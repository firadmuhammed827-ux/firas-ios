import Foundation

@main
@MainActor enum ChatDifficultyStoreTests {
    static func main() async throws {
        var checks = 0
        var suites: [String] = []
        defer { for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) } }
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
        }
        func fixture() -> (SessionStore, FirasAPI, ChatStore, UserDefaults) {
            let session = SessionStore()
            let api = FirasAPI()
            let suite = "firas-chat-difficulty-" + UUID().uuidString
            suites.append(suite)
            let defaults = UserDefaults(suiteName: suite)!
            return (session, api, ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: []), defaults)
        }
        func draft(_ store: ChatStore, _ session: SessionStore, text: String = "Create ten calculus problems") -> ChatDifficultyDraft {
            store.updateDraftText(text, expectedOwnerID: session.identityID, expectedIdentityGeneration: session.identityGeneration)
            return store.snapshotDraft()!
        }
        func request(_ store: ChatStore, _ snapshot: ChatDifficultyDraft) -> ChatDifficultyRequest<ChatDifficultyDraft> {
            guard case .choose(let request)? = store.difficultyAdmission(for: snapshot) else {
                preconditionFailure("eligible actual draft must request a choice")
            }
            return request
        }
        func ready(_ store: ChatStore, _ snapshot: ChatDifficultyDraft) -> ChatDifficultySubmission<ChatDifficultyDraft> {
            guard case .ready(let submission)? = store.difficultyAdmission(for: snapshot) else {
                preconditionFailure("bypass actual draft must issue a permit")
            }
            return submission
        }
        func send(_ store: ChatStore, _ submission: ChatDifficultySubmission<ChatDifficultyDraft>, web: Bool = false,
                  context: PreparedChatContext? = nil) async -> String? {
            await store.send(text: submission.scope.draft.text, tier: .pro, thinking: false, webSearch: web,
                language: .english, context: context, expectedOwnerID: submission.scope.ownerID, difficultySubmission: submission)
        }
        func complete(_ api: FirasAPI, _ store: ChatStore) async throws {
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "difficulty-" + UUID().uuidString, phase: .completed, text: "synthetic result")
            try await waitUntil { !store.isSending }
        }

        do {
            let (session, api, store, _) = fixture()
            let snapshot = draft(store, session)
            let held = request(store, snapshot)
            expect(held.decision.calibration.level == 5 && !store.isSending && store.selectedConversationID == nil,
                   "first eligible draft asks at five before any local send reservation")
            expect(api.createCount == 0 && api.classificationCount == 0 && api.updates.isEmpty && api.starts.isEmpty,
                   "opening the chooser creates no chat, classifier request, history write or job POST")
            store.cancelDifficulty(requestID: held.id)
            expect(store.chooseDifficulty(held, level: 7) == nil && store.snapshotDraft() == snapshot,
                   "cancel retains exact draft/context and prevents late choice dispatch")
            expect(request(store, snapshot).id != held.id, "Cancel does not seal a permanent chooser bypass")
            let bypass = await store.send(text: snapshot.text, tier: .pro, thinking: false, webSearch: false, language: .english)
            expect(bypass == nil && api.starts.isEmpty, "direct Store send cannot bypass an eligible unresolved chooser")
        }
        do {
            let (session, api, store, defaults) = fixture()
            let snapshot = draft(store, session)
            let held = request(store, snapshot)
            let submission = store.chooseDifficulty(held, level: 7)!
            let cid = await send(store, submission)
            expect(cid != nil && store.selectedConversationID == "created-1", "one confirmed choice admits the first actual owned chat")
            try await waitUntil { api.pendingStarts.count == 1 }
            let job = api.starts[0]
            let rule = DifficultyPolicy.rule(submission.calibration)
            expect(job.messages.first?.role == .system && job.messages.first?.content.hasSuffix(rule) == true,
                   "a question-only turn carries its selected calibration in the actual first system request")
            expect(job.messages.last?.content == snapshot.text && job.messages.last?.cid == cid,
                   "actual user request and CID are unchanged")
            expect(api.updates.last?.request.messages?.contains { $0.role == .system } == false,
                   "calibration is not persisted as a synthetic history row")
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
            expect(wire["difficulty"] == nil && wire["calibration"] == nil && wire["product"] as? String == "ai",
                   "actual encoded job adds no invented difficulty wire flag")
            expect(ChatDifficultyLevelRepository(defaults: defaults).level(ownerID: snapshot.ownerID, conversationID: "created-1") == 7,
                   "provisional choice transfers only to the actual created chat ID")
            store.beginDraftSubmission(cid: cid!, snapshot: snapshot)
            try await complete(api, store)
            expect(store.draftText.isEmpty, "only accepted unchanged draft is consumed")
            let next = request(store, draft(store, session))
            expect(next.decision.calibration.level == 7, "remembered level preselects but does not skip the next chooser")
            let oldSend = await send(store, submission)
            expect(oldSend == nil && api.starts.count == 1, "consumed old permit cannot replay after terminal completion")
        }
        do {
            let (session, api, store, _) = fixture()
            let snapshot = draft(store, session)
            let held = request(store, snapshot)
            let submission = store.chooseDifficulty(held, level: 2)!
            expect(store.chooseDifficulty(held, level: 6) == nil, "double tap cannot issue a second ready permit")
            store.updateDraftText("newer", expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            store.updateDraftText(snapshot.text, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            let cid = await send(store, submission)
            expect(cid == nil && api.createCount == 0 && api.starts.isEmpty, "edited-and-restored draft revision rejects a queued choice before IO")
        }
        do {
            let (session, api, store, _) = fixture()
            let snapshot = draft(store, session)
            let held = request(store, snapshot)
            var context = snapshot.context
            context.fileNames = ["source.txt"]
            context.files = [DraftFileAsset(id: "source", name: "source.txt", kind: "text", text: "synthetic source", wasTruncated: false)]
            store.updateDraftContext(context, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            expect(store.chooseDifficulty(held, level: 3) == nil, "late context update rejects the old chooser")
            let attached = ready(store, store.snapshotDraft()!)
            expect(attached.calibration.level == 5 && api.classificationCount == 0, "actual attachment bypass issues calibration without asking/classifying")
        }
        do {
            let (session, api, _, defaults) = fixture()
            ChatDifficultyLevelRepository(defaults: defaults).set(2, ownerID: session.identityID!, conversationID: "attached-parent")
            let store = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [])
            await store.select("attached-parent")
            _ = draft(store, session)
            var context = DraftContextSelection()
            context.fileNames = ["worksheet.txt"]
            context.files = [DraftFileAsset(id: "worksheet", name: "worksheet.txt", kind: "text", text: "synthetic worksheet", wasTruncated: false)]
            store.updateDraftContext(context, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            let submission = ready(store, store.snapshotDraft()!)
            expect(submission.calibration.level == 2, "attachments suppress only the chooser and inherit stored owner/chat level two")
            let prepared = PreparedChatContext(fullImages: [], imageThumbnails: [],
                files: [ChatAttachment(name: "worksheet.txt", kind: "text")], fileText: "synthetic worksheet")
            let cid = await send(store, submission, context: prepared)
            expect(cid != nil, "an attached eligible request uses its genuine prepared file context")
            try await waitUntil { api.pendingStarts.count == 1 }
            let job = api.starts[0]
            expect(job.messages.first?.content.hasSuffix(DifficultyPolicy.rule(DifficultyCalibration(level: 2))) == true,
                   "actual attached-file job carries the full inherited level two system rule")
            expect(api.updates.last?.request.messages?.contains { $0.role == .system } == false &&
                   api.updates.last?.request.messages?.last?.files == prepared.files,
                   "attached-file saved history retains real file metadata without calibration rows")
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as! [String: Any]
            expect(wire["difficulty"] == nil && wire["calibration"] == nil, "attached job has no invented difficulty body metadata")
            try await complete(api, store)
        }
        do {
            let (session, api, store, _) = fixture()
            let snapshot = draft(store, session)
            let submission = store.chooseDifficulty(request(store, snapshot), level: 6)!
            session.identityGeneration += 1
            let cid = await send(store, submission)
            expect(cid == nil && api.starts.isEmpty && api.createCount == 0, "same-account credential ABA rejects a queued permit before admission")
            expect(store.draftText == snapshot.text, "same-owner epoch transition preserves editable text")
        }
        do {
            let (session, api, store, _) = fixture()
            await store.select("one")
            let snapshot = draft(store, session)
            let held = request(store, snapshot)
            api.delayedChatIDs.insert("two")
            let navigation = Task { await store.select("two") }
            try await waitUntil { api.pendingChats["two"] != nil }
            expect(store.selectedConversationID == "one" && store.chooseDifficulty(held, level: 3) == nil,
                   "pending navigation invalidates the old choice before selected ID changes")
            api.resolveChat(id: "two")
            await navigation.value
            expect(api.starts.isEmpty && store.draftText == snapshot.text, "navigation retirement preserves draft without job dispatch")
        }
        do {
            let (session, api, store, _) = fixture()
            let submission = store.chooseDifficulty(request(store, draft(store, session)), level: 6)!
            store.retireDifficultySelection()
            let cid = await send(store, submission)
            expect(cid == nil && api.createCount == 0 && api.starts.isEmpty,
                   "another modal or leaving Chat retires an already chosen queued permit")
        }
        do {
            let (session, api, store, defaults) = fixture()
            let submission = store.chooseDifficulty(request(store, draft(store, session)), level: 2)!
            api.delayCreation = true
            let pending = Task { await send(store, submission) }
            try await waitUntil { api.pendingCreations.count == 1 }
            expect(ChatDifficultyLevelRepository(defaults: defaults).level(ownerID: submission.scope.ownerID, conversationID: "actual-owned") == 5,
                   "awaiting creation cannot persist a speculative target level")
            api.resolveCreation(id: "actual-owned")
            let cid = await pending.value
            expect(cid != nil && store.selectedConversationID == "actual-owned", "owned first-create lease admits its controlled real ID")
            expect(ChatDifficultyLevelRepository(defaults: defaults).level(ownerID: submission.scope.ownerID, conversationID: "actual-owned") == 2,
                   "delayed owned create adopts precisely the confirmed level")
            try await complete(api, store)
        }
        do {
            let (session, api, store, defaults) = fixture()
            let submission = store.chooseDifficulty(request(store, draft(store, session)), level: 7)!
            api.delayCreation = true
            let pending = Task { await send(store, submission) }
            try await waitUntil { api.pendingCreations.count == 1 }
            await store.select("different-navigation")
            api.resolveCreation(id: "retired-create")
            let cid = await pending.value
            expect(cid == nil && api.starts.isEmpty && store.selectedConversationID == "different-navigation",
                   "retired first-create response cannot send into a replacement chat")
            let levels = ChatDifficultyLevelRepository(defaults: defaults)
            expect(levels.level(ownerID: submission.scope.ownerID, conversationID: "retired-create") == 5 &&
                   levels.level(ownerID: submission.scope.ownerID, conversationID: "different-navigation") == 5,
                   "retired create transfers its level to neither old nor unrelated conversation")
        }
        do {
            let (session, api, _, defaults) = fixture()
            ChatDifficultyLevelRepository(defaults: defaults).set(1, ownerID: "foreign-owner", conversationID: "shared-id")
            let store = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [])
            await store.select("shared-id")
            let held = request(store, draft(store, session))
            expect(held.decision.calibration.level == 5, "a foreign owner’s identical chat ID does not preselect their level")
            session.identityID = "foreign-owner"
            expect(store.chooseDifficulty(held, level: 3) == nil && api.starts.isEmpty,
                   "account change rejects a stale rendered chooser")
        }
        do {
            let (session, api, store, _) = fixture()
            let snapshot = draft(store, session, text: "Create ten calculus problems at level 3")
            let submission = ready(store, snapshot)
            expect(submission.calibration.level == 3, "explicit written difficulty bypasses only its own chooser")
            let cid = await send(store, submission, web: true)
            expect(cid != nil, "explicit difficulty is a real ordinary turn")
            try await waitUntil { api.pendingStarts.count == 1 }
            expect(api.starts[0].messages.first?.content.hasSuffix(DifficultyPolicy.rule(submission.calibration)) == true,
                   "web request preparation retains final captured calibration")
            try await complete(api, store)
        }
        do {
            let (session, api, store, _) = fixture()
            let snapshot = draft(store, session)
            let submission = store.chooseDifficulty(request(store, snapshot), level: 4)!
            let cid = await send(store, submission)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.failStart(APIError.httpStatus(400, nil))
            try await waitUntil { !store.isSending }
            expect(store.snapshotDraft()?.text == snapshot.text && store.lastAcceptedSend == nil,
                   "definitive job failure leaves the editable brief intact")
            expect(request(store, store.snapshotDraft()!).decision.calibration.level == 4 && api.starts.count == 1,
                   "a new explicit attempt asks again at four without automatically replaying the failed POST")
        }
        do {
            let (session, api, store, _) = fixture()
            let snapshot = draft(store, session, text: "/prompteng Create ten calculus problems")
            expect(store.difficultyAdmission(for: snapshot) == nil && api.createCount == 0,
                   "prompt engineer never opens ordinary difficulty admission")
        }
        do {
            let (session, api, store, defaults) = fixture()
            let snapshot = draft(store, session)
            let submission = store.chooseDifficulty(request(store, snapshot), level: 7)!
            api.delayCreation = true
            let pending = Task { await send(store, submission) }
            try await waitUntil { api.pendingCreations.count == 1 }
            store.updateDraftText("edited during create", expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            store.updateDraftText(snapshot.text, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            api.resolveCreation(id: "edited-first-create")
            let cid = await pending.value
            expect(cid == nil && api.starts.isEmpty && api.updates.isEmpty,
                   "edit-and-restore during controlled first creation prevents history/job admission")
            expect(ChatDifficultyLevelRepository(defaults: defaults).level(ownerID: snapshot.ownerID, conversationID: "edited-first-create") == 5,
                   "retired exact draft cannot transfer its provisional level after create")
            expect(store.draftText == snapshot.text && !store.isSending,
                   "first-create retirement preserves restored editable input and releases local reservation")
        }
        do {
            let (session, api, store, defaults) = fixture()
            let submission = store.chooseDifficulty(request(store, draft(store, session)), level: 6)!
            api.delayCreation = true
            let pending = Task { await send(store, submission) }
            try await waitUntil { api.pendingCreations.count == 1 }
            store.retireDifficultySelection()
            api.resolveCreation(id: "modal-retired-create")
            let cid = await pending.value
            expect(cid == nil && api.starts.isEmpty && api.updates.isEmpty,
                   "modal retirement during first creation prevents later history/job admission")
            expect(ChatDifficultyLevelRepository(defaults: defaults).level(ownerID: submission.scope.ownerID, conversationID: "modal-retired-create") == 5,
                   "modal retirement transfers no provisional level to the accepted empty chat")
        }
        do {
            let (session, api, store, _) = fixture()
            await store.select("credentials-parent")
            let snapshot = draft(store, session)
            let submission = store.chooseDifficulty(request(store, snapshot), level: 4)!
            api.delayMediaCredentials = true
            let cid = await send(store, submission)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingMediaCredentials.count == 1 }
            store.retireDifficultySelection()
            api.pendingMediaCredentials.removeFirst().resume(returning: MediaCredentialSnapshot(
                origin: URL(string: "https://firasai.org")!, cookieHeader: "test-owned-cookie"))
            try await waitUntil { !store.isSending }
            expect(api.starts.isEmpty && api.updates.isEmpty,
                   "modal retirement across credential capture prevents pre-POST history and admission")
            expect(store.draftText == snapshot.text && store.lastAcceptedSend == nil,
                   "retired pre-POST reservation cannot consume the editable brief")
        }
        do {
            let (session, api, store, _) = fixture()
            await store.select("put-parent")
            let snapshot = draft(store, session)
            let submission = store.chooseDifficulty(request(store, snapshot), level: 4)!
            api.delayUpdates = true
            let cid = await send(store, submission)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingUpdates.count == 1 }
            store.retireDifficultySelection()
            api.resolveUpdate()
            try await waitUntil { !store.isSending }
            expect(api.updates.count == 1 && api.starts.isEmpty,
                   "retirement after an already-issued history PUT prevents job POST without claiming that PUT was undone")
            expect(store.draftText == snapshot.text, "retired history preparation retains editable text")
        }
        do {
            let (session, api, store, _) = fixture()
            await store.select("classifier-parent")
            let snapshot = draft(store, session)
            let submission = store.chooseDifficulty(request(store, snapshot), level: 4)!
            api.delayClassification = true
            _ = await send(store, submission)
            try await waitUntil { api.pendingClassifications.count == 1 }
            store.retireDifficultySelection()
            api.resolveClassification(.unavailable)
            try await waitUntil { !store.isSending }
            expect(api.starts.isEmpty && api.classificationCount == 1,
                   "retirement during classifier preparation prevents the sole admission POST")
        }
        do {
            let (session, api, store, _) = fixture()
            let snapshot = draft(store, session)
            let submission = store.chooseDifficulty(request(store, snapshot), level: 4)!
            let cid = await send(store, submission)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingStarts.count == 1 }
            store.retireDifficultySelection()
            store.updateDraftText("next editable request", expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            try await complete(api, store)
            expect(api.starts.count == 1 && store.lastAcceptedSend?.cid == cid,
                   "after the sole POST starts, UI retirement cannot abandon receipt/cloud completion")
            expect(store.draftText == "next editable request" && api.cancelledJobs.isEmpty,
                   "post-admission leave/edit preserves newer input without an implicit server Stop")
        }
        do {
            let (session, api, store, _) = fixture()
            let snapshot = draft(store, session, text: String(repeating: "x", count: 60_001))
            expect(store.difficultyAdmission(for: snapshot, language: .english) == nil &&
                   store.errorMessage == "The request is too long. Split it without dropping your constraints." && api.starts.isEmpty,
                   "oversized admission preserves the existing localized limit explanation instead of a silent no-op")
        }
        print("PASS \(checks) actual ChatStore difficulty admission/wire/ownership checks")
    }

    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("synthetic difficulty boundary did not become ready")
    }
}

import Foundation

@main
@MainActor enum ChatStoreRaceTests {
    static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
        }
        // Each store gets its own synthetic guest-transcript folder, so no
        // case reads another case's (or a previous run's) device copy.
        func guestDirectory() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("firas-guest-chat-test-" + UUID().uuidString, isDirectory: true)
        }
        @MainActor func fixture() -> (SessionStore, FirasAPI, ChatStore) {
            let session = SessionStore()
            let api = FirasAPI()
            let defaults = UserDefaults(suiteName: "firas-chat-race-test-" + UUID().uuidString)!
            return (session, api, ChatStore(session: session, api: api, defaults: defaults,
                recoveryDelays: [.milliseconds(1), .milliseconds(1)], guestTranscriptDirectory: guestDirectory()))
        }
        func summary(_ id: String, agent: Bool = false, code: Bool = false, brain: Bool = false) -> ChatSummary {
            ChatSummary(id: id, title: "Title: " + id, updatedAt: "test", pinned: false,
                        agent: agent, codeProj: code, brainNb: brain)
        }

        let exactDraft = "  Editable request\n"
        var originalDraftContext = DraftContextSelection()
        originalDraftContext.fileNames = ["draft.txt"]
        originalDraftContext.files = [DraftFileAsset(id: "draft-file", name: "draft.txt", kind: "text",
            text: "Private source text", wasTruncated: false)]
        do {
            let (session, api, store) = fixture()
            store.updateDraftText(exactDraft, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            store.updateDraftContext(originalDraftContext, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let cid = await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingStarts.count == 1 }
            expect(store.draftText == exactDraft && store.draftContext == originalDraftContext,
                   "actual local Send reservation retains editable exact text and original attachment contents")
            api.failStart(APIError.httpStatus(400, nil))
            try await waitUntil { !store.isSending }
            await store.select("another-chat-after-failure")
            expect(store.draftText == exactDraft && store.draftContext == originalDraftContext,
                   "pre-enqueue failure followed by navigation preserves the store-owned editable draft")
            expect(store.lastAcceptedSend == nil, "failure cannot fabricate acceptance to consume a draft")
        }
        do {
            let (session, api, store) = fixture()
            store.updateDraftText(exactDraft, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            store.updateDraftContext(originalDraftContext, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let cid = await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingStarts.count == 1 }
            store.updateDraftText("Newer editable request", expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            var laterContext = originalDraftContext
            laterContext.images = [DraftImageAsset(id: "later-image", sourceID: "camera:later", jpegData: Data([1, 2, 3]))]
            laterContext.cameraPhotoCount = 1
            store.updateDraftContext(laterContext, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            api.resolveStart(jobID: "accepted-with-new-draft", phase: .completed, text: "answer")
            try await waitUntil { !store.isSending }
            expect(store.lastAcceptedSend?.cid == cid && store.draftText == "Newer editable request" && store.draftContext == laterContext,
                   "actual server acceptance preserves newer edits and newly imported attachment bytes")
        }
        do {
            let (session, api, store) = fixture()
            store.updateDraftText(exactDraft, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            store.updateDraftContext(originalDraftContext, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let cid = await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "fast-accepted-draft", phase: .completed, text: "answer")
            try await waitUntil { !store.isSending }
            expect(store.draftText == exactDraft, "receipt arriving before local snapshot registration cannot erase an unregistered draft")
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            expect(store.draftText.isEmpty && store.draftContext.isEmpty,
                   "fast accepted receipt reconciles the exact registered snapshot even after terminal completion")
        }
        do {
            let (session, api, store) = fixture()
            store.updateDraftText(exactDraft, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let cid = await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingStarts.count == 1 }
            await store.stop()
            api.resolveStart(jobID: "stopped-pending-draft")
            try await waitUntil { !store.isSending }
            expect(store.draftText == exactDraft && api.cancelledJobs == ["stopped-pending-draft"],
                   "Stop before accepted-id response keeps input editable while cancelling only the accepted server job")
        }
        do {
            let (session, api, store) = fixture()
            store.updateDraftText(exactDraft, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let cid = await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            await store.select("new-navigation")
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            api.resolveStart(jobID: "navigation-pending-draft", phase: .completed, text: "answer")
            try await waitUntil { !store.isSending }
            expect(store.draftText == exactDraft && store.selectedConversationID == "new-navigation",
                   "late acceptance after navigation retains editable input and does not replace the newer selection")
        }
        do {
            let (session, api, store) = fixture()
            store.updateDraftText(exactDraft, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let cid = await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "fast-accept-before-stop")
            try await waitUntil { store.activeJobID == "fast-accept-before-stop" }
            await store.stop()
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            expect(store.draftText == exactDraft && store.lastAcceptedSend?.cid == cid,
                   "Stop before late local registration prevents an already published receipt from consuming input")
        }
        do {
            let (session, api, store) = fixture()
            store.updateDraftText(exactDraft, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let cid = await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingStarts.count == 1 }
            session.identityGeneration = 1
            store.synchronizeDraftOwner()
            api.resolveStart(jobID: "old-epoch-draft", phase: .completed, text: "answer")
            try await waitUntil { !store.isSending }
            expect(store.draftText == exactDraft, "same-account auth epoch keeps unsent text and rejects old-epoch draft consumption")
            session.identityID = "owner-two"
            session.identityGeneration = 2
            store.synchronizeDraftOwner()
            expect(store.draftText.isEmpty && store.draftContext.isEmpty, "new account exposes no previous owner's draft or context")
            store.updateDraftText("stale old field", expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            store.updateDraftContext(originalDraftContext, expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            expect(store.draftText.isEmpty && store.draftContext.isEmpty, "queued old text or attachment bindings cannot contaminate the new owner's draft")
        }

        // Round-trip actual omitted server sanitizer fields, including nested
        // activity traces. Local identity/state and typed content stay local.
        do {
            let data = Data(#"{"role":"assistant","content":"canonical","cid":"known","steps":[{"id":"search","details":{"query":"source"}}],"fileRevision":7,"omnix":{"run":"cloud-run","phase":"done"},"future":[true,null,9223372036854775807],"id":"untrusted-id","state":"failed"}"#.utf8)
            var decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
            let metadata = decoded.unknownFields
            decoded.content = "typed content wins"
            let encoded = try JSONEncoder().encode(decoded)
            let roundTrip = try JSONDecoder().decode(ChatMessage.self, from: encoded)
            expect(roundTrip.unknownFields == metadata && metadata["steps"] != nil && metadata["fileRevision"] != nil && metadata["omnix"] != nil,
                   "unknown server steps, file revision and Omnix metadata survive real Codable round-trip")
            let wire = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            expect(wire["id"] == nil && wire["state"] == nil && wire["content"] as? String == "typed content wins",
                   "local state and identity never override canonical typed wire fields")
            let oversized = "{\"role\":\"user\",\"content\":\"small\",\"oversized\":\"" + String(repeating: "x", count: 131_073) + "\",\"fileRevision\":3}"
            let bounded = try JSONDecoder().decode(ChatMessage.self, from: Data(oversized.utf8))
            expect(bounded.unknownFields["oversized"] == nil && bounded.unknownFields["fileRevision"] == .integer(3),
                   "oversized unknown metadata cannot crowd out valid bounded server fields")
        }

        do {
            let (_, api, store) = fixture()
            let saved = try JSONDecoder().decode(ChatMessage.self, from: Data(#"{"role":"assistant","content":"earlier","cid":"previous","steps":[{"id":"old-step"}],"fileRevision":4,"omnix":{"run":"old-run"}}"#.utf8))
            api.chats["shared"] = ChatConversation(id: "shared", title: "Old title", messages: [saved])
            await store.select("shared")
            api.chats["shared"] = ChatConversation(id: "shared", title: "Canonical title", messages: [saved, ChatMessage(role: .user, content: "website before send", cid: "before")])
            let cid = await store.send(text: "native current", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            let prepared = api.updates.last!.request.messages!
            expect(prepared.map(\.content) == ["earlier", "website before send", "native current"],
                   "the initial history save merges the native turn into freshly read website history")
            expect(prepared.first?.unknownFields == saved.unknownFields && prepared.last?.cid == cid,
                   "initial history PUT retains server metadata and associates the user with the accepted cid")
            let canonicalData = try JSONSerialization.data(withJSONObject: ["role": "assistant", "content": "server final", "cid": cid,
                "steps": [["id": "server-step"]], "fileRevision": 9, "omnix": ["run": "final-run"]])
            let canonical = try JSONDecoder().decode(ChatMessage.self, from: canonicalData)
            api.chats["shared"] = ChatConversation(id: "shared", title: "Latest server title", messages: prepared + [canonical, ChatMessage(role: .user, content: "website while running", cid: "during")])
            api.resolveStart(jobID: "canonical-job", phase: .completed, text: "local stale final")
            try await waitUntil { !store.isSending }
            expect(api.updates.count == 1, "terminal completion never PUTs an older local full history")
            expect(store.messages.contains { $0.content == "website while running" } && store.messages.contains { $0.content == "server final" },
                   "terminal canonical history retains concurrent website turns and the server answer")
            expect(store.messages.first { $0.role == .assistant && $0.cid == cid }?.unknownFields == canonical.unknownFields,
                   "terminal canonical worker metadata is preserved without an overwrite")
        }

        // Build a real persisted receipt by accepting a job, retire its local
        // watcher through an owner change, then hold the restored history GET.
        do {
            let session = SessionStore()
            let api = FirasAPI()
            let defaults = UserDefaults(suiteName: "firas-chat-restore-test-" + UUID().uuidString)!
            let original = ChatStore(session: session, api: api, defaults: defaults, guestTranscriptDirectory: guestDirectory())
            await original.send(text: "original durable", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "restored-job")
            try await waitUntil { original.activeJobID == "restored-job" }
            let chatID = original.selectedConversationID!
            session.identityID = "owner-away"
            await original.select("another-owner-chat")
            session.identityID = "owner-one"
            let restored = ChatStore(session: session, api: api, defaults: defaults, guestTranscriptDirectory: guestDirectory())
            api.delayedChatIDs = [chatID]
            let baseline = api.chatRequests.filter { $0 == chatID }.count
            let resume = Task { await restored.resumeActiveJob() }
            try await waitUntil { api.pendingChats[chatID] != nil }
            await restored.resumeActiveJob()
            let rejected = await restored.send(text: "duplicate while restoring", tier: .pro, thinking: false, webSearch: false, language: .english)
            let media = await restored.prepareMediaTurn(prompt: "new media while restoring", tier: .pro, language: .english, expectedOwnerID: "owner-one")
            expect(rejected == nil && media == nil && api.starts.count == 1,
                   "delayed receipt restoration cannot race an ordinary send or media binding")
            expect(api.chatRequests.filter { $0 == chatID }.count == baseline + 1,
                   "concurrent restoration creates one owned history read")
            let deletion = restored.deletionRequest(id: chatID, title: "Original durable chat")!
            let deletedWhileRestoring = await restored.delete(deletion, language: .english)
            expect(!deletedWhileRestoring && restored.activeJobID == nil && api.deletedChatIDs.isEmpty,
                   "persisted serverChatID blocks deletion while its receipt is unresolved and no active ID is published")
            await restored.select("latest-current-selection")
            api.resolveChat(id: chatID)
            await resume.value
            expect(restored.activeJobID == "restored-job" && restored.selectedConversationID == "latest-current-selection",
                   "restoration resumes the durable job without replacing newer navigation")
            await restored.stop()
            expect(api.cancelledJobs == ["restored-job"], "restored Stop targets the actual known receipt id once")
            let settledDeletion = restored.deletionRequest(id: chatID, title: "Original durable chat")!
            let deletedAfterStop = await restored.delete(settledDeletion, language: .english)
            expect(deletedAfterStop && api.deletedChatIDs == [chatID],
                   "a confirmed terminal Stop releases the original chat for exact-ID deletion")
        }

        // Media requires one persisted user/empty-assistant pair before any
        // render is admitted, while preserving existing typed history data.
        do {
            let (_, api, store) = fixture()
            let original = ChatMessage(role: .user, content: "existing", files: [ChatAttachment(name: "source.pdf")],
                images: ["original-image"], imageThumbs: ["original-thumb"], fileText: "original extraction")
            api.chats["media-history"] = ChatConversation(id: "media-history", title: "Saved", messages: [original])
            await store.select("media-history")
            let binding = await store.prepareMediaTurn(prompt: "Create an image", tier: .max,
                modelGeneration: .v11, language: .english, expectedOwnerID: "owner-one")
            expect(binding?.chatID == "media-history" && binding?.ownerID == "owner-one", "media binding targets the actual owned selected Chat")
            let messages = api.updates.last?.request.messages ?? []
            expect(messages.count == 3 && messages.first == original, "media preparation preserves prior attachments and history")
            let user = messages[1], assistant = messages[2]
            expect(user.role == .user && assistant.role == .assistant && assistant.content.isEmpty,
                   "media admission persists a user and empty assistant")
            expect(user.cid == binding?.cid && assistant.cid == binding?.cid && user.id != assistant.id,
                   "both media turns share the stable routing cid and unique UI identities")
            expect(user.tier == "max" && assistant.tier == "max" && assistant.modelGeneration == .v11 && assistant.lang == "en",
                   "media history captures selected tier, generation and language")
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(api.updates.last!.request)) as! [String: Any]
            let rows = wire["messages"] as! [[String: Any]]
            expect(rows.last?["content"] as? String == "" && rows.last?["cid"] as? String == binding?.cid,
                   "the actual history encoder keeps the empty assistant content and binding cid")
            expect(api.starts.isEmpty && api.classificationCount == 0 && !store.isSending,
                   "preparing an explicit media binding never starts an ordinary job or classifier")
        }

        do {
            let (session, api, store) = fixture()
            session.identityGeneration = 1
            let stale = await store.prepareMediaTurn(prompt: "old queued tap", tier: .pro,
                language: .english, expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            expect(stale == nil && api.createCount == 0 && api.updates.isEmpty,
                   "queued same-ID auth generations cannot create or save media turns")
            expect(store.errorMessage == nil, "a retired queued media tap cannot publish an error for the current session")
        }

        do {
            let (session, api, store) = fixture()
            api.delayUpdates = true
            let pending = Task { await store.prepareMediaTurn(prompt: "old owner", tier: .pro,
                language: .english, expectedOwnerID: "owner-one") }
            try await waitUntil { api.pendingUpdates.count == 1 }
            session.identityID = "owner-two"
            session.identityGeneration += 1
            await store.loadConversations()
            api.resolveUpdate()
            let retired = await pending.value
            expect(retired == nil && store.messages.isEmpty, "late media persistence cannot publish under another account")
            expect(!store.isSending && api.starts.isEmpty, "retired media binding releases only its own reservation")
        }

        do {
            let (session, api, store) = fixture()
            api.delayUpdates = true
            let pending = Task { await store.prepareMediaTurn(prompt: "before re-login", tier: .pro,
                language: .english, expectedOwnerID: "owner-one") }
            try await waitUntil { api.pendingUpdates.count == 1 }
            session.identityGeneration += 1
            api.resolveUpdate()
            let retired = await pending.value
            expect(retired == nil && store.messages.isEmpty, "same account re-login cannot publish an older media generation")
            expect(!store.isSending && store.activeCID == nil, "auth generation rejection releases preparation without a paid start")
        }

        do {
            let (_, api, store) = fixture()
            api.chats["old-selection"] = ChatConversation(id: "old-selection", title: "Old", messages: [])
            await store.select("old-selection")
            api.delayedChatIDs = ["old-selection"]
            let pending = Task { await store.prepareMediaTurn(prompt: "original target", tier: .pro,
                language: .english, expectedOwnerID: "owner-one") }
            try await waitUntil { api.pendingChats["old-selection"] != nil }
            await store.select("latest-selection")
            api.resolveChat(id: "old-selection")
            let retired = await pending.value
            expect(retired == nil && api.updates.isEmpty, "selecting another Chat retires delayed media preparation before writing")
            expect(store.selectedConversationID == "latest-selection", "media preparation never replaces a newer selection")
        }

        do {
            let (_, api, store) = fixture()
            await store.select("saved-history")
            api.updateFailure = .httpStatus(503, nil)
            let failed = await store.prepareMediaTurn(prompt: "retain this draft", tier: .pro,
                language: .english, expectedOwnerID: "owner-one")
            expect(failed == nil && store.messages.isEmpty && store.errorMessage != nil,
                   "failed media history save returns no binding and does not publish unsaved turns")
            expect(!store.isSending && api.starts.isEmpty, "failed binding never starts or charges a render")
        }

        do {
            let (_, api, store) = fixture()
            api.delayUpdates = true
            let pending = Task { await store.prepareMediaTurn(prompt: "stopped preparation", tier: .pro,
                language: .english, expectedOwnerID: "owner-one") }
            try await waitUntil { api.pendingUpdates.count == 1 }
            await store.stop()
            expect(store.isSending, "Stop keeps the media save reserved until its response resolves")
            api.resolveUpdate()
            let stopped = await pending.value
            expect(stopped == nil && !store.isSending && api.starts.isEmpty && api.cancelledJobs.isEmpty,
                   "Stop during binding never invents a render id or starts a job")
            api.delayUpdates = false
            let next = await store.prepareMediaTurn(prompt: "new explicit request", tier: .pro,
                language: .english, expectedOwnerID: "owner-one")
            expect(next != nil && !store.isSending, "stopped media preparation cannot poison the next explicit Create")
        }

        do {
            let (_, api, store) = fixture()
            api.delayCreation = true
            let first = Task { await store.prepareMediaTurn(prompt: "first", tier: .pro,
                language: .english, expectedOwnerID: "owner-one") }
            try await waitUntil { api.pendingCreations.count == 1 }
            let second = await store.prepareMediaTurn(prompt: "second", tier: .pro,
                language: .english, expectedOwnerID: "owner-one")
            expect(second == nil && api.createCount == 1, "two rapid media Create taps share one reserved first-chat creation")
            api.resolveCreation(id: "media-created")
            let bound = await first.value
            expect(bound?.chatID == "media-created" && api.updates.count == 1, "first media creation saves exactly one binding")
        }

        // Hold the server's accepted-job response until Stop has been tapped.
        // The owning operation must retain that intent and cancel the returned
        // id exactly once; a second send must not race the pending submission.
        do {
            let (_, api, store) = fixture()
            await store.loadConversations()
            await store.send(text: "first", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            expect(api.starts[0].mgen == "1.1", "new native turns use the website's shipping model generation")
            await store.stop()
            expect(store.isSending, "Stop keeps a pending enqueue reserved until its id resolves")
            await store.send(text: "second", tier: .pro, thinking: false, webSearch: false, language: .english)
            expect(api.starts.count == 1, "a second send cannot overwrite a stopped pending enqueue")
            api.resolveStart(jobID: "accepted-before-stop")
            try await waitUntil { api.cancelledJobs.count == 1 }
            expect(api.cancelledJobs == ["accepted-before-stop"], "Stop cancels precisely the accepted job")
            expect(store.messages.last?.state == .stopped, "the stopped answer stays stopped")
            expect(!store.isSending && store.activeJobID == nil, "cancel confirmation releases composer")
        }

        // Reserve Send before the first authenticated conversation is created.
        do {
            let (_, api, store) = fixture()
            await store.loadConversations()
            api.delayCreation = true
            let first = Task { await store.send(text: "first", tier: .pro, thinking: false, webSearch: false, language: .english) }
            try await waitUntil { api.pendingCreations.count == 1 }
            let second = Task { await store.send(text: "second", tier: .pro, thinking: false, webSearch: false, language: .english) }
            try await Task.sleep(for: .milliseconds(20))
            expect(api.createCount == 1, "double tapping Send creates only one first conversation")
            await second.value
            api.resolveCreation(id: "first-chat")
            await first.value
            try await waitUntil { api.pendingStarts.count == 1 }
            await store.stop()
            api.resolveStart(jobID: "single-first-job")
            try await waitUntil { !store.isSending }
        }

        // Resolve earlier selection after later selection. Last intent wins.
        do {
            let (_, api, store) = fixture()
            await store.loadConversations()
            api.delayedChatIDs = ["earlier", "later"]
            let earlier = Task { await store.select("earlier") }
            try await waitUntil { api.pendingChats["earlier"] != nil }
            let later = Task { await store.select("later") }
            try await waitUntil { api.pendingChats["later"] != nil }
            api.resolveChat(id: "later")
            await later.value
            api.resolveChat(id: "earlier")
            await earlier.value
            expect(store.selectedConversationID == "later", "a slow old selection cannot replace the latest chat")
        }

        // Sending another turn must preserve older attachment chips/thumbnails.
        // Only the inference request copy may discard heavy previous context.
        do {
            let (_, api, store) = fixture()
            let photo = ChatMessage(role: .user, content: "photo", files: [ChatAttachment(name: "source.pdf")],
                                    images: ["full-original"], imageThumbs: ["thumb-original"], fileText: "original document")
            api.chats["history"] = ChatConversation(id: "history", title: "history", messages: [photo, ChatMessage(role: .assistant, content: "answer")])
            await store.loadConversations()
            await store.select("history")
            await store.send(text: "followup", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            expect(store.messages.first?.imageThumbs == ["thumb-original"], "old photo stays visible in saved history")
            expect(store.messages.first?.files?.first?.name == "source.pdf", "old file metadata survives a followup")
            let requestPhoto = api.starts[0].messages.first(where: { $0.content == "photo" })
            expect(store.messages.first?.modelGeneration == .legacy, "legacy history keeps its own original model generation")
            expect(store.messages.last?.modelGeneration == .v11, "the new answer captures the current generation")
            expect(requestPhoto?.images == nil && requestPhoto?.fileText == nil, "inference copy remains lightweight")
            await store.stop()
            api.resolveStart(jobID: "history-job")
            try await waitUntil { !store.isSending }
        }
        // An accepted response from the previous account must never reset a
        // new account's pending send. Leaving an account is not a server Stop.
        do {
            let (session, api, store) = fixture()
            await store.loadConversations()
            await store.send(text: "old account", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            session.identityID = "owner-two"
            await store.loadConversations()
            await store.send(text: "new account", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 2 }
            api.resolveStart(jobID: "old-account-job")
            try await Task.sleep(for: .milliseconds(20))
            expect(store.isSending && store.messages.first?.content == "new account", "stale accepted job cannot overwrite the new account's send")
            expect(api.cancelledJobs.isEmpty, "account switch leaves the previous server job running")
            await store.stop()
            api.resolveStart(jobID: "new-account-job")
            try await waitUntil { !store.isSending }
            expect(api.cancelledJobs == ["new-account-job"], "explicit Stop is bound to the new account's own job")
        }
        // Pins affect the actual job, never the internal classifier. A failed
        // enqueue has no acceptance receipt, so the next attempt retains them.
        do {
            let (_, api, store) = fixture()
            await store.loadConversations()
            let skill = AccountSkill(id: "usk-1234567890abcdef", name: "Physics", cues: ["physics"], rules: ["Keep units."], mode: .auto, enabled: true)
            var selection = ChatSkillSelection()
            selection.bind(ownerID: "owner-one")
            selection.toggle(skill, available: [skill], expectedOwnerID: "owner-one")
            let classified = await store.classifyDraft(text: "Explain how to generate an image", context: nil, expectedOwnerID: "owner-one")
            let cid = await store.send(text: "Explain how to generate an image", tier: .pro, thinking: false, webSearch: false,
                                       language: .english, skillIDs: selection.ids, expectedOwnerID: "owner-one", prefetchedIntent: classified)
            expect(cid != nil, "owner-scoped pin send reserves a real turn")
            selection.beginSubmission(cid: cid!, ids: selection.ids, expectedOwnerID: "owner-one")
            try await waitUntil { api.pendingStarts.count == 1 }
            expect(api.classificationCount == 1, "prefetched conversational decision is classified only once")
            expect(api.starts.last?.skillIds == [skill.id], "selected pins reach the actual durable job")
            let expectedInstruction = classified.conversationInstruction
            let expectedDifficulty = DifficultyPolicy.decision(text: "Explain how to generate an image", currentLevel: 5)
            expect(!expectedDifficulty.ask && expectedDifficulty.calibration == DifficultyCalibration(level: 5),
                   "this ordinary explanation retains default level five without a chooser")
            let expectedRule = DifficultyPolicy.rule(DifficultyCalibration(level: 5))
            let submittedSystem = api.starts.last!.messages.first!
            expect(submittedSystem.role == .system &&
                   String(submittedSystem.content.prefix(expectedInstruction.count)) == expectedInstruction,
                   "unknown decision keeps the exact truthful conversational instruction first")
            expect(String(submittedSystem.content.dropFirst(expectedInstruction.count)) == expectedRule,
                   "ordinary non-chooser request appends the exact complete source-derived level five rule once")
            api.failStart(APIError.httpStatus(400, nil))
            try await waitUntil { !store.isSending }
            expect(store.lastAcceptedSend == nil && selection.ids == [skill.id], "failed enqueue does not clear pins")
            let retryCID = await store.send(text: "Retry the explanation", tier: .pro, thinking: false, webSearch: false,
                                           language: .english, skillIDs: selection.ids, expectedOwnerID: "owner-one", prefetchedIntent: classified)
            selection.beginSubmission(cid: retryCID!, ids: selection.ids, expectedOwnerID: "owner-one")
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "pinned-accepted", phase: .completed, text: "Explanation")
            try await waitUntil { store.lastAcceptedSend != nil }
            selection.accept(store.lastAcceptedSend!)
            expect(selection.skills.isEmpty, "server acceptance consumes the exact submitted pin snapshot")
            try await waitUntil { !store.isSending }
        }

        // A queued callback captured for another identity must not even start
        // a classifier, conversation creation or job under the current account.
        do {
            let (session, api, store) = fixture()
            session.identityID = "owner-two"
            let decision = await store.classifyDraft(text: "old draft", context: nil, expectedOwnerID: "owner-one")
            let cid = await store.send(text: "old draft", tier: .pro, thinking: false, webSearch: false, language: .english,
                                       skillIDs: ["usk-1234567890abcdef"], expectedOwnerID: "owner-one", prefetchedIntent: decision)
            expect(cid == nil && api.starts.isEmpty && api.createCount == 0 && api.classificationCount == 0,
                   "queued old-account selection cannot submit using new-account credentials")
        }

        // Delayed old first-chat creation used to release isSending even after
        // a new account reserved its own send. The reservation cid owns release.
        do {
            let (session, api, store) = fixture()
            await store.loadConversations()
            api.delayCreation = true
            let old = Task { await store.send(text: "old first", tier: .pro, thinking: false, webSearch: false, language: .english) }
            try await waitUntil { api.pendingCreations.count == 1 }
            session.identityID = "owner-two"
            await store.loadConversations()
            let current = Task { await store.send(text: "new first", tier: .pro, thinking: false, webSearch: false, language: .english) }
            try await waitUntil { api.pendingCreations.count == 2 }
            api.resolveCreation(id: "old-first-chat")
            _ = await old.value
            expect(store.isSending && api.starts.isEmpty, "old creation cannot release the new owner's reservation")
            api.resolveCreation(id: "new-first-chat")
            _ = await current.value
            try await waitUntil { api.pendingStarts.count == 1 }
            expect(store.messages.first?.content == "new first", "only the current account publishes a pending first turn")
            await store.stop()
            api.resolveStart(jobID: "new-first-accepted")
            try await waitUntil { !store.isSending }
        }

        // Stopping preparation while classifier transport is suspended must
        // not publish its late media decision or enqueue anything.
        do {
            let (_, api, store) = fixture()
            api.delayClassification = true
            let pending = Task { await store.classifyDraft(text: "Create an image", context: nil, expectedOwnerID: "owner-one") }
            try await waitUntil { api.pendingClassifications.count == 1 }
            pending.cancel()
            let image = IntentDecision(ok: true, kind: "image", requirements: "", classified: true, codeTarget: "unknown", codeLanguage: "unknown")
            api.resolveClassification(image)
            let result = await pending.value
            expect(result == .unavailable && api.starts.isEmpty, "canceled preparation ignores late paid-media classification")
        }
        // Stop can arrive even before first-chat creation returns. There is
        // still no accepted job: retain the reservation until it can retire.
        do {
            let (_, api, store) = fixture()
            await store.loadConversations()
            api.delayCreation = true
            let pending = Task { await store.send(text: "first stopped", tier: .pro, thinking: false, webSearch: false, language: .english) }
            try await waitUntil { api.pendingCreations.count == 1 }
            await store.stop()
            expect(store.isSending && store.activeCID != nil, "Stop preserves the first-create reservation")
            api.resolveCreation(id: "stopped-first-chat")
            _ = await pending.value
            try await waitUntil { !store.isSending }
            expect(api.starts.isEmpty && store.lastAcceptedSend == nil && store.messages.last?.state == .stopped,
                   "Stop during first creation never enqueues or consumes a pin receipt")
        }
        do {
            let (_, api, store) = fixture()
            api.chats["source-chat"] = ChatConversation(id: "source-chat", title: "saved", messages: [])
            await store.select("source-chat")
            let encoded = Data([255,216,255] + Array(repeating: UInt8(0), count: 16)).base64EncodedString()
            let binding = await store.prepareMediaTurn(prompt: "عدّل الصورة", sourceImage: "data:image/jpeg;base64," + encoded,
                tier: .pro, language: .arabic, expectedOwnerID: "owner-one")
            expect(binding?.chatID == "source-chat" && api.updates.count == 1,
                   "source edit saves one owned ordinary Chat binding")
            expect(api.updates.last?.request.messages?.first?.images == [encoded] && api.starts.isEmpty,
                   "actual chosen source reaches shared user history without a render submission")
        }
        do {
            let (session, api, store) = fixture()
            api.delayMediaCredentials = true
            let pending = Task { await store.prepareMediaTurn(prompt: "owner one", tier: .pro,
                language: .english, expectedOwnerID: "owner-one", expectedIdentityGeneration: 0) }
            try await waitUntil { api.pendingMediaCredentials.count == 1 }
            session.identityGeneration += 1
            api.pendingMediaCredentials.removeFirst().resume(returning:
                MediaCredentialSnapshot(origin: URL(string: "https://firasai.org")!, cookieHeader: "old-test-cookie"))
            let bound = await pending.value
            expect(bound == nil && api.createCount == 0 && api.updates.isEmpty && api.starts.isEmpty,
                   "an account epoch changed during credential capture cannot create or overwrite history")
        }
        for kind in ["agent", "code", "brain"] {
            let (_, api, store) = fixture()
            var canonical = ChatConversation(id: "special", title: "special", messages: [])
            canonical.agent = kind == "agent"; canonical.codeProj = kind == "code"; canonical.brainNb = kind == "brain"
            api.chats["special"] = canonical
            // Direct old notification routes must not expose a retired/special chat.
            await store.select("special")
            expect(store.selectedConversation?.id != "special", "canonical special chat is rejected before selection")
            api.chats["special"] = ChatConversation(id: "special", title: "ordinary", messages: [])
            await store.select("special")
            api.chats["special"] = canonical
            let rejected = await store.prepareMediaTurn(prompt: "no special writes", tier: .pro,
                language: .english, expectedOwnerID: "owner-one")
            expect(rejected == nil && api.updates.isEmpty && api.starts.isEmpty,
                   "canonical special flags outrank stale ordinary client selection at media admission")
        }
        do {
            let (_, api, store) = fixture()
            let huge = ChatMessage(role: .user, content: String(repeating: "س", count: 1_100_000))
            api.chats["large"] = ChatConversation(id: "large", title: "large", messages: [huge])
            await store.select("large")
            let binding = await store.prepareMediaTurn(prompt: "retain complete history", tier: .pro,
                language: .english, expectedOwnerID: "owner-one")
            expect(binding == nil && api.updates.isEmpty && api.starts.isEmpty && store.messages == [huge],
                   "UTF8 serialized history over budget is kept complete without PUT or render admission")
        }
        for changed in [false, true] {
            let (_, _, store) = fixture()
            store.updateDraftText("original image brief", expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let binding = await store.prepareMediaTurn(prompt: snapshot.text, tier: .pro,
                language: .english, expectedOwnerID: "owner-one")
            expect(binding != nil, "internal media Chat preparation preserves the original draft submission revision")
            if changed {
                store.updateDraftText("later edit", expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
                store.updateDraftText("original image brief", expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            }
            store.consumeAcceptedMediaDraft(binding: binding!, snapshot: snapshot)
            expect(store.draftText == (changed ? "original image brief" : ""),
                   "accepted media consumes unchanged input only; edit-and-back retains the newer revision")
        }
        do {
            let (_, _, store) = fixture()
            store.updateDraftText("keep after navigation", expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let prepared = await store.prepareMediaTurn(prompt: snapshot.text, tier: .pro,
                language: .english, expectedOwnerID: "owner-one")
            let binding = prepared!
            store.retireDraftSubmission(expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            store.consumeAcceptedMediaDraft(binding: binding, snapshot: snapshot)
            expect(store.draftText == "keep after navigation", "navigation retires older media draft consumption")
        }
        // These call the production deletion/admission implementation against
        // controlled transport; they never call an account or a real DELETE.
        do {
            let (_, api, store) = fixture()
            await store.select("sending-chat")
            api.delayUpdates = true
            await store.send(text: "Pending history save", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingUpdates.count == 1 }
            let request = store.deletionRequest(id: "sending-chat", title: "Captured title")!
            let deleted = await store.delete(request, language: .english)
            expect(!deleted && store.activeJobID == nil && api.deletedChatIDs.isEmpty,
                   "current sending chat cannot be deleted before history save or job acceptance")
            await store.select("reading-another-chat")
            let originalRequest = store.deletionRequest(id: "sending-chat", title: "Captured title")!
            let deletedAfterNavigation = await store.delete(originalRequest, language: .english)
            expect(!deletedAfterNavigation && api.deletedChatIDs.isEmpty,
                   "sending conversation reservation follows the original ID after the reader navigates elsewhere")
            let unrelated = store.deletionRequest(id: "unrelated-idle-chat", title: "Unrelated")!
            let unrelatedDeleted = await store.delete(unrelated, language: .english)
            expect(unrelatedDeleted && api.deletedChatIDs == ["unrelated-idle-chat"] && store.selectedConversationID == "reading-another-chat",
                   "an unrelated idle exact-ID deletion remains available during a different chat's pending send")
            await store.stop()
            api.resolveUpdate()
            try await waitUntil { !store.isSending }
            expect(api.starts.isEmpty, "blocking a pending chat delete never submits or cancels a fabricated job")
        }
        do {
            let (session, api, store) = fixture()
            await store.select("preparing-media-chat")
            api.delayMediaCredentials = true
            let preparation = Task { await store.prepareMediaTurn(prompt: "Create an image", tier: .pro,
                language: .english, expectedOwnerID: "owner-one", expectedIdentityGeneration: 0) }
            try await waitUntil { api.pendingMediaCredentials.count == 1 }
            let request = store.deletionRequest(id: "preparing-media-chat", title: "Media parent")!
            let deleted = await store.delete(request, language: .english)
            expect(!deleted && api.deletedChatIDs.isEmpty,
                   "current media Chat history preparation also reserves its parent before any server job exists")
            session.identityGeneration += 1
            api.pendingMediaCredentials.removeFirst().resume(returning: MediaCredentialSnapshot(
                origin: URL(string: "https://firasai.org")!, cookieHeader: "test-owned-cookie"))
            let binding = await preparation.value
            expect(binding == nil && api.updates.isEmpty, "retired media preparation releases its reservation without history mutation")
        }
        do {
            let (session, api, store) = fixture()
            await store.select("ticket-chat")
            let captured = store.deletionRequest(id: "ticket-chat", title: "Exact displayed title")!
            expect(captured.conversationID == "ticket-chat" && captured.title == "Exact displayed title" &&
                   captured.ownerID == "owner-one" && captured.identityGeneration == 0,
                   "confirmation captures the exact target, displayed title, owner and identity epoch")
            session.identityGeneration += 1
            let retired = await store.delete(captured, language: .english)
            expect(!retired && api.deletedChatIDs.isEmpty, "queued delete is rejected after same-owner identity ABA")
            let busyTicket = store.deletionRequest(id: "ticket-chat", title: "Current")!
            session.isWorking = true
            let busy = await store.delete(busyTicket, language: .english)
            expect(!busy && store.deletionRequest(id: "ticket-chat", title: "Busy") == nil && api.deletedChatIDs.isEmpty,
                   "authentication in progress cannot dispatch or present a destructive ticket")
            session.isWorking = false
            let differentOwner = store.deletionRequest(id: "ticket-chat", title: "Current")!
            session.identityID = "owner-two"
            let foreign = await store.delete(differentOwner, language: .english)
            expect(!foreign && api.deletedChatIDs.isEmpty, "foreign-account queued confirmation cannot issue DELETE")
        }
        do {
            let (_, api, store) = fixture()
            await store.select("navigation-chat")
            let request = store.deletionRequest(id: "navigation-chat", title: "Original")!
            await store.select("another-selection")
            await store.select("navigation-chat")
            let deleted = await store.delete(request, language: .english)
            expect(!deleted && api.deletedChatIDs.isEmpty,
                   "selection ABA retires an older confirmation even when the same conversation is visible again")
            let cancelled = store.deletionRequest(id: "navigation-chat", title: "Current")!
            let operation = Task { await store.delete(cancelled, language: .english) }
            operation.cancel()
            let cancelledResult = await operation.value
            expect(!cancelledResult && api.deletedChatIDs.isEmpty, "cancelled queued delete cannot dispatch")
        }
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("delete-target"), summary("keep-reading")]
            await store.select("delete-target")
            await store.loadConversations()
            let request = store.deletionRequest(id: "delete-target", title: "Delete only this")!
            api.delayDeletion = true
            let operation = Task { await store.delete(request, language: .english) }
            try await waitUntil { api.pendingDeletions["delete-target"] != nil }
            let duplicate = await store.delete(request, language: .english)
            let send = await store.send(text: "Racing send", tier: .pro, thinking: false, webSearch: false, language: .english)
            let binding = await store.prepareMediaTurn(prompt: "Racing media", tier: .pro, language: .english, expectedOwnerID: "owner-one")
            expect(!duplicate && send == nil && binding == nil && api.deletedChatIDs == ["delete-target"] && api.updates.isEmpty,
                   "one pending exact-ID DELETE prevents duplicate deletion and new writes to its target")
            await store.select("keep-reading")
            api.resolveDeletion(id: "delete-target")
            let result = await operation.value
            expect(result && store.selectedConversationID == "keep-reading" && !store.conversations.contains { $0.id == "delete-target" },
                   "completed deletion removes only its target while preserving navigation during DELETE")
        }
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("delete-target"), summary("legacy-record", agent: true),
                summary("code-record", code: true), summary("brain-record", brain: true), summary("ordinary-fallback")]
            await store.select("delete-target")
            await store.loadConversations()
            api.delayedChatIDs = ["ordinary-fallback"]
            let request = store.deletionRequest(id: "delete-target", title: "Delete target")!
            let operation = Task { await store.delete(request, language: .english) }
            try await waitUntil { api.pendingChats["ordinary-fallback"] != nil }
            expect(!api.chatRequests.contains("legacy-record") && !api.chatRequests.contains("code-record") && !api.chatRequests.contains("brain-record"),
                   "delete fallback reads only an ordinary Chat, never a legacy or other-product transcript")
            await store.select("newer-reader-selection")
            api.resolveChat(id: "ordinary-fallback")
            let result = await operation.value
            expect(result && store.selectedConversationID == "newer-reader-selection",
                   "a delayed deletion fallback cannot replace a newer reader selection")
        }
        do {
            let (session, api, store) = fixture()
            api.listedChats = [summary("delete-target"), summary("ordinary-fallback")]
            await store.select("delete-target")
            await store.loadConversations()
            api.delayedChatIDs = ["ordinary-fallback"]
            let request = store.deletionRequest(id: "delete-target", title: "Delete target")!
            let operation = Task { await store.delete(request, language: .english) }
            try await waitUntil { api.pendingChats["ordinary-fallback"] != nil }
            session.identityGeneration += 1
            api.resolveChat(id: "ordinary-fallback")
            let result = await operation.value
            expect(result && store.selectedConversationID == nil,
                   "same-owner identity epoch change rejects a delayed fallback transcript after accepted DELETE")
        }
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("last-chat"), summary("code-record", code: true)]
            await store.select("last-chat")
            await store.loadConversations()
            let request = store.deletionRequest(id: "last-chat", title: "Last ordinary chat")!
            let result = await store.delete(request, language: .english)
            expect(result && store.selectedConversationID == nil && api.createCount == 0 && api.chatRequests == ["last-chat"],
                   "deleting the last ordinary Chat leaves an empty composer without silently creating or loading another product")
        }
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("failed-delete")]
            await store.select("failed-delete")
            await store.loadConversations()
            store.updateDraftText("Preserve my input", expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            api.deleteFailure = .httpStatus(403, nil)
            let request = store.deletionRequest(id: "failed-delete", title: "Keep on failure")!
            let result = await store.delete(request, language: .english)
            expect(!result && store.selectedConversationID == "failed-delete" && store.conversations.map(\.id) == ["failed-delete"] &&
                   store.draftText == "Preserve my input" && store.errorMessage != nil,
                   "failed DELETE preserves the exact transcript, list, editable draft and visible error")
            api.deleteFailure = nil
            let next = store.deletionRequest(id: "failed-delete", title: "Explicit second attempt")!
            let nextResult = await store.delete(next, language: .english)
            expect(nextResult && api.deletedChatIDs == ["failed-delete", "failed-delete"],
                   "failed DELETE releases only its own reservation and retries only after another explicit request")
        }
        do {
            let (session, api, store) = fixture()
            api.listedChats = [summary("retired-delete")]
            await store.select("retired-delete")
            await store.loadConversations()
            api.delayDeletion = true
            let request = store.deletionRequest(id: "retired-delete", title: "Old owner")!
            let operation = Task { await store.delete(request, language: .english) }
            try await waitUntil { api.pendingDeletions["retired-delete"] != nil }
            session.identityID = "owner-two"
            session.identityGeneration += 1
            await store.select("owner-two-chat")
            api.resolveDeletion(id: "retired-delete")
            let result = await operation.value
            expect(!result && store.selectedConversationID == "owner-two-chat" && store.errorMessage == nil && api.deletedChatIDs == ["retired-delete"],
                   "an old owner's accepted network deletion cannot replace new-account state or replay the request")
        }
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("deleted-before-old-list")]
            await store.select("deleted-before-old-list")
            await store.loadConversations()
            api.delayList = true
            let list = Task { await store.loadConversations() }
            try await waitUntil { api.pendingLists.count == 1 }
            let request = store.deletionRequest(id: "deleted-before-old-list", title: "Exact target")!
            let result = await store.delete(request, language: .english)
            api.resolveList([summary("deleted-before-old-list")])
            await list.value
            expect(result && store.conversations.isEmpty && store.selectedConversationID == nil && !store.isLoading,
                   "a stale in-flight list GET cannot resurrect an accepted deleted row or leave loading stuck")
        }

        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("delete-a"), summary("delete-b"), summary("keep-c")]
            await store.select("delete-a")
            await store.loadConversations()
            let requestA = store.deletionRequest(id: "delete-a", title: "A")!
            let requestB = store.deletionRequest(id: "delete-b", title: "B")!
            api.delayDeletion = true
            api.delayedChatIDs = ["keep-c"]
            let deleteA = Task { await store.delete(requestA, language: .english) }
            let deleteB = Task { await store.delete(requestB, language: .english) }
            try await waitUntil { api.pendingDeletions.count == 2 }
            api.resolveDeletion(id: "delete-a")
            try await waitUntil { api.pendingChats["keep-c"] != nil }
            expect(!api.chatRequests.contains("delete-b") && Set(api.deletedChatIDs) == Set(["delete-a", "delete-b"]),
                   "concurrent exact-ID deletions remain allowed while fallback skips another reserved target")
            api.resolveDeletion(id: "delete-b")
            let resultB = await deleteB.value
            api.resolveChat(id: "keep-c")
            let resultA = await deleteA.value
            expect(resultA && resultB && store.selectedConversationID == "keep-c" && store.conversations.map(\.id) == ["keep-c"],
                   "different-target DELETE completions preserve an existing ordinary fallback")
        }
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("delete-a"), summary("delete-b")]
            await store.select("delete-a")
            await store.loadConversations()
            let requestA = store.deletionRequest(id: "delete-a", title: "A")!
            api.delayDeletion = true
            api.delayedChatIDs = ["delete-b"]
            let deleteA = Task { await store.delete(requestA, language: .english) }
            try await waitUntil { api.pendingDeletions["delete-a"] != nil }
            api.resolveDeletion(id: "delete-a")
            try await waitUntil { api.pendingChats["delete-b"] != nil }
            let requestB = store.deletionRequest(id: "delete-b", title: "B")!
            let deleteB = Task { await store.delete(requestB, language: .english) }
            try await waitUntil { api.pendingDeletions["delete-b"] != nil }
            api.resolveDeletion(id: "delete-b")
            let resultB = await deleteB.value
            api.resolveChat(id: "delete-b")
            let resultA = await deleteA.value
            expect(resultA && resultB && store.selectedConversationID == nil && store.conversations.isEmpty && api.createCount == 0,
                   "fallback GET cannot resurrect a row deleted while that GET was suspended")
        }

        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("delete-selected"), summary("ordinary-next")]
            await store.select("delete-selected")
            await store.loadConversations()
            let request = store.deletionRequest(id: "delete-selected", title: "Selected")!
            api.delayDeletion = true
            let deletion = Task { await store.delete(request, language: .english) }
            try await waitUntil { api.pendingDeletions["delete-selected"] != nil }
            await store.select("delete-selected")
            expect(api.chatRequests == ["delete-selected"] && store.selectedConversationID == "delete-selected",
                   "selecting the reserved exact-ID delete target cannot dispatch another GET or retire deletion cleanup")
            api.resolveDeletion(id: "delete-selected")
            let result = await deletion.value
            expect(result && store.selectedConversationID == "ordinary-next",
                   "accepted same-target deletion clears the deleted transcript and selects only an available ordinary row")
        }
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("pending-target"), summary("keep-current")]
            await store.select("keep-current")
            await store.loadConversations()
            api.delayedChatIDs = ["pending-target"]
            let selection = Task { await store.select("pending-target") }
            try await waitUntil { api.pendingChats["pending-target"] != nil }
            let request = store.deletionRequest(id: "pending-target", title: "Pending target")!
            api.delayDeletion = true
            let deletion = Task { await store.delete(request, language: .english) }
            try await waitUntil { api.pendingDeletions["pending-target"] != nil }
            api.resolveDeletion(id: "pending-target")
            let result = await deletion.value
            api.resolveChat(id: "pending-target")
            await selection.value
            expect(result && store.selectedConversationID == "keep-current" && store.conversations.map(\.id) == ["keep-current"],
                   "accepted deletion invalidates only its target's earlier pending selection GET so a deleted transcript cannot reappear")
        }
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("delete-visible"), summary("chosen-next")]
            await store.select("delete-visible")
            await store.loadConversations()
            let request = store.deletionRequest(id: "delete-visible", title: "Visible")!
            api.delayDeletion = true
            let deletion = Task { await store.delete(request, language: .english) }
            try await waitUntil { api.pendingDeletions["delete-visible"] != nil }
            api.delayedChatIDs = ["chosen-next"]
            let selection = Task { await store.select("chosen-next") }
            try await waitUntil { api.pendingChats["chosen-next"] != nil }
            api.resolveDeletion(id: "delete-visible")
            let result = await deletion.value
            expect(result && store.selectedConversationID == nil && api.chatRequests == ["delete-visible", "chosen-next"],
                   "clearing the deleted visible transcript does not issue a duplicate fallback while unrelated navigation is pending")
            api.resolveChat(id: "chosen-next")
            await selection.value
            expect(store.selectedConversationID == "chosen-next",
                   "an unrelated pending selection remains authoritative after deletion of the previously visible row")
        }

        // Ordinary admission is one POST. Lost/uncertain responses resolve only
        // through the original owned CID, with actual production Store state.
        func status(_ phase: ChatJobPhase, _ text: String? = nil) -> ChatJobStatus {
            ChatJobStatus(phase: phase, text: text, reasoning: nil, error: nil,
                          status: nil, surface: nil, progress: nil)
        }
        do {
            let (session, api, store) = fixture()
            store.updateDraftText(exactDraft, expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let cid = await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingStarts.count == 1 }
            let chatID = store.selectedConversationID!
            api.receipts[cid] = ChatJobReceipt(jobId: "receipt-accepted", phase: .completed, cid: cid, chatId: chatID)
            api.statusResults = [status(.completed, "worker result")]
            api.failStart(APIError.transport(code: -1001, message: "synthetic response lost"))
            try await waitUntil { !store.isSending }
            expect(api.starts.count == 1 && api.receiptRequests == [cid], "lost ACK is reconciled by original CID GET without a second POST")
            expect(store.lastAcceptedSend?.cid == cid && store.draftText.isEmpty && store.messages.contains { $0.content == "worker result" },
                   "owned receipt accepts only the registered original draft and preserves the actual completed result")
            expect(api.operationScopes.allSatisfy { $0.cookie == "test-owned-cookie" } && session.identityGeneration == 0,
                   "ordinary admission, receipt and result share the original frozen credentials")
        }
        do {
            let (_, api, store) = fixture()
            store.updateDraftText(exactDraft, expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            store.updateDraftContext(originalDraftContext, expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let cid = await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.failStart(APIError.httpStatus(503, nil))
            try await waitUntil { store.canForgetUnavailableReceipt }
            expect(api.starts.count == 1 && api.receiptRequests == [cid, cid, cid] && store.lastAcceptedSend == nil,
                   "server error followed by unknown receipts performs bounded GET-only recovery and never fabricates acceptance")
            let duplicate = await store.send(text: "another request", tier: .pro, thinking: false, webSearch: false, language: .english)
            expect(duplicate == nil && store.draftText == exactDraft && store.draftContext == originalDraftContext && api.starts.count == 1,
                   "an unresolved admission blocks a fresh paid CID while retaining exact editable text and attachments")
            store.forgetUnavailableReceipt(cid: cid, expectedOwnerID: "owner-one", expectedIdentityGeneration: 1)
            expect(store.canForgetUnavailableReceipt && api.cancelledJobs.isEmpty, "queued local removal cannot cross an identity epoch")
            store.forgetUnavailableReceipt(cid: cid, expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            expect(!store.canForgetUnavailableReceipt && store.draftText == exactDraft && store.draftContext == originalDraftContext && api.cancelledJobs.isEmpty,
                   "explicit local removal preserves input and never issues Stop or deletes server history")
            let next = await store.send(text: "explicit new request", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            expect(next != cid && api.starts.count == 2, "only a new explicit user Send after removal receives a new admission CID")
            api.resolveStart(jobID: "explicit-after-forget", phase: .completed, text: "new answer")
            try await waitUntil { !store.isSending }
        }
        do {
            let session = SessionStore()
            let api = FirasAPI()
            let defaults = UserDefaults(suiteName: "firas-chat-uncertain-restore-" + UUID().uuidString)!
            let original = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                     guestTranscriptDirectory: guestDirectory())
            let cid = await original.send(text: "private original", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            let bytes = defaults.data(forKey: "firas.ios.active-chat-job.v1")!
            let pointer = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            expect(pointer["cid"] as? String == cid && pointer["jobID"] as? String == "", "original CID is present in the synthetic defaults suite before the sole admission suspends")
            api.failStart(APIError.httpStatus(408, nil))
            try await waitUntil { original.canForgetUnavailableReceipt }
            let restored = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                     guestTranscriptDirectory: guestDirectory())
            api.receipts[cid] = ChatJobReceipt(jobId: "after-relaunch", phase: .completed, cid: cid, chatId: pointer["serverChatID"] as? String)
            api.statusResults = [status(.completed, "recovered result")]
            await restored.resumeActiveJob()
            try await waitUntil { !restored.isSending && restored.activeCID == nil }
            expect(api.starts.count == 1 && api.receiptRequests == [cid, cid] && restored.messages.contains { $0.content == "recovered result" },
                   "Store reconstruction against the same synthetic defaults recovers pre-POST CID through reads without request reconstruction or admission replay")
        }
        do {
            let (_, api, store) = fixture()
            let cid = await store.send(text: "mismatch", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            api.receipts[cid] = ChatJobReceipt(jobId: "foreign-receipt", phase: .completed, cid: "different", chatId: store.selectedConversationID)
            api.failStart(APIError.httpStatus(409, nil))
            try await waitUntil { !store.isSending }
            expect(api.starts.count == 1 && store.lastAcceptedSend == nil && !store.canForgetUnavailableReceipt && api.statusRequests.isEmpty,
                   "mismatched CID receipt cannot accept a draft, authorize local removal or query another result")
        }
        do {
            let (_, api, store) = fixture()
            let cid = await store.send(text: "leave preserves work", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            let oldChatID = store.selectedConversationID!
            await store.select("reader-selected-another")
            api.receipts[cid] = ChatJobReceipt(jobId: "background-original", phase: .completed, cid: cid, chatId: oldChatID)
            api.statusResults = [status(.completed, "old cloud answer")]
            api.failStart(APIError.transport(code: -1005, message: "synthetic lost ACK"))
            try await waitUntil { !store.isSending }
            expect(api.starts.count == 1 && api.cancelledJobs.isEmpty && store.selectedConversationID == "reader-selected-another",
                   "navigation during uncertain admission keeps cloud work and cannot replace a newer conversation selection")
        }
        do {
            let (session, api, store) = fixture()
            let cid = await store.send(text: "old identity", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            api.delayReceipts = true
            api.failStart(APIError.transport(code: -1005, message: "synthetic lost ACK"))
            try await waitUntil { api.pendingReceipts.count == 1 }
            let shownBeforeReplacement = store.messages
            session.identityGeneration += 1
            store.synchronizeDraftOwner()
            api.pendingReceipts.removeFirst().resume(returning: ChatJobReceipt(jobId: "old-identity-job", phase: .completed,
                cid: cid, chatId: "created-1"))
            try await Task.sleep(for: .milliseconds(20))
            expect(store.lastAcceptedSend == nil && !shownBeforeReplacement.isEmpty && store.messages == shownBeforeReplacement &&
                   api.statusRequests.isEmpty && api.cancelledJobs.isEmpty,
                   "unsynchronized same-owner identity ABA rejects a delayed original-CID result before publication or control, keeping the owner's transcript")
        }
        do {
            let (_, api, store) = fixture()
            let cid = await store.send(text: "stop lost ACK", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            await store.stop()
            api.receipts[cid] = ChatJobReceipt(jobId: "stop-original-cid", phase: .processing, cid: cid, chatId: store.selectedConversationID)
            api.failStart(APIError.transport(code: -1001, message: "synthetic lost ACK"))
            try await waitUntil { !store.isSending }
            expect(api.starts.count == 1 && api.cancelledJobs == ["stop-original-cid"] && api.receiptRequests == [cid],
                   "Stop during a lost admission response first resolves original CID and cancels only its actual job ID")
        }
        do {
            let (_, api, store) = fixture()
            await store.send(text: "completion wins", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "completion-before-stop")
            try await waitUntil { store.activeJobID == "completion-before-stop" }
            api.statusResults = [status(.completed, "authoritative finished answer")]
            await store.stop()
            expect(api.cancelledJobs.isEmpty && store.messages.last?.content == "authoritative finished answer" && store.messages.last?.state == .delivered,
                   "terminal completion before a Stop preflight preserves final text and performs no cancel")
        }
        do {
            let (_, api, store) = fixture()
            await store.send(text: "Stop raced worker", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "cancel-completion-race")
            try await waitUntil { store.activeJobID == "cancel-completion-race" }
            api.statusResults = [status(.processing), status(.completed, "finished while cancelling")]
            api.cancelFailure = .httpStatus(409, nil)
            await store.stop()
            expect(api.cancelledJobs == ["cancel-completion-race"] && store.messages.last?.content == "finished while cancelling" && !store.isSending,
                   "cancel HTTP409 resolves terminal completion and keeps the actual final answer instead of silently retiring it")
        }
        do {
            let (_, api, store) = fixture()
            await store.send(text: "bounded Stop", tier: .pro, thinking: false, webSearch: false, language: .arabic)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "bounded-stop-original")
            try await waitUntil { store.activeJobID == "bounded-stop-original" }
            api.cancelFailure = .transport(code: -1001, message: "synthetic response lost")
            await store.stop()
            expect(api.cancelledJobs.count == 3 && !store.isSending && store.canReconnectActiveJob && !store.canForgetUnavailableReceipt &&
                   store.activeJobID == "bounded-stop-original" && api.starts.count == 1,
                   "failed Stop is bounded to three original-ID controls, retains its durable intent and leaves Reconnect instead of a stuck Stop")
            expect(store.errorMessage == "تعذّر تأكيد الإيقاف. لم يُرسَل الطلب الأصلي مرة أخرى.",
                   "unconfirmed Stop uses the original answer language rather than an English-only notice")
            let refused = await store.send(text: "while the Stop is unconfirmed", tier: .pro, thinking: false, webSearch: false, language: .arabic)
            expect(refused == nil && api.starts.count == 1 &&
                   store.errorMessage == "تعذّر تأكيد الرد الحالي. اضغط «التحقّق من الرد الأصلي» قبل إرسال طلب جديد.",
                   "Send after an unconfirmed Stop points to Reconnect instead of asking for another Stop")
            api.cancelFailure = nil
            await store.resumeActiveJob()
            try await waitUntil { !store.isSending && store.activeCID == nil }
            expect(api.cancelledJobs.count == 4 && api.starts.count == 1 && store.messages.last?.state == .stopped &&
                   !store.canReconnectActiveJob,
                   "Reconnect retries the saved Stop once and settles the stopped answer without admission replay")
        }
        do {
            let (session, api, store) = fixture()
            store.updateDraftText(exactDraft, expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            api.delayMediaCredentials = true
            await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingMediaCredentials.count == 1 }
            session.identityGeneration += 1
            api.pendingMediaCredentials.removeFirst().resume(returning: MediaCredentialSnapshot(
                origin: URL(string: "https://firasai.org")!, cookieHeader: "retired-cookie"))
            try await waitUntil { !store.isSending }
            expect(api.starts.isEmpty && api.updates.isEmpty && store.draftText == exactDraft,
                   "same-owner identity replacement during credential capture cannot mutate history or dispatch admission")
        }
        do {
            let (session, api, store) = fixture()
            await store.send(text: "old status", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.delayStatuses = true
            api.resolveStart(jobID: "old-epoch-status")
            try await waitUntil { api.pendingStatuses.count == 1 }
            let shownBeforeReplacement = store.messages
            session.identityGeneration += 1
            api.pendingStatuses.removeFirst().resume(returning: status(.completed, "stale completed private text"))
            try await waitUntil { !store.isSending }
            expect(store.messages == shownBeforeReplacement && !store.messages.contains { $0.content == "stale completed private text" } &&
                   store.activeJobID == nil && api.cancelledJobs.isEmpty,
                   "unsynchronized identity ABA rejects a late completed result and does not stop its original cloud job")
        }
        do {
            let (session, api, store) = fixture()
            await store.send(text: "old Stop", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "old-epoch-control")
            try await waitUntil { store.activeJobID == "old-epoch-control" }
            api.delayCancellation = true
            let control = Task { await store.stop() }
            try await waitUntil { api.pendingCancellations.count == 1 }
            let callsBeforeReplacement = api.statusRequests.count
            session.identityID = "owner-two"
            session.identityGeneration += 1
            store.synchronizeDraftOwner()
            api.pendingCancellations.removeFirst().resume(returning: CancelChatJobResponse(ok: true, stopped: true))
            await control.value
            expect(store.messages.isEmpty && api.statusRequests.count == callsBeforeReplacement && api.cancelledJobs == ["old-epoch-control"],
                   "late old-account Stop acknowledgement cannot query or publish through a replacement session")
            expect(api.operationScopes.allSatisfy { $0.cookie == "test-owned-cookie" },
                   "status and Stop transport carry the immutable original credential context across suspension")
        }
        do {
            let (_, api, store) = fixture()
            await store.send(text: "double Stop", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "one-control-reservation")
            try await waitUntil { store.activeJobID == "one-control-reservation" }
            api.delayMediaCredentials = true
            let first = Task { await store.stop() }
            try await waitUntil { api.pendingMediaCredentials.count == 1 }
            await store.stop()
            expect(api.pendingMediaCredentials.count == 1 && api.cancelledJobs.isEmpty,
                   "Stop reserves control before its credential await so a concurrent tap cannot create a second observer")
            api.pendingMediaCredentials.removeFirst().resume(returning: MediaCredentialSnapshot(
                origin: URL(string: "https://firasai.org")!, cookieHeader: "test-owned-cookie"))
            await first.value
            expect(api.cancelledJobs == ["one-control-reservation"] && !store.isSending,
                   "the exact original control reservation alone completes the server Stop")
        }
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("owned-first-chat")]
            await store.loadConversations()
            expect(store.selectedConversationID == "owned-first-chat" && api.historyReadScopes.map(\.route) == ["list", "chat"],
                   "member history loading selects the actual first ordinary conversation")
            expect(api.historyReadScopes.allSatisfy { $0.cookie == "test-owned-cookie" },
                   "history list and selected detail share one immutable verified credential context")
        }
        do {
            let (session, api, store) = fixture()
            api.listedChats = [summary("retired-list")]
            api.delayMediaCredentials = true
            let loading = Task { await store.loadConversations() }
            try await waitUntil { api.pendingMediaCredentials.count == 1 }
            session.identityGeneration += 1
            api.pendingMediaCredentials.removeFirst().resume(returning: MediaCredentialSnapshot(
                origin: URL(string: "https://firasai.org")!, cookieHeader: "retired-cookie"))
            await loading.value
            expect(api.historyReadScopes.isEmpty && store.conversations.isEmpty && store.selectedConversationID == nil && !store.isLoading,
                   "same-owner identity ABA during list credential capture rejects all old-session history GETs")
        }
        do {
            let (session, api, store) = fixture()
            await store.send(text: "completed old owner", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            NotificationCoordinator.shared.delayFallback = true
            api.statusResults = [status(.completed, "old completed answer")]
            api.resolveStart(jobID: "completion-notification-await")
            try await waitUntil { NotificationCoordinator.shared.pendingFallbacks.count == 1 }
            let readsBeforeReplacement = api.chatRequests.count
            let shownBeforeReplacement = store.messages
            session.identityGeneration += 1
            NotificationCoordinator.shared.delayFallback = false
            NotificationCoordinator.shared.pendingFallbacks.removeFirst().resume()
            try await waitUntil { !store.isSending }
            expect(api.chatRequests.count == readsBeforeReplacement && store.messages == shownBeforeReplacement && api.cancelledJobs.isEmpty,
                   "identity ABA during terminal notification await rejects canonical history dispatch and any later answer publication")
        }
        do {
            let (_, api, store) = fixture()
            await store.send(text: "first job", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            let oldStop = store.stopRequest()!
            api.resolveStart(jobID: "first-completed-job", phase: .completed)
            try await waitUntil { !store.isSending }
            let cid = await store.send(text: "replacement job", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            await store.stop(oldStop)
            expect(store.activeCID == cid && store.isSending && api.cancelledJobs.isEmpty,
                   "a queued Stop from a completed CID cannot stop the later job under the same account epoch")
            let replacementStop = store.stopRequest()!
            let cancelledControl = Task { await store.stop(replacementStop) }
            cancelledControl.cancel()
            await cancelledControl.value
            expect(store.activeCID == cid && store.isSending && api.cancelledJobs.isEmpty,
                   "a precancelled queued Stop cannot mutate or control its otherwise valid current target")
            api.resolveStart(jobID: "replacement-after-stale-stop", phase: .completed)
            try await waitUntil { !store.isSending }
        }
        do {
            let (session, api, store) = fixture()
            await store.send(text: "old epoch Stop", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            let oldStop = store.stopRequest()!
            session.identityGeneration += 1
            store.synchronizeDraftOwner()
            store.updateDraftText(exactDraft, expectedOwnerID: "owner-one", expectedIdentityGeneration: session.identityGeneration)
            let snapshot = store.snapshotDraft()!
            await store.stop(oldStop)
            expect(store.snapshotDraft() == snapshot && store.draftText == exactDraft && api.cancelledJobs.isEmpty,
                   "a queued Stop from a retired same-owner epoch cannot retire or consume the replacement editable draft")
            api.resolveStart(jobID: "old-epoch-cloud-job")
        }
        do {
            let session = SessionStore()
            let api = FirasAPI()
            let defaults = UserDefaults(suiteName: "firas-chat-stop-during-resume-credentials-" + UUID().uuidString)!
            let original = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                     guestTranscriptDirectory: guestDirectory())
            await original.send(text: "durable before reopen", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "resume-credentials-original")
            try await waitUntil { original.activeJobID == "resume-credentials-original" }
            session.identityID = "owner-away"
            original.synchronizeDraftOwner()
            session.identityID = "owner-one"
            let restored = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                     guestTranscriptDirectory: guestDirectory())
            api.delayMediaCredentials = true
            let resuming = Task { await restored.resumeActiveJob() }
            try await waitUntil { api.pendingMediaCredentials.count == 1 }
            await restored.stop()
            expect(api.cancelledJobs.isEmpty && api.pendingMediaCredentials.count == 1,
                   "Stop during restore credential capture records intent without creating a second preparation")
            api.pendingMediaCredentials.removeFirst().resume(returning: MediaCredentialSnapshot(
                origin: URL(string: "https://firasai.org")!, cookieHeader: "test-owned-cookie"))
            await resuming.value
            try await waitUntil { !restored.isSending }
            expect(api.cancelledJobs == ["resume-credentials-original"] && api.starts.count == 1 && restored.activeCID == nil,
                   "restored observation consumes Stop recorded during credential capture and cancels only the original receipt")
        }
        do {
            let session = SessionStore()
            let api = FirasAPI()
            let defaults = UserDefaults(suiteName: "firas-chat-stop-during-resume-history-" + UUID().uuidString)!
            let original = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                     guestTranscriptDirectory: guestDirectory())
            await original.send(text: "durable before history reopen", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "resume-history-original")
            try await waitUntil { original.activeJobID == "resume-history-original" }
            let chatID = original.selectedConversationID!
            session.identityID = "owner-away"
            original.synchronizeDraftOwner()
            session.identityID = "owner-one"
            let restored = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                     guestTranscriptDirectory: guestDirectory())
            api.delayedChatIDs = [chatID]
            let resuming = Task { await restored.resumeActiveJob() }
            try await waitUntil { api.pendingChats[chatID] != nil }
            await restored.stop()
            await restored.resumeActiveJob()
            expect(api.cancelledJobs.isEmpty && api.pendingChats.count == 1,
                   "Stop during the single restored history GET cannot launch a overlapping watcher or cancel before ID resolution")
            api.resolveChat(id: chatID)
            await resuming.value
            try await waitUntil { !restored.isSending }
            expect(api.cancelledJobs == ["resume-history-original"] && api.starts.count == 1 && restored.activeCID == nil,
                   "Stop written during canonical history await survives the captured pre-Stop restore snapshot")
        }
        do {
            let (_, api, store) = fixture()
            await store.send(text: "known control recovery", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "known-id-recovery")
            try await waitUntil { store.activeJobID == "known-id-recovery" }
            api.cancelFailure = .transport(code: -1001, message: "synthetic Stop response lost")
            await store.stop()
            api.cancelFailure = nil
            api.delayMediaCredentials = true
            let resuming = Task { await store.resumeActiveJob() }
            try await waitUntil { api.pendingMediaCredentials.count == 1 }
            let stopping = Task { await store.stop() }
            try await waitUntil { api.pendingMediaCredentials.count == 2 }
            let readsBeforeResolution = api.chatRequests.count
            api.pendingMediaCredentials.removeFirst().resume(returning: MediaCredentialSnapshot(
                origin: URL(string: "https://firasai.org")!, cookieHeader: "test-owned-cookie"))
            await resuming.value
            expect(api.chatRequests.count == readsBeforeResolution && api.pendingMediaCredentials.count == 1,
                   "known-ID restore cannot dispatch history or register a watcher over the exact active Stop preparation")
            api.pendingMediaCredentials.removeFirst().resume(returning: MediaCredentialSnapshot(
                origin: URL(string: "https://firasai.org")!, cookieHeader: "test-owned-cookie"))
            await stopping.value
            expect(api.cancelledJobs.count == 4 && api.starts.count == 1 && !store.isSending,
                   "the original known-ID Stop preparation completes alone after an overlapping restore is retired")
        }
        // An uncertain admission whose receipt reads all failed used to leave
        // no control at all: Send refused, nothing retried. Reconnect is now
        // offered; local removal still needs a receipt proved missing.
        do {
            let (_, api, store) = fixture()
            store.updateDraftText(exactDraft, expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let cid = await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.receiptFailure = .transport(code: -1009, message: "synthetic offline")
            api.failStart(APIError.transport(code: -1001, message: "synthetic timeout"))
            try await waitUntil { store.canReconnectActiveJob }
            expect(api.receiptRequests == [cid, cid, cid] && !store.isSending && store.reconnectableReceiptCID == cid &&
                   store.unavailableReceiptCID == nil && !store.canForgetUnavailableReceipt,
                   "an uncertain send whose receipt reads all failed offers Reconnect but never local removal")
            expect(store.errorMessage == "The original answer could not be confirmed. It has not been sent again." &&
                   store.displayedMessage(store.messages.last!).content == "Answer not confirmed.",
                   "while the banner says the unconfirmed sentence, the row names only its state instead of repeating it")
            let refused = await store.send(text: "another request", tier: .pro, thinking: false, webSearch: false, language: .english)
            expect(refused == nil && api.starts.count == 1 && store.draftText == exactDraft &&
                   store.errorMessage == "The current answer could not be confirmed. Tap “Check original answer” before sending a new request.",
                   "the refused Send names the Reconnect control and keeps the editable draft")
            store.errorMessage = nil
            let admission = store.difficultyAdmission(for: store.snapshotDraft()!, language: .english)
            expect(admission == nil && api.classificationCount == 1 &&
                   store.errorMessage == "The current answer could not be confirmed. Tap “Check original answer” before sending a new request.",
                   "the screen's admission check refuses with the same reason before any classifier call")
            let media = await store.prepareMediaTurn(prompt: "media while unconfirmed", tier: .pro,
                language: .arabic, expectedOwnerID: "owner-one")
            expect(media == nil && api.updates.count == 1 &&
                   store.errorMessage == "تعذّر تأكيد الرد الحالي. اضغط «التحقّق من الرد الأصلي» قبل إرسال طلب جديد.",
                   "a media request is refused with the same reason instead of silently")
            let unobserved = store.messages.last!
            expect(unobserved.state == .sending && unobserved.content.isEmpty &&
                   store.displayedMessage(unobserved).content == "The original answer could not be confirmed. It has not been sent again.",
                   "the empty answer nothing observes is drawn with the unconfirmed notice, not a spinner, and the stored row is unchanged")
            let deletion = store.deletionRequest(id: store.selectedConversationID!, title: "unconfirmed")!
            let deleted = await store.delete(deletion, language: .english)
            expect(!deleted && api.deletedChatIDs.isEmpty &&
                   store.errorMessage == "The current answer could not be confirmed. Tap “Check original answer” before deleting this chat.",
                   "deleting the chat of an unconfirmed answer names Reconnect rather than a Stop that is not shown")
            api.receiptFailure = nil
            api.receipts[cid] = ChatJobReceipt(jobId: "reconnected-job", phase: .processing, cid: cid, chatId: store.selectedConversationID)
            api.statusResults = [status(.completed, "reconnected answer")]
            await store.resumeActiveJob()
            try await waitUntil { !store.isSending && store.activeCID == nil }
            expect(api.starts.count == 1 && store.messages.last?.content == "reconnected answer" &&
                   store.messages.last?.state == .delivered && !store.canReconnectActiveJob && store.errorMessage == nil &&
                   store.displayedMessage(store.messages.last!) == store.messages.last!,
                   "Reconnect re-reads the original receipt, shows its answer and retires the notice without a second admission")
            expect(store.lastAcceptedSend?.cid == cid && store.draftText.isEmpty,
                   "the reconnected acceptance consumes only the registered original draft")
        }
        // Returning to the app does what Reconnect does, in the job's own
        // chat, without moving the reader out of the conversation they opened.
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("reading-chat")]
            await store.loadConversations()
            await store.new()
            let jobChat = store.selectedConversationID!
            let cid = await store.send(text: "answer while away", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            api.receiptFailure = .transport(code: -1009, message: "synthetic offline")
            api.failStart(APIError.transport(code: -1005, message: "synthetic lost ACK"))
            try await waitUntil { store.canReconnectActiveJob }
            await store.select("reading-chat")
            api.receiptFailure = nil
            api.receipts[cid] = ChatJobReceipt(jobId: "activation-job", phase: .processing, cid: cid, chatId: jobChat)
            api.statusResults = [status(.completed, "finished while away")]
            await store.resumeAfterActivation()
            try await waitUntil { !store.isSending && store.activeCID == nil }
            expect(store.selectedConversationID == "reading-chat" && api.starts.count == 1 && api.cancelledJobs.isEmpty &&
                   api.receiptRequests.filter { $0 == cid }.count == 4 && !store.canReconnectActiveJob,
                   "becoming active re-observes the unconfirmed answer in its own chat without moving the reader or sending again")
            let next = await store.send(text: "after returning", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            expect(next != nil && api.starts.count == 2, "the recovered answer releases Send")
            api.resolveStart(jobID: "after-activation", phase: .completed, text: "next answer")
            try await waitUntil { !store.isSending }
            await store.resumeAfterActivation()
            expect(api.receiptRequests.filter { $0 == cid }.count == 4 && api.starts.count == 2,
                   "becoming active with nothing saved reads nothing")
        }
        // The server prunes a finished job after six hours and then answers
        // "unknown". That must never turn the saved answer back into a
        // spinner; the saved chat is read before any receipt recovery.
        do {
            let session = SessionStore()
            let api = FirasAPI()
            let defaults = UserDefaults(suiteName: "firas-chat-pruned-job-" + UUID().uuidString)!
            let original = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                     guestTranscriptDirectory: guestDirectory())
            let cid = await original.send(text: "answer finished overnight", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "pruned-overnight")
            try await waitUntil { original.activeJobID == "pruned-overnight" }
            let chatID = original.selectedConversationID!
            session.identityID = "owner-away"
            original.synchronizeDraftOwner()
            session.identityID = "owner-one"
            var saved = api.chats[chatID]!
            saved.messages.append(ChatMessage(role: .assistant, content: "the finished overnight answer", cid: cid))
            api.chats[chatID] = saved
            api.delayStatuses = true
            let restored = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                     guestTranscriptDirectory: guestDirectory())
            await restored.resumeActiveJob()
            try await waitUntil { api.pendingStatuses.count == 1 }
            let shown = restored.messages.last
            expect(shown?.content == "the finished overnight answer" && shown?.state == .delivered && restored.isSending,
                   "restoring shows the answer saved in the chat while its job is checked again")
            api.pendingStatuses.removeFirst().resume(returning: status(.unknown))
            try await waitUntil { api.pendingStatuses.count == 1 }
            expect(restored.messages.last == shown, "an unknown status never turns the saved finished answer back into a running one")
            api.delayStatuses = false
            api.statusResults = [status(.unknown)]
            api.pendingStatuses.removeFirst().resume(returning: status(.unknown))
            try await waitUntil { !restored.isSending && restored.activeCID == nil }
            expect(restored.messages.last?.content == "the finished overnight answer" && restored.messages.last?.state == .delivered &&
                   api.receiptRequests.isEmpty && defaults.data(forKey: "firas.ios.active-chat-job.v1") == nil &&
                   !restored.canReconnectActiveJob && restored.errorMessage == nil,
                   "a pruned job whose answer is in the saved chat is adopted as complete and its record cleared, without receipt recovery")
        }
        // An uncertain send's receipt is pruned with its finished job too. The
        // answer filed in the saved chat proves the admission and is adopted,
        // instead of Reconnect and Remove offered beneath a finished answer.
        do {
            let session = SessionStore()
            let api = FirasAPI()
            let defaults = UserDefaults(suiteName: "firas-chat-pruned-receipt-" + UUID().uuidString)!
            let original = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                     guestTranscriptDirectory: guestDirectory())
            let cid = await original.send(text: "uncertain overnight", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            let chatID = original.selectedConversationID!
            api.receiptFailure = .transport(code: -1009, message: "synthetic offline")
            api.failStart(APIError.transport(code: -1001, message: "synthetic timeout"))
            try await waitUntil { original.canReconnectActiveJob }
            api.receiptFailure = nil
            var saved = api.chats[chatID]!
            saved.messages.append(ChatMessage(role: .assistant, content: "the answer filed overnight", cid: cid))
            api.chats[chatID] = saved
            let restored = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                     guestTranscriptDirectory: guestDirectory())
            await restored.resumeActiveJob()
            try await waitUntil { !restored.isSending && restored.activeCID == nil }
            expect(restored.messages.last?.content == "the answer filed overnight" && restored.messages.last?.state == .delivered &&
                   !restored.canReconnectActiveJob && !restored.canForgetUnavailableReceipt && restored.errorMessage == nil &&
                   defaults.data(forKey: "firas.ios.active-chat-job.v1") == nil && api.starts.count == 1 && api.statusRequests.isEmpty,
                   "a receipt pruned with its finished job adopts the saved answer and clears the record, without Reconnect beneath it")
            let next = await restored.send(text: "after the adopted answer", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            expect(next != nil && api.starts.count == 2, "the adopted answer releases Send")
            api.resolveStart(jobID: "after-adopted-receipt", phase: .completed, text: "next answer")
            try await waitUntil { !restored.isSending }
        }
        // A guest has no saved chat, so the receipt decides. Removing the
        // proven-missing receipt keeps any answer text already shown.
        do {
            let (session, api, store) = fixture()
            session.isAuthenticated = false
            session.identityID = "guest-pruned"
            await store.loadConversations()
            let cid = await store.send(text: "guest long request", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            api.statusResults = [status(.processing, "partial answer before suspension"),
                                 status(.unknown), status(.unknown), status(.unknown)]
            api.resolveStart(jobID: "guest-pruned-job")
            try await waitUntil { store.canForgetUnavailableReceipt }
            expect(store.canReconnectActiveJob && store.messages.last?.content == "partial answer before suspension" &&
                   api.receiptRequests == [cid, cid, cid] && api.chatRequests.isEmpty,
                   "a guest's unknown job reads no saved chat and is decided by its receipt")
            store.forgetUnavailableReceipt(cid: cid, expectedOwnerID: "guest-pruned", expectedIdentityGeneration: 0)
            expect(store.messages.last?.content == "partial answer before suspension" && store.messages.last?.state == .delivered &&
                   !store.canReconnectActiveJob && store.activeCID == nil,
                   "removing a proven-missing receipt never marks an answer that has content as failed")
        }
        // A guest taps Stop on a weak connection and comes back the next day,
        // after the server pruned the job: its status is "unknown" and Stop
        // answers 404. Together they prove nothing is left to stop.
        do {
            let (session, api, store) = fixture()
            session.isAuthenticated = false
            session.identityID = "guest-pruned-stop"
            await store.loadConversations()
            let guestChatID = store.selectedConversationID
            await store.send(text: "guest Stop overnight", tier: .pro, thinking: false, webSearch: false, language: .arabic)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "guest-pruned-stop-job")
            try await waitUntil { store.activeJobID == "guest-pruned-stop-job" && api.statusRequests.count == 1 }
            api.cancelFailure = .transport(code: -1001, message: "synthetic weak connection")
            await store.stop()
            expect(store.canReconnectActiveJob && !store.isSending && api.cancelledJobs.count == 3,
                   "the unconfirmed guest Stop leaves Reconnect instead of a stuck Stop")
            await store.new()
            expect(store.selectedConversationID == guestChatID &&
                   store.errorMessage == "تعذّر تأكيد الرد الحالي. اضغط «التحقّق من الرد الأصلي» قبل بدء محادثة ضيف جديدة.",
                   "a guest's New chat refused meanwhile names Reconnect, not the hidden Stop")
            api.statusResults = [status(.unknown)]
            api.cancelFailure = .httpStatus(404, nil)
            await store.resumeAfterActivation()
            try await waitUntil { !store.isSending && store.activeCID == nil }
            expect(store.messages.last?.state == .stopped && !store.canReconnectActiveJob && store.activeJobID == nil &&
                   store.errorMessage == nil && api.cancelledJobs.count == 4 && api.starts.count == 1,
                   "an unknown status and a 404 Stop settle the stopped answer instead of retrying forever")
            api.cancelFailure = nil
            let next = await store.send(text: "after the pruned Stop", tier: .pro, thinking: false, webSearch: false, language: .arabic)
            try await waitUntil { api.pendingStarts.count == 1 }
            expect(next != nil && api.starts.count == 2, "the settled Stop releases Send for a second admission")
            api.resolveStart(jobID: "after-pruned-stop", phase: .completed, text: "next answer")
            try await waitUntil { !store.isSending }
        }
        // A member's pruned job may have filed its answer in the saved chat:
        // that answer outranks the Stop and is read before the 404 exit.
        do {
            let (_, api, store) = fixture()
            let cid = await store.send(text: "member Stop overnight", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "member-pruned-stop-job")
            try await waitUntil { store.activeJobID == "member-pruned-stop-job" && api.statusRequests.count == 1 }
            let chatID = store.selectedConversationID!
            var saved = api.chats[chatID]!
            saved.messages.append(ChatMessage(role: .assistant, content: "the answer filed before the Stop", cid: cid))
            api.chats[chatID] = saved
            api.statusResults = [status(.unknown)]
            api.cancelFailure = .httpStatus(404, nil)
            await store.stop()
            expect(store.activeCID == nil && !store.isSending && api.cancelledJobs.isEmpty && !store.canReconnectActiveJob &&
                   store.messages.last?.content == "the answer filed before the Stop" && store.messages.last?.state == .delivered,
                   "a pruned member job whose answer is saved is adopted before any Stop is sent")
        }
        // A resumed record carries its rows' states: an earlier failed guest
        // turn stays failed, and the running row keeps running.
        do {
            let (session, api, store) = fixture()
            session.isAuthenticated = false
            session.identityID = "guest-states"
            await store.loadConversations()
            await store.send(text: "guest refused turn", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.failStart(APIError.httpStatus(400, nil))
            try await waitUntil { !store.isSending }
            await store.send(text: "guest running turn", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.delayStatuses = true
            api.resolveStart(jobID: "guest-states-job")
            try await waitUntil { api.pendingStatuses.count == 1 }
            session.isWorking = true
            session.identityGeneration += 1
            store.synchronizeDraftOwner()
            api.pendingStatuses.removeFirst().resume(returning: status(.processing))
            try await Task.sleep(for: .milliseconds(20))
            session.isWorking = false
            await store.reloadAfterSessionOperationIfNeeded()
            try await waitUntil { api.pendingStatuses.count == 1 }
            let resumedStates: [ChatMessageState] = [.delivered, .failed, .delivered, .sending]
            expect(store.messages.map(\.state) == resumedStates && store.isSending,
                   "re-observing a guest's saved job keeps the earlier failed turn failed and the running row running")
            api.delayStatuses = false
            api.pendingStatuses.removeFirst().resume(returning: status(.completed, "guest running answer"))
            try await waitUntil { !store.isSending && store.activeCID == nil }
            let finishedStates: [ChatMessageState] = [.delivered, .failed, .delivered, .delivered]
            expect(store.messages.map(\.state) == finishedStates && store.messages.last?.content == "guest running answer",
                   "finishing the re-observed job keeps every earlier row's own state")
        }
        // A guest's transcript lives only on this device and survives the app
        // being closed: thumbnails, no full images or file text, within a cap.
        func transcriptURL(_ directory: URL) -> URL { directory.appendingPathComponent("transcript.json") }
        func guestFile(_ directory: URL) -> [String: Any]? {
            guard let data = try? Data(contentsOf: transcriptURL(directory)) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        do {
            let directory = guestDirectory()
            let session = SessionStore()
            session.isAuthenticated = false
            session.identityID = "guest-keep"
            let api = FirasAPI()
            let defaults = UserDefaults(suiteName: "firas-chat-guest-transcript-" + UUID().uuidString)!
            let first = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                  guestTranscriptDirectory: directory)
            await first.loadConversations()
            let guestChatID = first.selectedConversationID!
            let photo = PreparedChatContext(fullImages: ["full-image-bytes"], imageThumbnails: ["thumb-bytes"],
                files: [ChatAttachment(name: "notes.txt", kind: "text")], fileText: "private file text")
            await first.send(text: "guest photo request", tier: .pro, thinking: false, webSearch: false,
                             language: .english, context: photo)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "guest-kept", phase: .completed, text: "guest kept answer")
            try await waitUntil { !first.isSending }
            await first.send(text: "guest failed follow-up", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.failStart(APIError.httpStatus(400, nil))
            try await waitUntil { !first.isSending }
            try await waitUntil { (guestFile(directory)?["messages"] as? [[String: Any]])?.count == 4 }
            let stored = guestFile(directory)!
            let rows = stored["messages"] as! [[String: Any]]
            let storedStates: [String] = ["delivered", "delivered", "delivered", "failed"]
            let storedThumbs: [String] = ["thumb-bytes"]
            let ownedCopy = stored["ownerID"] as? String == "guest-keep" && stored["conversationID"] as? String == guestChatID
            let storedFileName = (rows[0]["files"] as? [[String: Any]])?.first?["name"] as? String
            let lightRow = rows[0]["imageThumbs"] as? [String] == storedThumbs && rows[0]["images"] == nil && rows[0]["fileText"] == nil
            expect(ownedCopy && lightRow && storedFileName == "notes.txt" && stored["states"] as? [String] == storedStates,
                   "the device copy keeps thumbnails, attachment names and states but no full image or file text")
            let backup = try transcriptURL(directory).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            expect(backup == true, "the guest copy is excluded from backup")
            let relaunched = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                       guestTranscriptDirectory: directory)
            await relaunched.loadConversations()
            let restoredStates: [ChatMessageState] = [.delivered, .delivered, .delivered, .failed]
            let restoredPhoto = relaunched.messages.first
            expect(relaunched.selectedConversationID == guestChatID &&
                   relaunched.messages.map(\.content) == first.messages.map(\.content) &&
                   relaunched.messages.map(\.state) == restoredStates && api.historyReadScopes.isEmpty,
                   "a relaunch for the same guest restores the transcript and its states from the device copy")
            expect(restoredPhoto?.imageThumbs == storedThumbs && restoredPhoto?.images == nil && restoredPhoto?.fileText == nil,
                   "the restored photo turn shows its thumbnail without the full image or file text")
            await relaunched.new()
            try await waitUntil { !FileManager.default.fileExists(atPath: transcriptURL(directory).path) }
            expect(relaunched.messages.isEmpty && relaunched.selectedConversationID != guestChatID,
                   "an explicit New chat starts empty and clears the device copy")
        }
        do {
            let directory = guestDirectory()
            let session = SessionStore()
            session.isAuthenticated = false
            session.identityID = "guest-large"
            let api = FirasAPI()
            let defaults = UserDefaults(suiteName: "firas-chat-guest-cap-" + UUID().uuidString)!
            let store = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                  guestTranscriptDirectory: directory)
            await store.loadConversations()
            for (index, turn) in ["turn one", "turn two", "turn three"].enumerated() {
                await store.send(text: turn, tier: .pro, thinking: false, webSearch: false, language: .english)
                try await waitUntil { api.pendingStarts.count == 1 }
                api.resolveStart(jobID: "large-turn-\(index)", phase: .completed, text: String(repeating: "a", count: 400_000))
                try await waitUntil { !store.isSending }
            }
            try await waitUntil {
                (guestFile(directory)?["messages"] as? [[String: Any]])?.first?["content"] as? String == "turn two"
            }
            let size = try transcriptURL(directory).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
            let relaunched = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                       guestTranscriptDirectory: directory)
            await relaunched.loadConversations()
            expect(size <= 1_000_000 && store.messages.count == 6 && relaunched.messages.count == 4 &&
                   relaunched.messages.first?.content == "turn two" && relaunched.messages.last?.content.count == 400_000,
                   "the device copy keeps the newest whole turns within its size cap while the screen keeps them all")
        }
        // One turn over the cap must not cost every earlier turn: a long turn
        // gives up its stored reasoning first, and a turn larger than the
        // whole file is left out on its own.
        do {
            let directory = guestDirectory()
            let session = SessionStore()
            session.isAuthenticated = false
            session.identityID = "guest-oversized"
            let api = FirasAPI()
            let store = ChatStore(session: session, api: api,
                                  defaults: UserDefaults(suiteName: "firas-chat-guest-oversized-" + UUID().uuidString)!,
                                  recoveryDelays: [], guestTranscriptDirectory: directory)
            await store.loadConversations()
            await store.send(text: "short turn", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "short-turn", phase: .completed, text: "short answer")
            try await waitUntil { !store.isSending }
            await store.send(text: "reasoned turn", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.statusResults = [ChatJobStatus(phase: .completed, text: String(repeating: "b", count: 600_000),
                reasoning: String(repeating: "r", count: 600_000), error: nil, status: nil, surface: nil, progress: nil)]
            api.resolveStart(jobID: "reasoned-turn")
            try await waitUntil { !store.isSending }
            try await waitUntil { (guestFile(directory)?["messages"] as? [[String: Any]])?.count == 4 }
            let reasoned = (guestFile(directory)?["messages"] as? [[String: Any]])?.last
            expect((reasoned?["content"] as? String)?.count == 600_000 && reasoned?["reasoning"] == nil &&
                   store.messages.last?.reasoning?.count == 600_000,
                   "a turn over the cap keeps its answer on the device and gives up only the stored reasoning")
            await store.send(text: "oversized turn", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "oversized-turn", phase: .completed, text: String(repeating: "c", count: 1_100_000))
            try await waitUntil { !store.isSending }
            try await waitUntil { (guestFile(directory)?["messages"] as? [[String: Any]])?.count == 5 }
            let rows = guestFile(directory)?["messages"] as? [[String: Any]] ?? []
            let size = try transcriptURL(directory).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
            expect(rows.first?["content"] as? String == "short turn" && rows.last?["content"] as? String == "oversized turn" &&
                   size <= 1_000_000 && store.messages.count == 6,
                   "a turn larger than the whole file is left out alone, and every earlier turn stays on the device")
        }
        do {
            let directory = guestDirectory()
            let session = SessionStore()
            session.isAuthenticated = false
            session.identityID = "guest-old"
            let api = FirasAPI()
            let store = ChatStore(session: session, api: api,
                                  defaults: UserDefaults(suiteName: "firas-chat-guest-owner-" + UUID().uuidString)!,
                                  recoveryDelays: [], guestTranscriptDirectory: directory)
            await store.loadConversations()
            await store.send(text: "old guest request", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "old-guest-job", phase: .completed, text: "old guest answer")
            try await waitUntil { FileManager.default.fileExists(atPath: transcriptURL(directory).path) }
            let otherSession = SessionStore()
            otherSession.isAuthenticated = false
            otherSession.identityID = "guest-new"
            let otherGuest = ChatStore(session: otherSession, api: api,
                                       defaults: UserDefaults(suiteName: "firas-chat-guest-other-" + UUID().uuidString)!,
                                       recoveryDelays: [], guestTranscriptDirectory: directory)
            await otherGuest.loadConversations()
            expect(otherGuest.messages.isEmpty && !FileManager.default.fileExists(atPath: transcriptURL(directory).path),
                   "another guest identity never sees the device copy, which is removed")
        }
        do {
            let directory = guestDirectory()
            let session = SessionStore()
            session.isAuthenticated = false
            session.identityID = "guest-replaced"
            let api = FirasAPI()
            let store = ChatStore(session: session, api: api,
                                  defaults: UserDefaults(suiteName: "firas-chat-guest-replaced-" + UUID().uuidString)!,
                                  recoveryDelays: [], guestTranscriptDirectory: directory)
            await store.loadConversations()
            await store.send(text: "replaced guest request", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "replaced-guest-job", phase: .completed, text: "replaced guest answer")
            try await waitUntil { FileManager.default.fileExists(atPath: transcriptURL(directory).path) }
            session.identityID = "guest-replacement"
            await store.loadConversations()
            try await waitUntil { !FileManager.default.fileExists(atPath: transcriptURL(directory).path) }
            expect(store.messages.isEmpty, "a replacement guest identity in the running app clears the previous guest's copy")
        }
        do {
            let directory = guestDirectory()
            let session = SessionStore()
            session.isAuthenticated = false
            session.identityID = "guest-signing-in"
            let api = FirasAPI()
            let store = ChatStore(session: session, api: api,
                                  defaults: UserDefaults(suiteName: "firas-chat-guest-member-" + UUID().uuidString)!,
                                  recoveryDelays: [], guestTranscriptDirectory: directory)
            await store.loadConversations()
            await store.send(text: "before signing in", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "before-sign-in", phase: .completed, text: "guest answer before sign-in")
            try await waitUntil { FileManager.default.fileExists(atPath: transcriptURL(directory).path) }
            session.isAuthenticated = true
            session.identityID = "member-after-guest"
            store.synchronizeDraftOwner()
            try await waitUntil { !FileManager.default.fileExists(atPath: transcriptURL(directory).path) }
            await store.loadConversations()
            await store.send(text: "member request", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "member-after-guest-job", phase: .completed, text: "member answer")
            try await waitUntil { !store.isSending }
            try await Task.sleep(for: .milliseconds(30))
            expect(!FileManager.default.fileExists(atPath: transcriptURL(directory).path) &&
                   store.messages.last?.content == "member answer",
                   "signing in as a member clears the guest copy, and a member's chats are never written there")
        }
        // Every session operation starts a new epoch, even a closed Google
        // sheet, a failed login, a refresh or an export. The same owner keeps
        // its list and transcript; only in-flight work is fenced and re-read.
        do {
            let (session, api, store) = fixture()
            session.isAuthenticated = false
            session.identityID = "guest-one"
            await store.loadConversations()
            let guestChatID = store.selectedConversationID
            await store.send(text: "guest greeting", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.resolveStart(jobID: "guest-finished", phase: .completed, text: "guest answer")
            try await waitUntil { !store.isSending }
            await store.send(text: "guest follow-up", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.delayStatuses = true
            api.resolveStart(jobID: "guest-streaming")
            try await waitUntil { api.pendingStatuses.count == 1 }
            let transcript = store.messages
            expect(guestChatID?.hasPrefix("guest-") == true &&
                   transcript.map(\.content) == ["guest greeting", "guest answer", "guest follow-up", ""],
                   "the guest holds an unsaved in-memory transcript with one streaming answer")
            session.isWorking = true
            session.identityGeneration += 1 // the system Google account picker was closed
            store.synchronizeDraftOwner()
            expect(store.selectedConversationID == guestChatID && store.messages == transcript &&
                   !store.isSending && store.activeJobID == nil,
                   "a same-guest epoch fences the streaming observer but keeps the unsaved transcript")
            api.pendingStatuses.removeFirst().resume(returning: status(.processing, "fenced partial"))
            try await Task.sleep(for: .milliseconds(20))
            expect(store.messages == transcript, "the fenced guest observer publishes nothing")
            api.delayStatuses = false
            api.statusResults = [status(.completed, "guest follow-up answer")]
            session.isWorking = false
            await store.reloadAfterSessionOperationIfNeeded()
            try await waitUntil { !store.isSending && store.activeCID == nil }
            expect(store.selectedConversationID == guestChatID &&
                   store.messages.map(\.content) == ["guest greeting", "guest answer", "guest follow-up", "guest follow-up answer"] &&
                   store.messages.last?.state == .delivered && api.historyReadScopes.isEmpty && api.starts.count == 2,
                   "ending the operation re-observes the guest's saved job inside the kept transcript without a second admission")
        }
        do {
            let (session, api, store) = fixture()
            api.listedChats = [summary("owner-one-history")]
            await store.loadConversations()
            expect(store.selectedConversationID == "owner-one-history" && store.conversations.count == 1,
                   "the member has a loaded list and an open conversation")
            session.isWorking = true
            session.identityGeneration += 1
            store.synchronizeDraftOwner()
            expect(store.conversations.map(\.id) == ["owner-one-history"] && store.selectedConversationID == "owner-one-history",
                   "the same member's refresh epoch keeps the list and the open conversation")
            session.identityID = "owner-two"
            store.synchronizeDraftOwner()
            expect(store.conversations.isEmpty && store.selectedConversation == nil && store.messages.isEmpty,
                   "an actual account change still clears the previous owner's list and transcript")
            session.isWorking = false
            api.listedChats = [summary("owner-two-history")]
            await store.loadConversations()
            await store.reloadAfterSessionOperationIfNeeded()
            expect(store.conversations.map(\.id) == ["owner-two-history"] && store.selectedConversationID == "owner-two-history" &&
                   api.historyReadScopes.filter { $0.route == "list" }.count == 2,
                   "the new account is loaded once by its identity load, not again when the operation ends")
        }
        do {
            let (session, _, store) = fixture()
            session.isAuthenticated = false
            session.identityID = "guest-two"
            await store.loadConversations()
            let guestChatID = store.selectedConversationID
            session.isWorking = true
            session.identityGeneration += 1
            store.synchronizeDraftOwner()
            expect(guestChatID != nil && store.selectedConversationID == guestChatID,
                   "the guest transcript survives the start of a sign-in")
            session.identityID = "member-after-google"
            session.isAuthenticated = true
            store.synchronizeDraftOwner()
            expect(store.selectedConversation == nil && store.conversations.isEmpty,
                   "a completed sign-in into another identity never shows the guest transcript under the member")
            session.isWorking = false
        }
        do {
            let (session, api, store) = fixture()
            api.listedChats = [summary("running-chat")]
            await store.loadConversations()
            let cid = await store.send(text: "long answer", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            api.delayStatuses = true
            api.resolveStart(jobID: "fenced-member-job")
            try await waitUntil { api.pendingStatuses.count == 1 }
            session.isWorking = true
            session.identityGeneration += 1 // pull-to-refresh the account, or export chats
            store.synchronizeDraftOwner()
            expect(store.conversations.map(\.id) == ["running-chat"] && store.selectedConversationID == "running-chat" &&
                   store.messages.last?.cid == cid && !store.isSending && store.activeJobID == nil,
                   "a same-member settings epoch fences the answer observer but keeps the list and open transcript")
            api.pendingStatuses.removeFirst().resume(returning: status(.processing, "fenced partial"))
            try await Task.sleep(for: .milliseconds(20))
            await store.reloadAfterSessionOperationIfNeeded()
            expect(!store.messages.contains { $0.content == "fenced partial" } &&
                   api.historyReadScopes.filter { $0.route == "list" }.count == 1,
                   "the fenced observer publishes nothing and no reload runs while the operation is still working")
            session.isWorking = false
            api.delayStatuses = false
            let refused = await store.send(text: "before reload", tier: .pro, thinking: false, webSearch: false, language: .english)
            expect(refused == nil && api.starts.count == 1, "the saved receipt still blocks a second paid send until it is observed again")
            api.listedChats = [summary("running-chat"), summary("imported-chat")]
            api.statusResults = [status(.completed, "finished after refresh")]
            await store.reloadAfterSessionOperationIfNeeded()
            try await waitUntil { !store.isSending && store.activeCID == nil }
            expect(store.conversations.map(\.id) == ["running-chat", "imported-chat"] && store.selectedConversationID == "running-chat",
                   "ending the operation re-reads the list without replacing the open conversation")
            expect(store.messages.last?.content == "finished after refresh" && store.messages.last?.state == .delivered &&
                   api.statusRequests.filter { $0 == "fenced-member-job" }.count == 2 && api.starts.count == 1 && api.cancelledJobs.isEmpty,
                   "the persisted job is re-observed to completion without a second admission or a Stop")
            let next = await store.send(text: "after refresh", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            expect(next != nil && api.starts.count == 2, "the re-observed job releases Send instead of refusing it until relaunch")
            api.resolveStart(jobID: "after-refresh-job", phase: .completed, text: "next answer")
            try await waitUntil { !store.isSending }
        }
        do {
            let (session, api, store) = fixture()
            store.updateDraftText(exactDraft, expectedOwnerID: "owner-one", expectedIdentityGeneration: 0)
            api.delayClassification = true
            await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingClassifications.count == 1 }
            session.isWorking = true
            session.identityGeneration += 1
            store.synchronizeDraftOwner()
            api.resolveClassification(.unavailable)
            try await Task.sleep(for: .milliseconds(20))
            expect(api.starts.isEmpty && store.messages.last?.role == .assistant && store.messages.last?.state == .failed &&
                   store.draftText == exactDraft && !store.isSending,
                   "a kept turn fenced before its sole POST shows as unfinished rather than spinning, and keeps the draft")
            api.delayClassification = false
            session.isWorking = false
        }
        // The new account's identity load and the operation-end reload are two
        // tasks with no fixed order. SessionStore applies the new account and
        // clears isWorking in the same turn, so a reload that runs first finds
        // nothing to redo, and the identity load reads the new list once.
        do {
            let (session, api, store) = fixture()
            api.listedChats = [summary("owner-one-history")]
            await store.loadConversations()
            session.isWorking = true
            session.identityGeneration += 1
            store.synchronizeDraftOwner()
            session.identityID = "owner-two"
            session.isWorking = false
            api.listedChats = [summary("owner-two-history")]
            await store.reloadAfterSessionOperationIfNeeded()
            expect(store.conversations.isEmpty && store.selectedConversation == nil && store.messages.isEmpty &&
                   api.historyReadScopes.filter { $0.route == "list" }.count == 1,
                   "a reload that runs before the new account's identity load reads nothing and shows nothing of the previous owner")
            await store.loadConversations()
            await store.reloadAfterSessionOperationIfNeeded()
            expect(store.conversations.map(\.id) == ["owner-two-history"] && store.selectedConversationID == "owner-two-history" &&
                   api.historyReadScopes.filter { $0.route == "list" }.count == 2,
                   "in the reverse order the new account is still loaded exactly once, by its identity load")
        }
        // The real Send registers its snapshot as soon as the store returns the
        // cid. A same-owner epoch before the sole POST must keep that registered
        // draft, and the unfinished row must carry text: a guest's next request
        // sends the local transcript as history.
        do {
            let (session, api, store) = fixture()
            session.isAuthenticated = false
            session.identityID = "guest-fence"
            await store.loadConversations()
            store.updateDraftText(exactDraft, expectedOwnerID: "guest-fence", expectedIdentityGeneration: 0)
            store.updateDraftContext(originalDraftContext, expectedOwnerID: "guest-fence", expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            api.delayClassification = true
            let cid = await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingClassifications.count == 1 }
            session.isWorking = true
            session.identityGeneration += 1
            store.synchronizeDraftOwner()
            let fenced = store.messages.last
            expect(fenced?.role == .assistant && fenced?.cid == cid && fenced?.state == .failed &&
                   fenced?.content == "The original answer could not be confirmed. It has not been sent again." &&
                   !store.isSending && api.starts.isEmpty,
                   "a registered turn fenced before its sole POST is unfinished with the unconfirmed text, never an empty assistant")
            api.resolveClassification(.unavailable)
            try await Task.sleep(for: .milliseconds(20))
            expect(api.starts.isEmpty && store.messages.last == fenced && store.lastAcceptedSend == nil &&
                   store.draftText == exactDraft && store.draftContext == originalDraftContext,
                   "the late classification cannot admit the fenced turn, and the registered draft and attachments stay")
            api.delayClassification = false
            session.isWorking = false
            await store.reloadAfterSessionOperationIfNeeded()
            expect(store.messages.last == fenced && api.starts.isEmpty, "ending the operation keeps the unfinished row and replays nothing")
            let retry = await store.send(text: "after the fence", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            let history = api.starts[0].messages
            expect(retry != nil && retry != cid &&
                   history.contains { $0.role == .assistant && $0.cid == cid && $0.content == fenced?.content } &&
                   !history.contains { $0.role == .assistant && $0.content.isEmpty },
                   "the next request carries the unfinished turn's text as history and never an empty assistant")
            api.resolveStart(jobID: "after-fence-job", phase: .completed, text: "answer after the fence")
            try await waitUntil { !store.isSending }
        }
        // Re-observing a saved job after a session operation must not move the
        // reader out of the conversation they kept open.
        do {
            let (session, api, store) = fixture()
            api.listedChats = [summary("job-chat"), summary("reading-chat")]
            await store.loadConversations()
            let cid = await store.send(text: "answer while I read elsewhere", tier: .pro, thinking: false, webSearch: false, language: .english)!
            try await waitUntil { api.pendingStarts.count == 1 }
            api.delayStatuses = true
            api.resolveStart(jobID: "elsewhere-job")
            try await waitUntil { api.pendingStatuses.count == 1 }
            await store.select("reading-chat")
            session.isWorking = true
            session.identityGeneration += 1
            store.synchronizeDraftOwner()
            api.pendingStatuses.removeFirst().resume(returning: status(.processing, "fenced partial"))
            try await Task.sleep(for: .milliseconds(20))
            api.delayStatuses = false
            api.statusResults = [status(.completed, "finished while reading")]
            session.isWorking = false
            await store.reloadAfterSessionOperationIfNeeded()
            try await waitUntil { !store.isSending && store.activeCID == nil }
            expect(store.selectedConversationID == "reading-chat" && !store.messages.contains { $0.cid == cid },
                   "re-observing the saved job never moves the reader out of the conversation they kept open")
            expect(api.statusRequests.filter { $0 == "elsewhere-job" }.count == 2 && api.starts.count == 1 && api.cancelledJobs.isEmpty,
                   "the job in the other conversation is still observed to completion without a second admission or a Stop")
        }
        // Launch runs the same code path and still opens the running chat: the
        // first conversation a read picks by itself is not one the reader kept.
        do {
            let session = SessionStore()
            let api = FirasAPI()
            let defaults = UserDefaults(suiteName: "firas-chat-launch-opens-job-" + UUID().uuidString)!
            let original = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                     guestTranscriptDirectory: guestDirectory())
            api.listedChats = [summary("launch-job-chat")]
            await original.loadConversations()
            await original.send(text: "still running at launch", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.delayStatuses = true
            api.resolveStart(jobID: "launch-job")
            try await waitUntil { api.pendingStatuses.count == 1 }
            session.identityID = "owner-away"
            original.synchronizeDraftOwner()
            api.pendingStatuses.removeFirst().resume(returning: status(.processing))
            try await Task.sleep(for: .milliseconds(20))
            session.identityID = "owner-one"
            api.delayStatuses = false
            api.statusResults = [status(.completed, "answer found at launch")]
            api.listedChats = [summary("newer-chat"), summary("launch-job-chat")]
            let relaunched = ChatStore(session: session, api: api, defaults: defaults, recoveryDelays: [],
                                     guestTranscriptDirectory: guestDirectory())
            await relaunched.loadConversations()
            try await waitUntil { !relaunched.isSending && relaunched.activeCID == nil }
            expect(relaunched.selectedConversationID == "launch-job-chat" &&
                   relaunched.messages.contains { $0.content == "answer found at launch" },
                   "at launch the read's own first pick still gives way to the running chat, as before")
        }
        // Exercise the actual selected-history -> saved-history -> job DTO
        // path. Only the inference suffix is trimmed; full history is retained.
        @MainActor func budgetRequest(history: [ChatMessage], text: String,
                                      context: PreparedChatContext? = nil) async throws
            -> (request: ChatJobRequest, savedHistory: [ChatMessage], cid: String) {
            let (_, api, store) = fixture()
            let chatID = "budget-" + UUID().uuidString
            api.chats[chatID] = ChatConversation(id: chatID, title: "Budget fixture", messages: history)
            await store.select(chatID)
            let cid = await store.send(text: text, tier: .pro, thinking: false, webSearch: false,
                                       language: .english, context: context)!
            try await waitUntil { api.pendingStarts.count == 1 }
            let request = api.starts[0]
            let saved = api.updates.last!.request.messages!
            api.resolveStart(jobID: "budget-result-" + cid, phase: .completed, text: "fixture complete")
            try await waitUntil { !store.isSending }
            return (request, saved, cid)
        }
        do {
            let metadata: [String: ChatJSONValue] = ["steps": .array([.object(["id": .string("retained-step")])]),
                "fileRevision": .number(4), "omnix": .object(["run": .string("retained-run")])]
            let history = [ChatMessage(role: .user, content: String(repeating: "a", count: 159_999),
                    cid: "budget-exact-a", reasoning: "archived reasoning", unknownFields: metadata),
                ChatMessage(role: .assistant, content: String(repeating: "b", count: 159_999), cid: "budget-exact-b")]
            let result = try await budgetRequest(history: history, text: "cc")
            expect(result.request.messages.filter { $0.role != .system }.map(\.cid) == ["budget-exact-a", "budget-exact-b", result.cid],
                   "exactly 320000 estimated characters retain every inference message")
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.request)) as! [String: Any]
            let wireMessages = wire["messages"] as! [[String: Any]]
            expect(wire["product"] as? String == "ai" && wire["cid"] as? String == result.cid &&
                   wireMessages.last?["content"] as? String == "cc" && wireMessages.last?["role"] as? String == "user",
                   "the actual encoded job still carries its ordinary product and unmodified accepted user turn")
            expect(Array(result.savedHistory.prefix(history.count)) == history && result.savedHistory.last?.cid == result.cid,
                   "context budgeting cannot mutate canonical saved reasoning or steps/fileRevision/omnix metadata")
        }
        do {
            let history = [ChatMessage(role: .user, content: String(repeating: "a", count: 159_999), cid: "budget-over-a"),
                ChatMessage(role: .assistant, content: String(repeating: "b", count: 159_999), cid: "budget-over-b")]
            let result = try await budgetRequest(history: history, text: "ccc")
            expect(result.request.messages.filter { $0.role != .system }.map(\.cid) == ["budget-over-b", result.cid],
                   "one character beyond 320000 removes exactly the oldest whole inference message")
            expect(Array(result.savedHistory.prefix(history.count)) == history && result.savedHistory.count == history.count + 1,
                   "a discarded inference row remains complete in the initial authoritative history PUT")
        }
        do {
            let arabic = String(repeating: "\u{0639}\u{064E}", count: 159_999)
            let family = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: 159_999)
            let latest = "\u{062C}\u{064E}\u{0641}\u{064E}"
            let history = [ChatMessage(role: .user, content: arabic, cid: "budget-arabic"),
                ChatMessage(role: .assistant, content: family, cid: "budget-emoji")]
            let result = try await budgetRequest(history: history, text: latest)
            expect(arabic.count + family.count + latest.count == 320_000 && family.utf16.count > family.count,
                   "Unicode budget fixture has exactly 320000 graphemes despite longer scalar and UTF16 representations")
            expect(result.request.messages.filter { $0.role != .system }.map(\.content) == [arabic, family, latest],
                   "decomposed Arabic and joined family emoji keep the existing Swift grapheme budget rather than a byte/UTF16 budget")
        }
        do {
            let history = [ChatMessage(role: .assistant, content: String(repeating: "a", count: 320_000), cid: "oversized-last-two")]
            let result = try await budgetRequest(history: history, text: "x")
            expect(result.request.messages.filter { $0.role != .system }.map(\.content) == [history[0].content, "x"],
                   "the final two whole messages remain intact even when their estimated cost exceeds the budget")
            expect(result.savedHistory.first == history.first && result.savedHistory.last?.content == "x",
                   "oversized two-turn inference does not rewrite saved history or the submitted brief")
        }
        do {
            // Synthetic fragments isolate the joined-string estimator; this
            // fixture does not exercise image validation or provider decoding.
            let thumbnails = ["e", "\u{0301}"]
            let history = [ChatMessage(role: .user, content: String(repeating: "a", count: 159_999), cid: "thumbnail-budget-a"),
                ChatMessage(role: .assistant, content: String(repeating: "b", count: 159_998), cid: "thumbnail-budget-b")]
            let context = PreparedChatContext(fullImages: [], imageThumbnails: thumbnails, files: [], fileText: nil)
            let result = try await budgetRequest(history: history, text: "cc", context: context)
            expect(thumbnails.joined().count == 1 && thumbnails.reduce(0, { $0 + $1.count }) == 2,
                   "synthetic thumbnail boundary distinguishes the required joined grapheme estimate from summing separate strings")
            expect(result.request.messages.filter { $0.role != .system }.map(\.cid) == ["thumbnail-budget-a", "thumbnail-budget-b", result.cid],
                   "joined thumbnail cost at the exact limit keeps the oldest inference row")
            let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.request)) as! [String: Any]
            let wireMessages = wire["messages"] as! [[String: Any]]
            expect(wireMessages.last?["imageThumbs"] as? [String] == thumbnails && result.savedHistory.last?.imageThumbs == thumbnails,
                   "budgeting retains exact thumbnail fragments in both the actual job wire and saved user turn")
        }
        do {
            let history = [ChatMessage(role: .user, content: String(repeating: "a", count: 159_999), cid: "file-budget-a"),
                ChatMessage(role: .assistant, content: String(repeating: "b", count: 159_999), cid: "file-budget-b")]
            let files = [ChatAttachment(name: "budget.txt", kind: "text")]
            let context = PreparedChatContext(fullImages: [], imageThumbnails: [], files: files, fileText: "f")
            let result = try await budgetRequest(history: history, text: "cc", context: context)
            expect(result.request.messages.filter { $0.role != .system }.map(\.cid) == ["file-budget-b", result.cid],
                   "latest file text contributes before inference conversion and pushes a 320000 text-only suffix over budget")
            expect(result.request.messages.last?.content == "cc\n\nf" && result.request.messages.last?.fileText == nil,
                   "the existing inference file-text conversion and its separators stay unchanged after one-pass budgeting")
            expect(result.savedHistory.last?.content == "cc" && result.savedHistory.last?.fileText == "f" && result.savedHistory.last?.files == files,
                   "saved user content, file text and attachment metadata remain separate and complete")
        }
        do {
            let history = (0..<35).map { index in
                ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                    content: String(repeating: "a", count: 20_000), cid: "many-budget-\(index)")
            }
            let result = try await budgetRequest(history: history, text: "x")
            let expectedCIDs = Array(history.suffix(15)).map(\.cid) + [Optional(result.cid)]
            expect(result.request.messages.filter { $0.role != .system }.map(\.cid) == expectedCIDs,
                   "multiple oldest-first removals retain the exact last fifteen historical turns and current request")
            expect(result.request.messages.filter { $0.role != .system }.map(\.content) == Array(history.suffix(15)).map(\.content) + ["x"],
                   "one-pass removal never truncates or rewrites surviving message bodies")
            expect(Array(result.savedHistory.prefix(history.count)) == history && result.savedHistory.count == 36,
                   "all thirty-five historical turns remain saved while the smaller inference suffix is submitted")
        }

        // Failure text is short and in the turn's language (else the app's);
        // never a raw code, a system sentence or a server text in the other language.
        do {
            let arabicNotice = "تعذّر إكمال الطلب بسبب حدّ الاستخدام أو كثرة الطلبات."
            let modelText: String? = "The selected model is not available right now. Try again shortly or choose another model."
            let quotaText: String? = "وصلت إلى حدّ الاستخدام أو كثرت الطلبات. انتظر قليلاً ثم أعد المحاولة."
            let busyText: String? = "The server is busy right now. Try again in a minute."
            expect(FirasErrorText.text(code: "selected_model_unavailable", notice: arabicNotice, english: false) == arabicNotice,
                   "a server notice in the reader's language is shown as it is")
            expect(FirasErrorText.text(code: "selected_model_unavailable", notice: arabicNotice, english: true) == modelText,
                   "a notice in the other language gives way to its code's own text")
            expect(FirasErrorText.text(code: "selected_model_unavailable", notice: "{\"upstream\": \"body text\"}", english: true) == modelText,
                   "a notice that is not a sentence is never shown")
            expect(FirasErrorText.text(code: "upstream said something", english: false) == nil,
                   "unknown server text is never returned")
            expect(FirasErrorText.text(status: 429, code: "media_request_failed", english: false) == quotaText,
                   "a limit without a known code still names its next step")
            expect(FirasErrorText.text(status: 503, code: nil, english: true) == busyText,
                   "a server failure asks for a retry in a minute")
            expect(FirasErrorText.connection(code: -1009, english: true) ==
                       "There is no internet connection. Check your connection, then try again.",
                   "offline names the connection in English")
            expect(FirasErrorText.connection(code: -1001, english: false) ==
                       "انتهت مهلة الاتصال بالخادم. تحقّق من اتصالك ثم أعد المحاولة.",
                   "a timeout names the connection in Arabic")
        }
        for (failure, language, expected) in [
            (APIError.httpStatus(429, "daily_quota_reached"), AppLanguage.english,
             "You have reached today's usage limit. You can continue tomorrow."),
            (APIError.httpStatus(429, "media_request_failed"), AppLanguage.arabic,
             "وصلت إلى حدّ الاستخدام أو كثرت الطلبات. انتظر قليلاً ثم أعد المحاولة."),
            (APIError.httpStatus(401, "authentication_required"), AppLanguage.english,
             "Your session has ended. Sign in again, then try again."),
            (APIError.httpStatus(413, "payload_too_large"), AppLanguage.arabic,
             "الطلب أو الملف كبير جداً. صغّر حجمه أو قسّمه ثم أعد المحاولة."),
            (APIError.httpStatus(400, "invalid JSON body"), AppLanguage.english,
             "This request could not be accepted. Edit it, then try again."),
        ] {
            let (_, api, store) = fixture()
            await store.send(text: "mapped admission failure", tier: .pro, thinking: false, webSearch: false, language: language)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.failStart(failure)
            try await waitUntil { !store.isSending }
            expect(store.errorMessage == expected && store.messages.last?.content == expected &&
                   store.messages.last?.state == .failed && api.starts.count == 1,
                   "a rejected admission names its reason and next step in the turn's language, never its code")
        }
        for (language, error, expected) in [
            (AppLanguage.english,
             "{\"error\":\"selected_model_unavailable\",\"message\":\"This request could not finish because a usage or request limit was reached.\"}",
             "This request could not finish because a usage or request limit was reached."),
            (AppLanguage.arabic,
             "{\"error\":\"selected_model_unavailable\",\"message\":\"The selected model could not complete this answer.\"}",
             "النموذج المحدد غير متاح الآن. أعد المحاولة بعد قليل أو اختر نموذجاً آخر."),
            (AppLanguage.english, "{\"error\":\"cancelled\"}", "The answer was stopped."),
            (AppLanguage.arabic, "previous_attempt_failed", "تعذّر إكمال الإجابة. أعد المحاولة."),
        ] {
            let (_, api, store) = fixture()
            await store.send(text: "failed job", tier: .pro, thinking: false, webSearch: false, language: language)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.statusResults = [ChatJobStatus(phase: .failed, text: nil, reasoning: nil, error: error,
                                               status: 503, surface: nil, progress: nil)]
            api.resolveStart(jobID: "failed-job-" + UUID().uuidString)
            try await waitUntil { !store.isSending }
            expect(store.errorMessage == expected && store.messages.last?.content == expected &&
                   store.messages.last?.state == .failed,
                   "a failed job shows the server's notice in the turn's language, else its code's text, never the code")
        }
        for saved in [nil, "en"] as [String?] {
            let session = SessionStore()
            let api = FirasAPI()
            let defaults = UserDefaults(suiteName: "firas-chat-app-language-" + UUID().uuidString)!
            if let saved { defaults.set(saved, forKey: "lang") }
            let store = ChatStore(session: session, api: api, defaults: defaults,
                recoveryDelays: [.milliseconds(1), .milliseconds(1)], guestTranscriptDirectory: guestDirectory())
            api.delayedChatIDs = ["offline-read"]
            let selection = Task { await store.select("offline-read") }
            try await waitUntil { api.pendingChats["offline-read"] != nil }
            api.pendingChats.removeValue(forKey: "offline-read")?.resume(throwing:
                APIError.transport(code: -1009, message: "The Internet connection appears to be offline."))
            await selection.value
            let expected: String = saved == "en"
                ? "There is no internet connection. Check your connection, then try again."
                : "لا يتوفر اتصال بالإنترنت. تحقّق من اتصالك ثم أعد المحاولة."
            expect(store.errorMessage == expected,
                   "a failure outside any turn follows the saved app language, never the system's own sentence")
        }
        do {
            let (_, api, store) = fixture()
            await store.send(text: "first English turn", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            let refused = await store.send(text: "second English turn", tier: .pro, thinking: false, webSearch: false, language: .english)
            expect(refused == nil && store.errorMessage == "An answer is in progress. Stop it before sending a new message.",
                   "the in-progress refusal follows the reader's language")
            await store.stop()
            api.resolveStart(jobID: "english-stopped-turn")
            try await waitUntil { !store.isSending }
            expect(store.messages.last?.state == .stopped && store.messages.last?.content == "The answer was stopped." &&
                   api.cancelledJobs == ["english-stopped-turn"],
                   "a stopped English answer says so in English")
        }
        do {
            let (session, api, store) = fixture()
            session.isAuthenticated = false
            session.identityID = nil
            let refused = await store.send(text: "no guest yet", tier: .pro, thinking: false, webSearch: false, language: .english)
            expect(refused == nil && api.starts.isEmpty &&
                   store.errorMessage == "The guest session could not start. Check your connection, then try again.",
                   "a guest session that could not start says so in the reader's language")
        }

        // The single-chat read carries no product flags; the list decides, so
        // a Code project or Brain notebook never becomes the Chat transcript.
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("ordinary-open"), summary("code-project", code: true),
                               summary("brain-notebook", brain: true)]
            await store.loadConversations()
            let reads = api.chatRequests.count
            await store.select("code-project")
            await store.select("brain-notebook")
            expect(store.selectedConversationID == "ordinary-open" && api.chatRequests.count == reads,
                   "a listed Code project or Brain notebook is refused before any read and the open chat stays")
        }
        do {
            let (_, api, store) = fixture()
            await store.select("opened-before-list")
            expect(store.selectedConversationID == "opened-before-list", "a chat the list has not described yet can open")
            api.listedChats = [summary("opened-before-list", code: true), summary("ordinary-next")]
            await store.loadConversations()
            expect(store.selectedConversationID == "ordinary-next",
                   "once the list marks the open chat as a Code project it is closed for the first ordinary chat")
        }
        do {
            let (_, api, store) = fixture()
            api.delayedChatIDs = ["racing-notebook"]
            let selection = Task { await store.select("racing-notebook") }
            try await waitUntil { api.pendingChats["racing-notebook"] != nil }
            api.listedChats = [summary("racing-notebook", brain: true)]
            await store.loadConversations()
            api.resolveChat(id: "racing-notebook")
            await selection.value
            expect(store.selectedConversationID == nil,
                   "a notebook read still in flight when the list arrives is not opened")
        }

        // Refreshing the open chat (the foreground return, a pull and a tap on
        // the open row) re-reads turns saved elsewhere and nothing else.
        do {
            let (_, api, store) = fixture()
            let phone = ChatMessage(role: .user, content: "asked on the phone", cid: "phone-turn")
            api.chats["shared-chat"] = ChatConversation(id: "shared-chat", title: "Shared", messages: [phone])
            await store.select("shared-chat")
            let web = ChatMessage(role: .user, content: "asked on the website", cid: "web-turn")
            let webAnswer = ChatMessage(role: .assistant, content: "answered on the website", cid: "web-turn")
            api.chats["shared-chat"] = ChatConversation(id: "shared-chat", title: "Shared", messages: [phone, web, webAnswer])
            await store.refreshSelectedConversation()
            expect(store.selectedConversationID == "shared-chat" &&
                   store.messages.map(\.content) == ["asked on the phone", "asked on the website", "answered on the website"],
                   "(a) a turn saved on the website appears in the open chat without opening it again")
            let reads = api.chatRequests.count
            await store.refreshSelectedConversation()
            expect(api.chatRequests.count == reads + 1 && store.messages.count == 3,
                   "(a) a refresh that finds nothing new leaves the transcript as it is")
        }
        do {
            let (session, api, store) = fixture()
            session.isAuthenticated = false
            session.identityID = "guest-refresh"
            await store.loadConversations()
            let reads = api.chatRequests.count
            await store.refreshSelectedConversation()
            expect(api.chatRequests.count == reads && store.selectedConversationID?.hasPrefix("guest-") == true,
                   "(a) a guest's on-device transcript is never re-read from the server")
        }
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("turns-into-code")]
            await store.loadConversations()
            api.delayedChatIDs = ["turns-into-code"]
            let refresh = Task { await store.refreshSelectedConversation() }
            try await waitUntil { api.pendingChats["turns-into-code"] != nil }
            api.listedChats = [summary("turns-into-code", code: true)]
            await store.loadConversations()
            api.chats["turns-into-code"] = ChatConversation(id: "turns-into-code", title: "Project",
                messages: [ChatMessage(role: .user, content: "project file", cid: "project-turn")])
            api.resolveChat(id: "turns-into-code")
            await refresh.value
            expect(store.selectedConversationID == nil && store.messages.isEmpty,
                   "(a) a chat the list marks as a Code project during the read is not refreshed back into Chat")
        }
        do {
            let (session, api, store) = fixture()
            await store.select("running-chat")
            store.updateDraftText(exactDraft, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let cid = await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingStarts.count == 1 }
            let reads = api.chatRequests.count
            await store.refreshSelectedConversation()
            expect(api.chatRequests.count == reads && store.messages.last?.state == .sending && store.draftText == exactDraft,
                   "(b) a chat with an answer running in it is not re-read, and the Send reservation stays")
            api.resolveStart(jobID: "refresh-running-job", phase: .completed, text: "answer")
            try await waitUntil { !store.isSending }
            expect(store.lastAcceptedSend?.cid == cid && store.draftText.isEmpty,
                   "(b) the reservation a refresh left alone is consumed by the acceptance")
        }
        do {
            let (_, api, store) = fixture()
            await store.select("receipt-chat")
            _ = await store.send(text: "unconfirmed turn", tier: .pro, thinking: false, webSearch: false, language: .english)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.receiptFailure = .transport(code: -1009, message: "synthetic offline")
            api.failStart(APIError.transport(code: -1001, message: "synthetic timeout"))
            try await waitUntil { store.canReconnectActiveJob }
            let reads = api.chatRequests.count
            let shown = store.messages
            await store.refreshSelectedConversation()
            expect(api.chatRequests.count == reads && store.messages == shown,
                   "(b) a chat whose saved receipt is still unconfirmed is left to Reconnect")
        }
        do {
            let (_, api, store) = fixture()
            await store.select("first-open")
            api.delayedChatIDs = ["first-open"]
            let refresh = Task { await store.refreshSelectedConversation() }
            try await waitUntil { api.pendingChats["first-open"] != nil }
            await store.select("chosen-later")
            api.chats["first-open"] = ChatConversation(id: "first-open", title: "Late",
                messages: [ChatMessage(role: .user, content: "late read", cid: "late-turn")])
            api.resolveChat(id: "first-open")
            await refresh.value
            expect(store.selectedConversationID == "chosen-later" && store.messages.isEmpty,
                   "(c) a chat chosen during the read wins over the late refresh")
        }
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("deleting-open"), summary("next-ordinary")]
            await store.select("deleting-open")
            await store.loadConversations()
            api.delayedChatIDs = ["deleting-open"]
            let refresh = Task { await store.refreshSelectedConversation() }
            try await waitUntil { api.pendingChats["deleting-open"] != nil }
            let request = store.deletionRequest(id: "deleting-open", title: "Deleting")!
            api.delayDeletion = true
            let deletion = Task { await store.delete(request, language: .english) }
            try await waitUntil { api.pendingDeletions["deleting-open"] != nil }
            api.chats["deleting-open"] = ChatConversation(id: "deleting-open", title: "Deleted",
                messages: [ChatMessage(role: .user, content: "must not return", cid: "deleted-turn")])
            api.resolveChat(id: "deleting-open")
            await refresh.value
            expect(store.messages.isEmpty, "(c) a chat being deleted is not refreshed")
            api.resolveDeletion(id: "deleting-open")
            _ = await deletion.value
            expect(store.selectedConversationID == "next-ordinary",
                   "(c) the deletion still settles on the next ordinary chat")
        }
        do {
            let (session, api, store) = fixture()
            await store.select("failed-chat")
            store.updateDraftText(exactDraft, expectedOwnerID: session.identityID, expectedIdentityGeneration: 0)
            let snapshot = store.snapshotDraft()!
            let cid = await store.send(text: exactDraft, tier: .pro, thinking: false, webSearch: false, language: .english)!
            store.beginDraftSubmission(cid: cid, snapshot: snapshot)
            try await waitUntil { api.pendingStarts.count == 1 }
            api.failStart(APIError.httpStatus(400, nil))
            try await waitUntil { !store.isSending }
            // The failed turn's question was saved before the POST; its answer never was.
            api.chats["failed-chat"]?.messages.append(ChatMessage(role: .user, content: "added on the website", cid: "web-later"))
            await store.refreshSelectedConversation()
            let failedIndex = store.messages.firstIndex { $0.role == .assistant && $0.cid == cid }
            let questionIndex = store.messages.firstIndex { $0.role == .user && $0.cid == cid }
            expect(failedIndex != nil && store.messages[failedIndex!].state == .failed &&
                   questionIndex.map { $0 + 1 } == failedIndex &&
                   store.messages.last?.content == "added on the website",
                   "(d) a local failed answer stays beside its saved question while the website turn arrives")
            expect(store.draftText == exactDraft && api.starts.count == 1,
                   "(d) a refresh never touches the editable draft and never sends anything")
        }
        do {
            let (_, api, store) = fixture()
            api.listedChats = [summary("notice-chat")]
            await store.loadConversations()
            store.errorMessage = "Synthetic daily limit notice"
            api.listedChats = [summary("notice-chat"), summary("added-elsewhere")]
            await store.loadConversations(clearsError: false)
            expect(store.errorMessage == "Synthetic daily limit notice" &&
                   store.conversations.map(\.id) == ["notice-chat", "added-elsewhere"] &&
                   store.selectedConversationID == "notice-chat",
                   "(e) the return from the background re-reads the list and keeps the notice on screen")
            await store.loadConversations()
            expect(store.errorMessage == nil, "(e) a read the reader asked for still clears the notice")
        }
        print("CLEAN:\(checks) production ChatStore race/history/pin/delete/admission checks")
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(4))
        }
        preconditionFailure("test operation did not reach its synchronization point")
    }
}

import Foundation
import CryptoKit

@main @MainActor enum PromptEngineerTests {
    static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); checks += 1 }
        func until(_ predicate: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while !predicate() {
                precondition(ContinuousClock.now < deadline, "Synthetic boundary did not become ready")
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        expect(PromptEngineerPolicy.matches("Before /PrOmPtEnG after"), "shipping whitespace-delimited token works anywhere and is ASCII case insensitive")
        expect(!PromptEngineerPolicy.matches("/promptengsuffix") && !PromptEngineerPolicy.matches("x/prompteng"), "ordinary substrings are not commands")
        expect(!PromptEngineerPolicy.matches("/prompteng\u{85}x"), "NEL is not JavaScript whitespace")
        expect(PromptEngineerPolicy.source("\u{FEFF}Before\t /prompteng  after \u{00A0}") == "Before after", "first token removal, exact JS trim and horizontal run collapse match website")
        expect(PromptEngineerPolicy.source("/prompteng one\ttwo") == "one\ttwo", "a single tab is preserved by the shipping rule")
        expect(PromptEngineerPolicy.source("/prompteng /prompteng x") == "/prompteng x", "only first command token is stripped")
        expect(PromptEngineerPolicy.source("/prompteng " + String(repeating: "😀", count: 4_000)) != nil, "source ceiling counts UTF16")
        expect(PromptEngineerPolicy.source("/prompteng " + String(repeating: "😀", count: 4_001)) == nil, "source beyond 8000 UTF16 is not silently truncated")
        let request = PromptEngineerJobRequest(cid: "pe_wire", source: "Make a working site", languageCode: "en")
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        expect(Set(wire.keys) == Set(["cid", "tier", "think", "nomem", "promptEng", "lang", "messages"]), "actual helper JSON cannot carry history, pins, generation or charge/control fields")
        expect(wire["tier"] as? String == "ultra" && wire["think"] as? Bool == false && wire["nomem"] as? Bool == true && wire["promptEng"] as? Bool == true, "flags are encoded even when false/default")
        expect(request.messages[0].content.contains("450 to 800 words") && request.messages[0].content.contains("ARTIFACT ITSELF"), "actual shipping prompt retains depth and artifact-kind rule")
        expect(PromptEngineerInstructions.system(languageCode: "ar").contains("الدور والهدف"), "Arabic headings remain exact shipping text")
        func sha(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
        expect(sha(PromptEngineerInstructions.system(languageCode: "ar")) == "423fe7122d13dc316bc626137adba51bc0545332c147bb33c1d50eb1991b2665", "Arabic instructions match independently extracted shipping bytes")
        expect(sha(PromptEngineerInstructions.system(languageCode: "en")) == "0b856419e17357a7c937e57e6414cd2a68b7cde911b2e34e6e38270365e23938", "English instructions match independently extracted shipping bytes")
        expect(PromptEngineerPolicy.digest("Arabic العربية / and quote \" and newline\n", "") == "2f1b62e5aa9f6f584da24771e7ce354bc5afa770e9c4ad5b4fc62a67d8f7a7ad", "receipt hashing matches independent Node JSON.stringify Arabic/slash/quote fixture")
        expect(PromptEngineerPolicy.digest("line\u{2028}x\u{1}😀", "reason\\back") == "752fc9f7d94c39ce4a49db1b8bf9991ac277c2f90ae31345359e6e4e7d8833bb", "receipt hashing matches JS control scalar, separator, emoji and backslash bytes")

        do {
            let (session, chatAPI, chat, api, store, _) = promptFixture()
            let lease = store.acquireObservation()
            let snapshot = chat.snapshotDraft()!
            expect(chat.promptEngineerCommandMatches && chat.promptEngineerSourceReady, "actual draft mutation publishes cached helper projection before the next render")
            expect(store.start(snapshot: snapshot, languageCode: "en"), "owned helper admission reserves immediately")
            expect(!store.start(snapshot: snapshot, languageCode: "en"), "double Apply is rejected before any suspension")
            try await until { api.startWaiters.count == 1 }
            let original = store.pointer!
            expect(chat.draftText == snapshot.text, "original input remains editable while enqueue is pending")
            expect(chatAPI.starts.isEmpty && chatAPI.createCount == 0 && chatAPI.updates.isEmpty, "helper never creates or charges a visible Chat turn")
            api.acknowledge(original)
            try await until { api.statusWaiters.count == 1 }
            api.deliver(helperStatus(store.pointer!, text: "Finished professional prompt"))
            try await until { store.phase == .completed && !store.isObserving }
            expect(chat.draftText == "Finished professional prompt" && store.automaticallyApplied, "proof-attested completion replaces only the exact captured draft")
            expect(!chat.promptEngineerCommandMatches && !chat.promptEngineerSourceReady, "helper replacement invalidates cached command projection with the real draft")
            expect(api.starts.count == 1 && api.scopes.allSatisfy { $0 == "synthetic-owner-one" }, "POST and status share the captured cookie scope")
            expect(store.matchesNotification(jobID: original.jobID ?? PromptEngineerPolicy.jobID(ownerID: original.ownerID, cid: original.cid)), "exact owned helper job notification is routable")
            expect(!store.matchesNotification(jobID: "unrelated-job"), "generic AI notification does not open an unrelated helper")
            let current = chat.snapshotDraft()!
            expect(store.apply(snapshot: current), "manual Apply uses a fresh immutable current draft")
            session.identityGeneration += 1
            expect(!store.apply(snapshot: current), "same-ID epoch invalidates a queued manual application")
            expect(store.visibleText.isEmpty && !store.hasResult, "published old result is hidden immediately by epoch mismatch before synchronization callback")
            store.releaseObservation(lease)
        }

        do {
            let (_, _, chat, api, store, defaults) = promptFixture()
            let lease = store.acquireObservation()
            let snapshot = chat.snapshotDraft()!
            _ = store.start(snapshot: snapshot, languageCode: "ar")
            try await until { api.startWaiters.count == 1 }
            let saved = store.pointer!
            let pointerKey = "firas.ios.prompt-engineer.v1." + String(PromptEngineerPolicy.jobID(ownerID: saved.ownerID, cid: "pointer").prefix(10))
            let encodedPointer = defaults.data(forKey: pointerKey)!
            let persistedPointer = try JSONDecoder().decode(PromptEngineerPointer.self, from: encodedPointer)
            expect(persistedPointer == saved, "prePOST persisted bytes belong to the exact reserved owner/CID pointer")
            let pointerJSON = try JSONSerialization.jsonObject(with: encodedPointer) as! [String: Any]
            expect(Set(pointerJSON.keys) == Set(["ownerID", "cid", "languageCode", "startedAt", "stopRequested"]), "prePOST durable pointer contains only identity/provenance, never source/system/context/cookies")
            api.startWaiters.removeFirst().resume(throwing: APIError.transport(code: -1001, message: "synthetic timeout"))
            try await until { api.receiptWaiters.count == 1 }
            expect(api.starts.count == 1 && api.receiptCalls == [saved.cid], "lost POST acknowledgement uses original-CID GET only")
            api.receipt(saved)
            try await until { api.statusWaiters.count == 1 }
            api.deliver(helperStatus(store.pointer!, text: "partial prompt", phase: "failed", status: 503, notice: "Failure notice"))
            try await until { store.phase == .failed }
            expect(store.text == "partial prompt" && !store.automaticallyApplied, "attested failure removes only its suffix and remains a partial failure")
            expect(chat.draftText == snapshot.text && store.canApply, "failed partial output never destroys original line; explicit Apply remains possible")
            store.releaseObservation(lease)
        }

        do {
            let (_, _, chat, api, store, _) = promptFixture()
            let lease = store.acquireObservation()
            let snapshot = chat.snapshotDraft()!
            _ = store.start(snapshot: snapshot, languageCode: "en")
            try await until { api.startWaiters.count == 1 }
            api.acknowledge(store.pointer!)
            try await until { api.statusWaiters.count == 1 }
            chat.updateDraftText("new edit", expectedOwnerID: snapshot.ownerID, expectedIdentityGeneration: snapshot.identityGeneration)
            chat.updateDraftText(snapshot.text, expectedOwnerID: snapshot.ownerID, expectedIdentityGeneration: snapshot.identityGeneration)
            api.deliver(helperStatus(store.pointer!, text: "Result for older revision"))
            try await until { store.phase == .completed }
            expect(chat.draftText == snapshot.text && !store.automaticallyApplied, "edit then revert still fences automatic replacement")
            store.releaseObservation(lease)
        }

        do {
            let (_, _, chat, api, store, _) = promptFixture()
            let snapshot = chat.snapshotDraft()!
            var queued: CheckedContinuation<Void, Never>?
            let caller = Task {
                await withCheckedContinuation { queued = $0 }
                return store.start(snapshot: snapshot, languageCode: "en")
            }
            try await until { queued != nil }
            caller.cancel()
            queued!.resume()
            let admitted = await caller.value
            expect(!admitted && store.pointer == nil && api.starts.isEmpty, "precancelled queued caller cannot persist a pointer or dispatch a helper")
            expect(chat.draftText == snapshot.text, "precancelled Start leaves the full original line editable")
        }

        do {
            let (_, _, chat, api, store, _) = promptFixture()
            let lease = store.acquireObservation()
            _ = store.start(snapshot: chat.snapshotDraft()!, languageCode: "en")
            try await until { api.startWaiters.count == 1 }
            store.setForeground(false)
            api.acknowledge(store.pointer!)
            try await until { !store.isObserving }
            expect(api.stopCalls.isEmpty && api.statusCalls.isEmpty && store.pointer?.jobID != nil, "background during enqueue allows acceptance to settle but does not Stop or poll the server")
            store.setForeground(true)
            try await until { api.statusWaiters.count == 1 }
            store.setForeground(false)
            store.setForeground(true)
            try await until { api.statusWaiters.count == 2 }
            api.deliver(processingStatus("late background observer"))
            try await Task.sleep(for: .milliseconds(5))
            expect(store.isObserving && store.text.isEmpty, "late noncooperative background observer cannot clear the replacement lease")
            api.deliver(helperStatus(store.pointer!, text: "Foreground reattached"))
            try await until { store.phase == .completed && !store.isObserving }
            expect(api.starts.count == 1 && api.stopCalls.isEmpty, "foreground observation resumes original job without POST or cancel")
            store.releaseObservation(lease)
        }

        do {
            let (_, _, chat, api, store, _) = promptFixture()
            api.credentialFailure = .httpStatus(401, "synthetic")
            let original = chat.draftText
            let lease = store.acquireObservation()
            _ = store.start(snapshot: chat.snapshotDraft()!, languageCode: "en")
            try await until { !store.isObserving }
            expect(store.phase == .failed && store.pointer == nil && api.starts.isEmpty, "definite failure before credential capture removes only undispatched local reservation")
            expect(chat.draftText == original && !store.blocksNewHelper, "no-admission failure keeps editable input and permits a new explicit attempt")
            store.releaseObservation(lease)
        }

        do {
            let (session, _, chat, api, store, _) = promptFixture()
            let lease = store.acquireObservation()
            _ = store.start(snapshot: chat.snapshotDraft()!, languageCode: "en")
            try await until { api.startWaiters.count == 1 }
            api.acknowledge(store.pointer!)
            try await until { api.statusWaiters.count == 1 }
            api.stopFailure = .httpStatus(503, "synthetic")
            store.stop(cid: store.pointer!.cid, expectedOwnerID: session.identityID!, expectedIdentityGeneration: session.identityGeneration)
            try await until { api.statusWaiters.count == 2 }
            api.deliver(processingStatus("retired"))
            for attempt in 1...3 {
                try await until { api.statusWaiters.count == 1 }
                api.deliver(processingStatus("Available partial"))
                try await until { api.stopCalls.count == attempt && api.statusWaiters.count == 1 }
                api.deliver(processingStatus("Available partial"))
            }
            try await until { !store.isObserving }
            expect(store.phase == .stopping && store.problem == "stop_unconfirmed" && store.pointer?.stopRequested == true, "bounded failed Stop preserves durable intent and honest unconfirmed state")
            expect(api.stopCalls.count == 3 && api.starts.count == 1 && store.text == "Available partial", "Stop retries are bounded to three idempotent cancels, never a generation POST")
            expect(api.scopes.allSatisfy { $0 == "synthetic-owner-one" }, "Stop preflight, cancel and completion recheck all carry the original credentials")
            store.releaseObservation(lease)
        }

        do {
            let (session, _, chat, api, store, _) = promptFixture()
            let lease = store.acquireObservation()
            _ = store.start(snapshot: chat.snapshotDraft()!, languageCode: "en")
            try await until { api.startWaiters.count == 1 }
            api.acknowledge(store.pointer!)
            try await until { api.statusWaiters.count == 1 }
            api.holdStops = true
            store.stop(cid: store.pointer!.cid, expectedOwnerID: session.identityID!, expectedIdentityGeneration: session.identityGeneration)
            try await until { api.statusWaiters.count == 2 }
            api.deliver(processingStatus()) // retired observer
            api.deliver(processingStatus()) // owned Stop preflight
            try await until { api.stopWaiters.count == 1 }
            let calls = api.statusCalls.count
            session.identityGeneration += 2
            api.cookie = "replacement-cookie"
            api.stopWaiters.removeFirst().resume(returning: true)
            try await until { !store.isObserving }
            expect(api.statusCalls.count == calls && store.text.isEmpty, "ABA during cancel prevents subsequent status under a replacement account")
            expect(api.scopes.allSatisfy { $0 == "synthetic-owner-one" }, "cancel retains original frozen credentials across its suspension")
            store.releaseObservation(lease)
        }

        do {
            let (_, _, chat, api, store, _) = promptFixture()
            let lease = store.acquireObservation()
            let snapshot = chat.snapshotDraft()!
            _ = store.start(snapshot: snapshot, languageCode: "en")
            try await until { api.startWaiters.count == 1 }
            api.acknowledge(store.pointer!)
            try await until { api.statusWaiters.count == 1 }
            var newerContext = snapshot.context
            newerContext.fileNames = ["new.txt"]
            chat.updateDraftContext(newerContext, expectedOwnerID: snapshot.ownerID, expectedIdentityGeneration: snapshot.identityGeneration)
            api.deliver(helperStatus(store.pointer!, text: "Older context result"))
            try await until { store.phase == .completed }
            expect(chat.draftText == snapshot.text && chat.draftContext == newerContext && !store.automaticallyApplied, "new attachment/context prevents consuming the older draft")
            expect(store.apply(snapshot: chat.snapshotDraft()!), "explicit current-draft application can retain newer context")
            expect(chat.draftContext == newerContext, "manual helper replacement never clears attachments")
            store.releaseObservation(lease)
        }

        do {
            let (session, _, chat, api, store, _) = promptFixture()
            api.holdCredentials = true
            let lease = store.acquireObservation()
            _ = store.start(snapshot: chat.snapshotDraft()!, languageCode: "en")
            try await until { api.credentials.count == 1 }
            let cid = store.pointer!.cid
            store.stop(cid: cid, expectedOwnerID: session.identityID!, expectedIdentityGeneration: session.identityGeneration)
            api.credentials.removeFirst().resume(returning: api.snapshot())
            try await until { !store.isObserving }
            expect(store.phase == .stopped && api.starts.isEmpty && api.stopCalls.isEmpty, "Stop before admission retires only local reservation, never fabricates a cloud cancel")
            expect(chat.draftText.contains("/prompteng"), "pre-admission Stop leaves original editable command")
            store.releaseObservation(lease)
        }

        do {
            let (session, _, chat, api, store, _) = promptFixture()
            let lease = store.acquireObservation()
            _ = store.start(snapshot: chat.snapshotDraft()!, languageCode: "en")
            try await until { api.startWaiters.count == 1 }
            let original = store.pointer!
            store.stop(cid: original.cid, expectedOwnerID: original.ownerID, expectedIdentityGeneration: session.identityGeneration)
            api.startWaiters.removeFirst().resume(throwing: APIError.transport(code: -1001, message: "synthetic lost ack"))
            try await until { api.receiptWaiters.count == 1 }
            api.receipt(original)
            try await until { api.statusWaiters.count == 1 }
            api.deliver(processingStatus("partial"))
            try await until { api.stopCalls.count == 1 && api.statusWaiters.count == 1 }
            api.deliver(helperStatus(store.pointer!, text: "partial", phase: "failed", status: 499, notice: "Stopped notice"))
            try await until { store.phase == .stopped && !store.isObserving }
            expect(api.starts.count == 1 && api.stopCalls == [store.pointer!.jobID!], "uncertain Stop reconciles original CID then cancels full ordinary ID exactly once")
            expect(store.text == "partial" && chat.draftText.contains("/prompteng"), "stopped partial remains distinct from success")
            store.releaseObservation(lease)
        }

        do {
            let (session, _, chat, api, store, _) = promptFixture()
            let lease = store.acquireObservation()
            _ = store.start(snapshot: chat.snapshotDraft()!, languageCode: "en")
            try await until { api.startWaiters.count == 1 }
            api.acknowledge(store.pointer!)
            try await until { api.statusWaiters.count == 1 }
            store.stop(cid: store.pointer!.cid, expectedOwnerID: session.identityID!, expectedIdentityGeneration: session.identityGeneration)
            try await until { api.statusWaiters.count == 2 }
            // Retired watcher returns late. Its result/cleanup cannot own the replacement.
            api.deliver(processingStatus("stale watcher"))
            try await Task.sleep(for: .milliseconds(5))
            expect(store.isObserving && store.text != "stale watcher", "old cancelled watcher cannot clear or publish over the exact new Stop observer")
            api.deliver(helperStatus(store.pointer!, text: "Completion won"))
            try await until { store.phase == .completed && !store.isObserving }
            expect(api.stopCalls.isEmpty && store.text == "Completion won", "authoritative completion wins before late cancel")
            store.releaseObservation(lease)
        }

        do {
            let (session, _, chat, api, store, defaults) = promptFixture()
            let lease = store.acquireObservation()
            _ = store.start(snapshot: chat.snapshotDraft()!, languageCode: "en")
            try await until { api.startWaiters.count == 1 }
            api.acknowledge(store.pointer!)
            try await until { api.statusWaiters.count == 1 }
            let saved = store.pointer!
            store.releaseObservation(lease)
            api.deliver(processingStatus("late old view"))
            try await Task.sleep(for: .milliseconds(5))
            expect(api.stopCalls.isEmpty && store.text.isEmpty, "leave cancels only local observation and rejects its late output")
            let chat2 = ChatStore(session: session, api: FirasAPI(), defaults: defaults)
            let api2 = SyntheticPromptEngineerAPI()
            let restored = PromptEngineerStore(session: session, chatStore: chat2, api: api2, defaults: defaults, pollDelay: .milliseconds(1))
            let lease2 = restored.acquireObservation()
            restored.resumeIfNeeded(); restored.resumeIfNeeded()
            try await until { api2.statusWaiters.count == 1 }
            expect(api2.starts.isEmpty && restored.pointer?.cid == saved.cid && api2.statusCalls == [saved.jobID!], "fresh store resumes identifier-only pointer with exactly one watcher and no request body")
            api2.deliver(helperStatus(saved, text: "Recovered prompt"))
            try await until { restored.phase == .completed }
            expect(!restored.automaticallyApplied && chat2.draftText.isEmpty && restored.canApply, "restored completion requires explicit Apply because no replayable draft was persisted")
            restored.releaseObservation(lease2)
        }

        for boundary in ["credentials", "start", "receipt", "status"] {
            let (session, _, chat, api, store, _) = promptFixture()
            api.holdCredentials = boundary == "credentials"
            let lease = store.acquireObservation()
            _ = store.start(snapshot: chat.snapshotDraft()!, languageCode: "en")
            if boundary == "credentials" { try await until { api.credentials.count == 1 } }
            else {
                try await until { api.startWaiters.count == 1 }
                if boundary == "receipt" {
                    api.startWaiters.removeFirst().resume(throwing: APIError.transport(code: -1, message: "synthetic"))
                    try await until { api.receiptWaiters.count == 1 }
                } else if boundary == "status" {
                    api.acknowledge(store.pointer!)
                    try await until { api.statusWaiters.count == 1 }
                }
            }
            let old = store.pointer!
            session.identityGeneration += 2 // same-ID ABA, without a UI synchronization callback
            if boundary == "credentials" { api.credentials.removeFirst().resume(returning: api.snapshot()) }
            if boundary == "start" { api.acknowledge(old) }
            if boundary == "receipt" { api.receipt(old) }
            if boundary == "status" { api.deliver(helperStatus(old, text: "stale account output")) }
            try await until { !store.isObserving }
            expect(store.text.isEmpty && api.stopCalls.isEmpty, "unsynchronized ABA at \(boundary) cannot publish or cancel using replacement identity")
            expect(api.starts.count == (boundary == "credentials" ? 0 : 1), "ABA cannot introduce a second helper POST at \(boundary)")
            store.releaseObservation(lease)
        }

        do {
            let (_, _, chat, api, store, _) = promptFixture()
            let lease = store.acquireObservation()
            _ = store.start(snapshot: chat.snapshotDraft()!, languageCode: "en")
            try await until { api.startWaiters.count == 1 }
            let saved = store.pointer!
            api.startWaiters.removeFirst().resume(throwing: APIError.transport(code: -1, message: "synthetic"))
            try await until { api.receiptWaiters.count == 1 }
            api.receiptWaiters.removeFirst().resume(returning: PromptEngineerReceipt(jobId: "", phase: "unknown", cid: nil, chatId: nil))
            try await until { !store.isObserving }
            expect(store.phase == .uncertain && !store.blocksOrdinarySend && store.blocksNewHelper && store.canForgetUnavailableReceipt && store.pointer?.cid == saved.cid, "unknown receipt preserves no-replay while releasing edited ordinary Chat input")
            expect(!store.start(snapshot: chat.snapshotDraft()!, languageCode: "en") && api.starts.count == 1, "uncertain helper cannot dispatch a fresh paid/helper request automatically")
            let unchanged = chat.draftText
            store.forgetUnavailableReceipt(cid: saved.cid, expectedOwnerID: saved.ownerID,
                expectedIdentityGeneration: store.identityGeneration)
            expect(!store.hasResult && chat.draftText == unchanged && api.starts.count == 1 && api.stopCalls.isEmpty, "explicit local Forget preserves draft and neither cancels nor replays unknown server work")
            expect(store.start(snapshot: chat.snapshotDraft()!, languageCode: "en"), "a new explicit helper tap after Forget reserves a new CID")
            try await until { api.startWaiters.count == 1 }
            expect(api.starts.count == 2 && store.pointer?.cid != saved.cid, "only the new explicit action performs exactly one new POST; old CID is never replayed")
            api.acknowledge(store.pointer!)
            try await until { api.statusWaiters.count == 1 }
            api.deliver(helperStatus(store.pointer!, text: "Explicit new result"))
            try await until { store.phase == .completed }
            store.releaseObservation(lease)
        }

        do {
            let (session, chatAPI, chat, _, _, _) = promptFixture()
            let rejected = await chat.send(text: "Explain /prompteng this", tier: .pro, thinking: false, webSearch: false, language: .english)
            expect(rejected == nil && chatAPI.starts.isEmpty && chatAPI.createCount == 0, "actual ordinary ChatStore defensively refuses any helper token")
            let snapshot = chat.snapshotDraft()!
            chat.retireDraftSubmission(expectedOwnerID: session.identityID, expectedIdentityGeneration: session.identityGeneration)
            expect(!chat.replaceDraft(with: "late helper", matching: snapshot), "actual ChatStore navigation retirement fences helper application")
        }

        var pointer = PromptEngineerPointer(ownerID: "owner-one", cid: "pe_policy", jobID: nil, languageCode: "en", startedAt: .now, stopRequested: false)
        pointer.jobID = PromptEngineerPolicy.jobID(ownerID: pointer.ownerID, cid: pointer.cid)
        let noticeOnly = helperStatus(pointer, text: "", phase: "failed", status: 503, notice: "Failure")
        expect(PromptEngineerPolicy.outcome(noticeOnly, pointer: pointer, previous: "").text.isEmpty, "notice-only output contains no generated prompt")
        let wrongOwner = helperStatus(pointer, text: "untrusted", proofOwner: "other")
        expect(PromptEngineerPolicy.outcome(wrongOwner, pointer: pointer, previous: "partial").phase == .uncertain, "terminal proof must name captured owner")
        let corrupt = helperStatus(pointer, text: "untrusted", digest: String(repeating: "0", count: 64))
        expect(PromptEngineerPolicy.outcome(corrupt, pointer: pointer, previous: "partial").text == "partial", "bad content hash cannot become completed/application text")
        let large = processingStatus(String(repeating: "😀", count: 24_001))
        expect(PromptEngineerPolicy.outcome(large, pointer: pointer, previous: "safe").problem == "output_too_large", "output budget independently bounds rendered snapshots")
        expect(PromptEngineerPolicy.outcome(processingStatus("short"), pointer: pointer, previous: "longer partial").text == "longer partial", "regressing partial snapshots do not delete available content")
        print("PASS: \(checks) prompt-engineer wire, draft, owner, receipt and lifecycle assertions")
    }
}

import Foundation

@main @MainActor enum MediaStoreRaceTests {
    // Golden keys are SHA256 of the shipping JS JSON identity arrays, not fake
    // job strings or a second native implementation of the receipt policy.
    static let imageKey = "b3c5dbecd22ab7454aebcbe63475dce709bb04de1e7170c41462ad8197452ba3"
    static let videoKey = "85e2f158450534b48e129a39d1d012fbcede5f24f3bfb38df1178014ecabd357"
    static let musicKey = "9af6c379211027541f533684bf1560a14e3da7d551928edbde3a7129f89bf267"
    static let newImageKey = "ee3940b4bf9fd0a7663bbd31fc5b15b5220694e8f2d4f9437b7db00ce2ae7bc8"
    static let png = Data([137, 80, 78, 71, 13, 10, 26, 10] + Array(repeating: 0, count: 24))

    static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); checks += 1
        }
        func fixture(history: [MediaCreation] = []) throws -> (SessionStore, FirasAPI, MediaStudioStore, UserDefaults) {
            let session = SessionStore(), api = FirasAPI()
            let defaults = UserDefaults(suiteName: "firas-media-race-" + UUID().uuidString)!
            defaults.set(try JSONEncoder().encode(["owner-a": history]), forKey: "firas.ios.media-studio.history.v1")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("firas-media-race-" + UUID().uuidString)
            let store = MediaStudioStore(api: api, session: session,
                repository: MediaAssetRepository(directory: directory), defaults: defaults)
            store.synchronizeOwner()
            return (session, api, store, defaults)
        }
        func binding(_ cid: String = "media-turn-a") -> MediaTurnBinding {
            MediaTurnBinding(ownerID: "owner-a", chatID: "chat-a", cid: cid)
        }
        func key(_ kind: MediaStudioKind) -> String {
            switch kind { case .image: imageKey; case .video: videoKey; case .music: musicKey }
        }
        func startResponse(_ kind: MediaStudioKind = .image, phase: String = "queued",
                           cid: String = "media-turn-a", chatID: String = "chat-a",
                           overrideKey: String? = nil, ok: Bool = true) throws -> MediaJobStartResponse {
            let id = overrideKey ?? key(kind)
            var json: [String: Any] = ["ok": ok, "jobId": id, "phase": phase, "cid": cid, "chatId": chatID]
            if phase == "done" { json["key"] = id }
            return try JSONDecoder().decode(MediaJobStartResponse.self, from: JSONSerialization.data(withJSONObject: json))
        }
        func status(_ kind: MediaStudioKind = .image, phase: String = "running",
                    cid: String? = "media-turn-a", chatID: String? = "chat-a",
                    overrideKey: String? = nil, error: String? = nil) throws -> MediaJobStatusResponse {
            let id = overrideKey ?? key(kind)
            var json: [String: Any] = ["ok": true, "phase": phase, "jobId": phase == "unknown" ? "" : id]
            json["cid"] = cid; json["chatId"] = chatID; json["error"] = error
            if phase == "done" { json["key"] = id }
            return try JSONDecoder().decode(MediaJobStatusResponse.self, from: JSONSerialization.data(withJSONObject: json))
        }
        func staged(_ bytes: Data = png, mime: String = "image/png") throws -> MediaAssetFileDownload {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".part")
            try bytes.write(to: url)
            return MediaAssetFileDownload(fileURL: url, mimeType: mime, suggestedFilename: "provider-name.png")
        }
        func dispose(_ session: SessionStore, _ api: FirasAPI, _ store: MediaStudioStore) async {
            session.transition(to: nil); store.synchronizeOwner(); api.drain()
            await Task.yield(); await Task.yield()
        }

        // Opening is read-only. Create does not claim acceptance until the
        // matching real server receipt resolves, and source/draft stay ephemeral.
        do {
            let (session, api, store, defaults) = try fixture()
            store.resumeIfNeeded(); await Task.yield()
            expect(api.starts.isEmpty && api.receipts.isEmpty, "opening an empty Studio does not create a job")
            let ticket = store.ownerGeneration
            let source = "data:image/png;base64," + png.base64EncodedString()
            let attempt = Task { await store.createImage(prompt: "PRIVATE PHOTO BRIEF", preset: .portrait,
                sourceImage: source, language: .english, binding: binding(), tier: .max,
                expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket, expectedIdentityGeneration: session.identityGeneration) }
            try await waitUntil { api.pendingStarts.count == 1 }
            expect(store.isCreating && !store.canCreate, "unresolved admission keeps Create reserved")
            let duplicate = await store.createImage(prompt: "another", preset: .square, language: .english,
                binding: binding("media-turn-new"), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket)
            expect(!duplicate && api.starts.count == 1, "a second tap during a suspended POST cannot enqueue")
            let payload = api.starts[0]
            expect(payload.binding == binding() && payload.tier == "max" && payload.languageCode == "en",
                "paid request retains captured account Chat CID tier and language")
            expect(payload.prompt == "PRIVATE PHOTO BRIEF" && payload.sourceImage == source, "real source and brief reach the sole request")
            let savedBytes = defaults.data(forKey: "firas.ios.media-studio.history.v1")!
            let saved = try JSONDecoder().decode([String: [MediaCreation]].self, from: savedBytes)["owner-a"]![0]
            expect(saved.startAttempted == true && saved.sourceWasProvided == true, "dispatch fence and source provenance are durable before POST returns")
            let savedText = String(decoding: savedBytes, as: UTF8.self)
            expect(saved.prompt.isEmpty && saved.lyrics == nil && !savedText.contains("PRIVATE PHOTO BRIEF") &&
                !savedText.contains(png.base64EncodedString()), "disk receipt contains neither brief nor photo payload")
            api.pendingStarts.removeFirst().resume(returning: try startResponse())
            let accepted = await attempt.value
            expect(accepted && !store.isCreating, "confirmed receipt releases the admission before reporting true")
            try await waitUntil { api.pendingStatuses.count == 1 }
            expect(api.snapshotCount == 1 && api.capturedScopes.allSatisfy { $0 == "synthetic-owner-a" },
                "start and subsequent status use one frozen credential scope")
            expect(api.stops.isEmpty, "opening or leaving the caller does not Stop a cloud job")
            await dispose(session, api, store)
        }

        // A lost POST reply recovers the original CID, including a finished
        // result. Cancellation of the caller never replays or Stops that job.
        do {
            let (session, api, store, _) = try fixture()
            let ticket = store.ownerGeneration
            let attempt = Task { await store.createVideo(prompt: "private video", seconds: 10,
                sourceImage: "data:image/png;base64," + png.base64EncodedString(), language: .arabic,
                binding: binding(), tier: .mini, expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket) }
            try await waitUntil { api.pendingStarts.count == 1 }
            attempt.cancel()
            api.pendingStarts.removeFirst().resume(throwing: APIError.transport(code: -1005, message: "lost_reply"))
            try await waitUntil { api.pendingReceipts.count == 1 }
            expect(api.starts.count == 1 && api.receipts[0].1 == "media-turn-a", "transport uncertainty reads the original receipt only")
            api.pendingReceipts.removeFirst().resume(returning: try status(.video, phase: "done"))
            let accepted = await attempt.value
            expect(accepted && api.stops.isEmpty, "a cancelled observer cannot cancel the independently accepted job")
            try await waitUntil { api.pendingAssets.count == 1 }
            let mp4 = Data([0, 0, 0, 24] + Array("ftypisom".utf8) + Array(repeating: 0, count: 12))
            let download = try staged(mp4, mime: "video/mp4")
            api.pendingAssets.removeFirst().resume(returning: download)
            try await waitUntil { store.creations.first?.localFileURL != nil }
            let url = store.creations[0].localFileURL!
            let bytes = try Data(contentsOf: url)
            expect(bytes == mp4 && !FileManager.default.fileExists(atPath: download.fileURL.path), "repository moves actual staged bytes without retaining a temporary file")
            expect(store.creations[0].phase == .completed && store.creations[0].jobID == videoKey, "original video receipt owns the completed result")
            store.resumeIfNeeded(); await Task.yield()
            expect(api.assets.count == 1 && api.starts.count == 1, "reopen does not redownload readable completed media or create again")
            expect(api.snapshotCount == 1 && api.capturedScopes.count >= 5, "receipt and asset keep the first operation's credential context")
            await dispose(session, api, store)
        }

        // Unknown receipt does not grant a new paid CID. Its bounded caller
        // wait returns false, leaves the draft to UI, and survives a relaunch.
        do {
            let (session, api, store, defaults) = try fixture()
            let ticket = store.ownerGeneration
            let attempt = Task { await store.createImage(prompt: "unconfirmed", preset: .square,
                language: .english, binding: binding(), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket) }
            try await waitUntil { api.pendingStarts.count == 1 }
            api.pendingStarts.removeFirst().resume(throwing: APIError.httpStatus(code: 408, message: "timeout"))
            for _ in 0..<3 {
                try await waitUntil { api.pendingReceipts.count == 1 }
                api.pendingReceipts.removeFirst().resume(returning: try status(phase: "unknown", chatID: nil))
            }
            let accepted = await attempt.value
            expect(!accepted && store.isUnconfirmedSubmission && !store.canCreate, "unconfirmed admission retains editable input and blocks a new paid CID")
            let next = await store.createImage(prompt: "same input", preset: .square, language: .english,
                binding: binding("media-turn-new"), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket)
            expect(!next && api.starts.count == 1, "unknown receipt never enables a replacement creation")
            let pointer = try JSONDecoder().decode([String: [MediaCreation]].self,
                from: defaults.data(forKey: "firas.ios.media-studio.history.v1")!)["owner-a"]!
            await dispose(session, api, store)
            let (resumedSession, resumedAPI, resumedStore, _) = try fixture(history: pointer)
            resumedStore.resumeIfNeeded()
            try await waitUntil { resumedAPI.pendingReceipts.count == 1 }
            expect(resumedAPI.starts.isEmpty && resumedAPI.receipts[0].1 == "media-turn-a", "cold restore can only read the original CID")
            await dispose(resumedSession, resumedAPI, resumedStore)
        }

        // Neither an older unbound row nor a bound pre-dispatch saved draft has
        // the fresh in-memory permit needed to cross the paid POST boundary.
        for hasBinding in [false, true] {
            let row = MediaCreation(ownerID: "owner-a", kind: .music, prompt: "old private brief",
                lyrics: "old private lyrics", cid: hasBinding ? "media-turn-a" : nil,
                chatID: hasBinding ? "chat-a" : nil, startAttempted: false)
            let (session, api, store, defaults) = try fixture(history: [row])
            store.resumeIfNeeded()
            try await waitUntil { store.creations.first?.phase == .failed }
            expect(api.starts.isEmpty && api.receipts.isEmpty, "restored pre-POST history cannot submit or charge")
            let text = String(decoding: defaults.data(forKey: "firas.ios.media-studio.history.v1")!, as: UTF8.self)
            expect(!text.contains("old private"), "successful owned migration erases old replayable drafts")
            await dispose(session, api, store)
        }

        // An old scheduled tap, same-ID ABA, unauthenticated guest or concurrent
        // identity operation cannot authorize a media render.
        do {
            let (session, api, store, _) = try fixture()
            let oldTicket = store.ownerGeneration, oldIdentity = session.identityGeneration
            session.transition(to: "owner-a"); store.synchronizeOwner()
            let stale = await store.createImage(prompt: "stale", preset: .square, language: .english,
                binding: binding(), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: oldTicket,
                expectedIdentityGeneration: oldIdentity)
            expect(!stale, "same-ID identity epoch rejects the old tap")
            session.isWorking = true
            let duringAuth = await store.createImage(prompt: "auth busy", preset: .square, language: .english,
                binding: binding(), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: store.ownerGeneration)
            expect(!duringAuth, "auth transition rejects new media")
            session.isWorking = false; session.isAuthenticated = false; store.synchronizeOwner()
            let guest = await store.createImage(prompt: "guest", preset: .square, language: .english,
                binding: binding(), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: store.ownerGeneration)
            expect(!guest && api.starts.isEmpty, "real guest cannot use member-only media")
            await dispose(session, api, store)
        }

        // Stop before the worker's credential snapshot finishes retires only
        // that fresh permit. A later independent Create is still possible.
        do {
            let (session, api, store, _) = try fixture()
            api.holdSnapshot = true
            let ticket = store.ownerGeneration
            let attempt = Task { await store.createImage(prompt: "before snapshot", preset: .square,
                language: .english, binding: binding(), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket) }
            try await waitUntil { api.pendingSnapshots.count == 1 }
            store.stop(store.creations[0], language: .english)
            api.pendingSnapshots.removeFirst().resume(returning: .init(origin: URL(string: "https://firasai.org")!, cookieHeader: api.cookieHeader))
            let accepted = await attempt.value
            expect(!accepted && store.creations[0].phase == .stopped && api.starts.isEmpty, "pre-POST Stop never sends the saved input")
            api.holdSnapshot = false
            let next = Task { await store.createImage(prompt: "fresh explicit input", preset: .square,
                language: .english, binding: binding("media-turn-new"), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket) }
            try await waitUntil { api.pendingStarts.count == 1 }
            api.pendingStarts.removeFirst().resume(returning: try startResponse(cid: "media-turn-new", overrideKey: newImageKey))
            let nextAccepted = await next.value
            expect(nextAccepted && api.starts.count == 1, "old Stop intent cannot permanently stop a new CID")
            await dispose(session, api, store)
        }

        // Stop during the sole POST preserves receipt recovery and uses the
        // server's kind_ control ID. Completion observed afterward outranks Stop.
        do {
            let (session, api, store, _) = try fixture()
            let ticket = store.ownerGeneration
            let attempt = Task { await store.createMusic(prompt: "", lyrics: "private lyrics", seconds: 90,
                language: .english, binding: binding(), tier: .ultra, expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket) }
            try await waitUntil { api.pendingStarts.count == 1 }
            store.stop(store.creations[0], language: .english)
            expect(api.stops.isEmpty, "Stop cannot invent a job ID while POST is unresolved")
            api.pendingStarts.removeFirst().resume(returning: try startResponse(.music))
            let accepted = await attempt.value
            expect(!accepted, "pre-accept Stop preserves the caller's editable lyrics")
            try await waitUntil { api.pendingStops.count == 1 }
            expect(api.stops[0] == "music_" + musicKey && api.starts.count == 1, "Stop targets the exact existing music control ID")
            api.pendingStops.removeFirst().resume(returning: .init(ok: true, stopped: true))
            try await waitUntil { api.pendingStatuses.count == 1 }
            api.pendingStatuses.removeFirst().resume(returning: try status(.music, phase: "done"))
            try await waitUntil { api.pendingAssets.count == 1 }
            expect(store.creations[0].phase == .completed && store.creations[0].stopRequested == false, "completed durable status outranks acknowledged Stop")
            await dispose(session, api, store)
        }

        // An uncooperative cancelled status returns after its replacement Stop
        // starts. Its finally must not erase the replacement task lease.
        do {
            let row = MediaCreation(ownerID: "owner-a", kind: .image, prompt: "",
                phase: .running, jobID: imageKey, cid: "media-turn-a", chatID: "chat-a", startAttempted: true)
            let (session, api, store, _) = try fixture(history: [row])
            store.resumeIfNeeded(); try await waitUntil { api.pendingStatuses.count == 1 }
            let retiredStatus = api.pendingStatuses.removeFirst()
            store.stop(store.creations[0], language: .english)
            try await waitUntil { api.pendingStops.count == 1 }
            retiredStatus.resume(returning: try status())
            await Task.yield(); await Task.yield()
            store.resumeIfNeeded(); await Task.yield()
            expect(api.stops.count == 1 && api.statuses.count == 1, "retired same-owner finally cannot clear replacement Stop lease")
            for _ in 0..<3 {
                try await waitUntil { api.pendingStops.count == 1 }
                api.pendingStops.removeFirst().resume(throwing: APIError.transport(code: -1, message: "stop_reply_lost"))
                try await waitUntil { api.pendingStatuses.count == 1 }
                api.pendingStatuses.removeFirst().resume(returning: try status())
            }
            try await waitUntil { store.creations[0].errorCode == "stop_unconfirmed" }
            expect(api.stops.count == 3 && store.creations[0].phase == .stopping, "uncertain Stop is bounded and persists its unresolved intent")
            expect(api.starts.isEmpty, "Stop uncertainty never dispatches paid rendering")
            await dispose(session, api, store)
        }

        // A new cookie arriving while POST is suspended is an uncertain paid
        // boundary, not evidence of a definite rejection or permission to retry.
        do {
            let (session, api, store, _) = try fixture()
            let ticket = store.ownerGeneration
            let attempt = Task { await store.createImage(prompt: "cookie race", preset: .square,
                language: .english, binding: binding(), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket) }
            try await waitUntil { api.pendingStarts.count == 1 }
            api.cookieHeader = "synthetic-owner-b"
            api.pendingStarts.removeFirst().resume(returning: try startResponse())
            let accepted = await attempt.value
            expect(!accepted && store.isUnconfirmedSubmission && store.creations[0].phase.isActive, "cookie retirement after paid dispatch remains receipt-only")
            expect(api.starts.count == 1 && api.assets.isEmpty && api.receipts.isEmpty, "retired scope cannot read under newly arrived credentials")
            await dispose(session, api, store)
        }

        // ABA account transition and delayed HTTP return cannot publish into the
        // new view or clear its already registered recovery watcher.
        do {
            let (session, api, store, _) = try fixture()
            let ticket = store.ownerGeneration
            let attempt = Task { await store.createImage(prompt: "private A", preset: .square,
                language: .english, binding: binding(), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket) }
            try await waitUntil { api.pendingStarts.count == 1 }
            let retiredStart = api.pendingStarts.removeFirst()
            session.transition(to: "owner-b"); store.synchronizeOwner()
            let accepted = await attempt.value
            expect(!accepted && store.creations.isEmpty, "account switch retires acceptance and private rows")
            session.transition(to: "owner-a"); store.resumeIfNeeded()
            try await waitUntil { api.pendingReceipts.count == 1 }
            retiredStart.resume(returning: try startResponse())
            await Task.yield(); await Task.yield()
            store.resumeIfNeeded(); await Task.yield()
            expect(api.receipts.count == 1 && api.starts.count == 1, "late old POST cannot erase current original-CID recovery lease")
            expect(store.creations[0].jobID == nil, "late old owner's admission cannot publish a job pointer")
            await dispose(session, api, store)
        }

        // Resume of 24 completed results does zero transfers. Explicit open is
        // GET-only, deduplicated, and retired transfers remove their staging file.
        do {
            let history = (0..<24).map { _ in MediaCreation(ownerID: "owner-a", kind: .image,
                prompt: "old title", phase: .completed, jobID: imageKey, resultKey: imageKey) }
            let (session, api, store, _) = try fixture(history: history)
            store.resumeIfNeeded(); await Task.yield()
            expect(api.assets.isEmpty && api.starts.isEmpty, "opening a finished library cannot bulk hydrate 24 results")
            store.loadAsset(store.creations[0], language: .english)
            store.loadAsset(store.creations[0], language: .english)
            try await waitUntil { api.pendingAssets.count == 1 }
            expect(api.assets.count == 1 && store.loadingAssetIDs.count == 1, "repeated open shares a single file transfer")
            let retiredTransfer = api.pendingAssets.removeFirst(), download = try staged()
            session.transition(to: "owner-b"); store.synchronizeOwner()
            retiredTransfer.resume(returning: download)
            try await waitUntil { !FileManager.default.fileExists(atPath: download.fileURL.path) }
            expect(store.creations.isEmpty && store.loadingAssetIDs.isEmpty && store.errorMessage == nil,
                "retired download cannot publish or retain private staged media")
            await dispose(session, api, store)
        }

        // Identical running GETs must not republish the array or rewrite the
        // durable history/timestamps on every polling interval.
        do {
            let row = MediaCreation(ownerID: "owner-a", kind: .image, prompt: "",
                phase: .running, jobID: imageKey, cid: "media-turn-a", chatID: "chat-a", startAttempted: true)
            let (session, api, store, defaults) = try fixture(history: [row])
            let initialRows = store.creations
            let initialBytes = defaults.data(forKey: "firas.ios.media-studio.history.v1")
            store.resumeIfNeeded()
            for _ in 0..<2 {
                try await waitUntil { api.pendingStatuses.count == 1 }
                api.pendingStatuses.removeFirst().resume(returning: try status())
            }
            try await waitUntil { api.pendingStatuses.count == 1 }
            expect(store.creations == initialRows, "identical status preserves the full observed creation snapshot including timestamps")
            expect(defaults.data(forKey: "firas.ios.media-studio.history.v1") == initialBytes,
                "identical status preserves durable bytes without repeated encoding or writing")
            await dispose(session, api, store)
        }

        // Removing a downloading old row and opening the same server result
        // registers a new reservation. A late transfer cannot clear that one.
        do {
            let row = MediaCreation(ownerID: "owner-a", kind: .image, prompt: "",
                phase: .completed, jobID: imageKey, resultKey: imageKey)
            let (session, api, store, _) = try fixture(history: [row])
            store.loadAsset(store.creations[0], language: .english)
            try await waitUntil { api.pendingAssets.count == 1 }
            let oldTransfer = api.pendingAssets.removeFirst()
            store.remove(store.creations[0])
            store.resumeNotificationJob(jobID: imageKey, kind: .image)
            try await waitUntil { api.pendingStatuses.count == 1 }
            api.pendingStatuses.removeFirst().resume(returning: try status(phase: "done"))
            try await waitUntil { api.pendingAssets.count == 1 }
            let replacementID = store.creations[0].id
            let retiredFile = try staged()
            oldTransfer.resume(returning: retiredFile)
            try await waitUntil { !FileManager.default.fileExists(atPath: retiredFile.fileURL.path) }
            expect(store.loadingAssetIDs == Set([replacementID]) && store.isLoading,
                "late retired transfer cannot clear a replacement file reservation")
            let replacement = try staged()
            api.pendingAssets.removeFirst().resume(returning: replacement)
            try await waitUntil { store.localAssetURL(for: store.creations[0]) != nil }
            expect(api.assets.count == 2 && api.starts.isEmpty && !store.isLoading,
                "replacement result remains GET-only and retires only its own loading reservation")
            await dispose(session, api, store)
        }

        // Contradictory receipt, even with valid hexadecimal shape, cannot
        // consume a draft or fetch an unrelated media asset.
        do {
            let (session, api, store, _) = try fixture()
            let ticket = store.ownerGeneration
            let attempt = Task { await store.createImage(prompt: "mismatch", preset: .square,
                language: .english, binding: binding(), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket) }
            try await waitUntil { api.pendingStarts.count == 1 }
            api.pendingStarts.removeFirst().resume(returning: try startResponse(chatID: "wrong-chat"))
            for _ in 0..<3 {
                try await waitUntil { api.pendingReceipts.count == 1 }
                api.pendingReceipts.removeFirst().resume(returning: try status(phase: "done", overrideKey: videoKey))
            }
            let accepted = await attempt.value
            expect(!accepted && api.starts.count == 1 && api.assets.isEmpty, "invalid receipt cannot admit an unrelated result or replay creation")
            expect(!store.canCreate && store.isUnconfirmedSubmission, "mismatched receipt leaves the original paid boundary unresolved")
            await dispose(session, api, store)
        }

        // Invalid inputs fail before any durable dispatch; HTTP rejection is
        // terminal but never exposes the upstream body as UI copy.
        do {
            let (session, api, store, _) = try fixture()
            let ticket = store.ownerGeneration
            let tooLarge = await store.createImage(prompt: String(repeating: "😀", count: 501), preset: .square,
                language: .english, binding: binding(), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket)
            let invalidSource = await store.createVideo(prompt: "source", seconds: 10, sourceImage: "https://untrusted.invalid/photo",
                language: .english, binding: binding(), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket)
            expect(!tooLarge && !invalidSource && api.starts.isEmpty && store.creations.isEmpty,
                "UTF16 and actual source validation run before paid admission")
            let attempt = Task { await store.createImage(prompt: "quota", preset: .square, language: .english,
                binding: binding(), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: ticket) }
            try await waitUntil { api.pendingStarts.count == 1 }
            api.pendingStarts.removeFirst().resume(throwing: APIError.httpStatus(code: 429, message: "PRIVATE upstream key body"))
            let accepted = await attempt.value
            expect(!accepted && store.creations[0].phase == .failed && api.receipts.isEmpty, "definitive admission rejection preserves draft without an automatic retry")
            expect(store.creations[0].errorCode == "render_failed" && !store.errorMessage!.contains("PRIVATE"),
                "untrusted upstream prose cannot become persisted or visible error copy")
            await dispose(session, api, store)
        }

        // Corrupt private storage is not an empty library and never gets
        // overwritten by a new paid submission.
        do {
            let (session, api, store, defaults) = try fixture()
            let corrupt = Data("unreadable private receipt".utf8)
            defaults.set(corrupt, forKey: "firas.ios.media-studio.history.v1")
            store.synchronizeOwner()
            let accepted = await store.createImage(prompt: "new", preset: .square, language: .english,
                binding: binding(), tier: .pro, expectedOwnerID: "owner-a", expectedOwnerGeneration: store.ownerGeneration)
            expect(!accepted && !store.canCreate && api.starts.isEmpty, "unreadable receipt storage blocks new paid admission")
            expect(defaults.data(forKey: "firas.ios.media-studio.history.v1") == corrupt, "failed storage validation preserves original recovery data")
            await dispose(session, api, store)
        }
        do {
            let (session, api, store, defaults) = try fixture()
            let foreign = MediaCreation(ownerID: "owner-b", kind: .image, prompt: "foreign",
                phase: .completed, jobID: imageKey, resultKey: imageKey)
            let bytes = try JSONEncoder().encode(["owner-a": [foreign]])
            defaults.set(bytes, forKey: "firas.ios.media-studio.history.v1")
            session.transition(to: "owner-a"); store.synchronizeOwner()
            expect(store.creations.isEmpty && !store.canCreate && api.assets.isEmpty,
                "wrong-owner row in local receipt partition cannot display or authorize a download")
            expect(defaults.data(forKey: "firas.ios.media-studio.history.v1") == bytes,
                "invalid owner partition does not overwrite private recovery data")
            await dispose(session, api, store)
        }
        do {
            let history = (0..<26).map { MediaCreation(ownerID: "owner-a", kind: .image, prompt: "old",
                phase: .queued, cid: "pending-\($0)", chatID: "chat-a", startAttempted: true) }
            let (session, api, store, defaults) = try fixture(history: history)
            let saved = try JSONDecoder().decode([String: [MediaCreation]].self,
                from: defaults.data(forKey: "firas.ios.media-studio.history.v1")!)["owner-a"]!
            expect(store.creations.count == 26 && saved.count == 26, "finished history cap never evicts unresolved active receipts")
            expect(store.isUnconfirmedSubmission && !store.canCreate && api.starts.isEmpty, "restored uncertain receipts block replacement paid input")
            await dispose(session, api, store)
        }

        // Real repository imports a sparse 200MB provider file by reading only
        // its bounded prefix, and enforces both the byte ceiling and owner path.
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("firas-media-file-" + UUID().uuidString)
            let repository = MediaAssetRepository(directory: directory)
            let header = Data([0, 0, 0, 24] + Array("ftypisom".utf8) + Array(repeating: 0, count: 12))
            let download = try staged(header, mime: "video/mp4")
            let handle = try FileHandle(forWritingTo: download.fileURL)
            try handle.truncate(atOffset: 200_000_000); try handle.close()
            let url = try await repository.save(download, kind: .video, identifier: videoKey, ownerID: "owner-a")
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            expect(values.fileSize == 200_000_000, "file-backed repository supports the exact video ceiling without whole Data allocation")
            expect(repository.owns(url, ownerID: "owner-a") && !repository.owns(url, ownerID: "owner-b"), "local cached file belongs to one private owner partition")
            let oversized = try staged(header, mime: "video/mp4")
            let largeHandle = try FileHandle(forWritingTo: oversized.fileURL)
            try largeHandle.truncate(atOffset: 200_000_001); try largeHandle.close()
            var rejected = false
            do { _ = try await repository.save(oversized, kind: .video, identifier: videoKey, ownerID: "owner-a") }
            catch { rejected = true }
            expect(rejected, "one byte over the actual video limit cannot overwrite the cache")
            try? FileManager.default.removeItem(at: oversized.fileURL)
            try await repository.remove(url)
        }
        print("PASS: \(checks) production media ownership/receipt/file checks (run only on macOS)")
    }

    static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("controlled media boundary did not resolve")
    }
}

import Foundation
import Observation
import Photos
import CryptoKit

@MainActor
@Observable
final class MediaStudioStore {
    private(set) var creations: [MediaCreation] = []
    private(set) var isLoading = false
    private(set) var isCreating = false
    private(set) var loadingAssetIDs: Set<UUID> = []
    private(set) var loadedOwnerID: String?
    private(set) var ownerGeneration = 0
    var errorMessage: String?
    var confirmationMessage: String?

    @ObservationIgnored private let api: FirasAPI
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let repository: MediaAssetRepository
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var workTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var workIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var freshInputs: [UUID: FreshInput] = [:]
    @ObservationIgnored private var acceptanceWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var startingIDs: Set<UUID> = []
    @ObservationIgnored private var preparationID: UUID?
    @ObservationIgnored private var adoptedIdentityGeneration: Int?
    @ObservationIgnored private var cachedHistoryData: Data?
    @ObservationIgnored private var cachedHistoryMap: [String: [MediaCreation]]?
    @ObservationIgnored private var hasHistoryCache = false
    private var historyReadable = true

    private static let historyMapKey = "firas.ios.media-studio.history.v1"
    private static let historyLimit = 24
    private static let maximumHistoryBytes = 2_000_000
    private static let maximumActiveReceipts = 256

    private struct FreshInput {
        let prompt: String
        let lyrics: String?
        let sourceImage: String?
    }

    init(
        api: FirasAPI,
        session: SessionStore,
        repository: MediaAssetRepository = MediaAssetRepository(),
        defaults: UserDefaults = .standard
    ) {
        self.api = api
        self.session = session
        self.repository = repository
        self.defaults = defaults
    }

    var activeCreations: [MediaCreation] {
        creations.filter(\.phase.isActive)
    }

    var finishedCreations: [MediaCreation] {
        creations.filter { !$0.phase.isActive }
    }

    var isUnconfirmedSubmission: Bool {
        creations.contains {
            $0.phase.isActive && $0.startAttempted == true &&
                ($0.jobID == nil || $0.errorCode == "media_receipt_mismatch")
        }
    }

    var canCreate: Bool {
        historyReadable && !isCreating && !isUnconfirmedSubmission &&
            session.isAuthenticated && !session.isWorking &&
            loadedOwnerID == session.identityID && adoptedIdentityGeneration == session.identityGeneration &&
            activeCreations.count < Self.maximumActiveReceipts
    }

    /// Lets the Chat notification router distinguish a Create job from an
    /// ordinary `.ai` chat job without inventing a separate ProductKind. It can
    /// answer from the durable pointer table before Media Studio has appeared.
    func kind(forNotificationJobID jobID: String) -> MediaStudioKind? {
        guard MediaRequestPolicy.validKey(jobID), session.isAuthenticated, !session.isWorking,
              let ownerID = session.identityID else { return nil }
        if let match = creations.first(where: { $0.ownerID == ownerID && $0.jobID == jobID }) {
            return match.kind
        }
        return historyMap()[ownerID]?.first(where: { $0.jobID == jobID })?.kind
    }

    /// Reconnects a terminal push route to its durable server job. This also
    /// repairs an older local timeout/failure marker: the server notification is
    /// authoritative and the same job id can still resolve its cached result.
    func resumeNotificationJob(jobID: String, kind: MediaStudioKind) {
        guard MediaRequestPolicy.validKey(jobID), session.isAuthenticated, !session.isWorking,
              let ownerID = session.identityID else { return }
        synchronizeOwner()
        guard loadedOwnerID == ownerID else { return }

        if let existing = creations.first(where: { $0.ownerID == ownerID && $0.jobID == jobID }) {
            if existing.phase == .completed, existing.resultKey != nil {
                if !hasReadableLocalAsset(existing) {
                    beginHydration(for: existing.id, language: currentLanguage())
                }
                return
            }
            update(existing.id) {
                $0.phase = $0.stopRequested == true ? .stopping : .running
                $0.errorCode = nil
            }
            persistCurrentHistory()
            beginWork(for: existing.id, language: currentLanguage())
            return
        }

        let recovered = MediaCreation(
            ownerID: ownerID,
            kind: kind,
            prompt: "",
            phase: .running,
            jobID: jobID
        )
        creations.insert(recovered, at: 0)
        persistCurrentHistory()
        beginWork(for: recovered.id, language: currentLanguage())
    }

    /// Call when the authenticated identity changes and whenever the app becomes
    /// active. The owned tasks deliberately outlive the screen that displays
    /// them; leaving Media Studio never cancels a server render.
    func resumeIfNeeded() {
        synchronizeOwner()
        resumeLoadedCreations()
    }

    /// The shell calls this for every identity transition, including while
    /// Studio is hidden. Cancelling local observation never stops a cloud job.
    func synchronizeOwner() {
        let ownerID = session.isAuthenticated ? session.identityID : nil
        adopt(ownerID: ownerID, creations: ownerID.flatMap { historyMap()[$0] } ?? [])
        if ownerID != nil, !historyReadable {
            errorMessage = localizedFailure("media_storage_unavailable", language: currentLanguage())
        }
    }

    @discardableResult
    func createImage(
        prompt: String,
        preset: ImageAspectPreset,
        sourceImage: String? = nil,
        language: AppLanguage,
        binding: MediaTurnBinding,
        tier: ModelTier,
        expectedOwnerID: String,
        expectedOwnerGeneration: Int?,
        expectedIdentityGeneration: Int? = nil
    ) async -> Bool {
        await create(
            kind: .image,
            prompt: prompt,
            lyrics: nil,
            aspect: preset,
            seconds: nil,
            sourceImage: sourceImage,
            language: language, binding: binding, tier: tier,
            expectedOwnerID: expectedOwnerID, expectedOwnerGeneration: expectedOwnerGeneration,
            expectedIdentityGeneration: expectedIdentityGeneration
        )
    }

    @discardableResult
    func createVideo(
        prompt: String,
        seconds: Int,
        sourceImage: String? = nil,
        language: AppLanguage,
        binding: MediaTurnBinding,
        tier: ModelTier,
        expectedOwnerID: String,
        expectedOwnerGeneration: Int?,
        expectedIdentityGeneration: Int? = nil
    ) async -> Bool {
        await create(
            kind: .video,
            prompt: prompt,
            lyrics: nil,
            aspect: nil,
            seconds: seconds,
            sourceImage: sourceImage,
            language: language, binding: binding, tier: tier,
            expectedOwnerID: expectedOwnerID, expectedOwnerGeneration: expectedOwnerGeneration,
            expectedIdentityGeneration: expectedIdentityGeneration
        )
    }

    @discardableResult
    func createMusic(
        prompt: String,
        lyrics: String,
        seconds: Int,
        language: AppLanguage,
        binding: MediaTurnBinding,
        tier: ModelTier,
        expectedOwnerID: String,
        expectedOwnerGeneration: Int?,
        expectedIdentityGeneration: Int? = nil
    ) async -> Bool {
        await create(
            kind: .music,
            prompt: prompt,
            lyrics: lyrics,
            aspect: nil,
            seconds: seconds,
            sourceImage: nil,
            language: language, binding: binding, tier: tier,
            expectedOwnerID: expectedOwnerID, expectedOwnerGeneration: expectedOwnerGeneration,
            expectedIdentityGeneration: expectedIdentityGeneration
        )
    }

    /// A saved row is a receipt, never a replayable paid submission.
    func loadAsset(_ creation: MediaCreation, language: AppLanguage) {
        guard creation.ownerID == loadedOwnerID, let current = self.creation(id: creation.id),
              current.phase == .completed, accepts(ownerGeneration, ownerID: current.ownerID)
        else { return }
        beginHydration(for: creation.id, language: language)
    }

    func localAssetURL(for creation: MediaCreation) -> URL? {
        guard creation.ownerID == loadedOwnerID, let current = self.creation(id: creation.id),
              current.phase == .completed, accepts(ownerGeneration, ownerID: current.ownerID),
              hasReadableLocalAsset(current) else { return nil }
        return current.localFileURL
    }

    /// Leaving a view does not call this. Only an explicit Stop persists this
    /// intent and addresses the same owned server job.
    func stop(_ creation: MediaCreation, language: AppLanguage) {
        guard creation.ownerID == loadedOwnerID, let current = self.creation(id: creation.id),
              current.phase.isActive, accepts(ownerGeneration, ownerID: current.ownerID)
        else { return }
        update(current.id) { $0.stopRequested = true; $0.phase = .stopping }
        _ = persistCurrentHistory()
        resolveAcceptance(current.id, accepted: false)
        if current.startAttempted != true && !startingIDs.contains(current.id) {
            freshInputs[current.id] = nil
            update(current.id) { $0.phase = .stopped; $0.errorCode = nil }
            _ = persistCurrentHistory()
            return
        }
        // Never cancel the in-flight sole POST. Its receipt must first identify
        // what Stop is allowed to address.
        guard !startingIDs.contains(current.id) else { return }
        retireWork(current.id)
        beginWork(for: current.id, language: language)
    }

    func remove(_ creation: MediaCreation) {
        guard creation.ownerID == session.identityID, creation.ownerID == loadedOwnerID,
              let current = self.creation(id: creation.id), !current.phase.isActive else { return }
        retireWork(creation.id)
        creations.removeAll { $0.id == creation.id }
        persistCurrentHistory()
        if hasReadableLocalAsset(current), let url = current.localFileURL {
            Task { [repository] in try? await repository.remove(url) }
        }
    }

    func saveToPhotos(_ creation: MediaCreation, language: AppLanguage) {
        guard creation.ownerID == session.identityID, creation.ownerID == loadedOwnerID,
              hasReadableLocalAsset(creation),
              let fileURL = creation.localFileURL,
              creation.kind == .image || creation.kind == .video
        else { return }

        let ticket = ownerGeneration
        Task { [weak self] in
            guard let self else { return }
            guard self.accepts(ticket, ownerID: creation.ownerID) else { return }
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard self.accepts(ticket, ownerID: creation.ownerID) else { return }
            guard authorization == .authorized || authorization == .limited else {
                self.errorMessage = language == .arabic
                    ? "اسمح لفِراس بإضافة الوسائط إلى الصور من إعدادات iPhone."
                    : "Allow Firas to add media to Photos in iPhone Settings."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    if creation.kind == .image {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
                    } else {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                    }
                }
                guard self.accepts(ticket, ownerID: creation.ownerID) else { return }
                self.confirmationMessage = language == .arabic
                    ? "تم الحفظ في الصور."
                    : "Saved to Photos."
            } catch {
                guard self.accepts(ticket, ownerID: creation.ownerID) else { return }
                self.errorMessage = self.message(for: error, language: language)
            }
        }
    }

    func clearMessages() {
        errorMessage = nil
        confirmationMessage = nil
    }

    private func create(
        kind: MediaStudioKind,
        prompt: String,
        lyrics: String?,
        aspect: ImageAspectPreset?,
        seconds: Int?,
        sourceImage: String?,
        language: AppLanguage,
        binding: MediaTurnBinding,
        tier: ModelTier,
        expectedOwnerID: String,
        expectedOwnerGeneration: Int?,
        expectedIdentityGeneration: Int?
    ) async -> Bool {
        guard let expectedOwnerGeneration,
              accepts(expectedOwnerGeneration, ownerID: expectedOwnerID), canCreate,
              expectedIdentityGeneration == nil || expectedIdentityGeneration == session.identityGeneration,
              binding.ownerID == expectedOwnerID,
              Self.validCID(binding.cid), !binding.chatID.isEmpty, binding.chatID.utf16.count <= 128,
              !creations.contains(where: { $0.cid == binding.cid && $0.ownerID == expectedOwnerID })
        else { return false }
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLyrics = lyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanPrompt.utf16.count <= (kind == .image ? 1_000 : 2_000),
              (cleanLyrics?.utf16.count ?? 0) <= 6_000,
              (sourceImage?.utf8.count ?? 0) <= 28_000_000,
              kind != .video || (2...30).contains(seconds ?? 0),
              kind != .music || (10...600).contains(seconds ?? 0)
        else { errorMessage = localizedFailure("media_input_invalid", language: language); return false }
        guard !cleanPrompt.isEmpty || (kind == .music && cleanLyrics?.isEmpty == false) else { return false }
        guard session.isAuthenticated, let ownerID = session.identityID else {
            errorMessage = language == .arabic
                ? "سجّل الدخول لإنشاء الوسائط وحفظ المهمة في السحابة."
                : "Sign in to create media and keep the job running in the cloud."
            return false
        }

        let preparation = UUID()
        preparationID = preparation
        isCreating = true
        defer {
            if preparationID == preparation {
                preparationID = nil
                isCreating = !acceptanceWaiters.isEmpty
            }
        }
        let validationProblem = await Task.detached(priority: .userInitiated) {
            MediaRequestPolicy.validationProblem(kind: kind, prompt: cleanPrompt, lyrics: cleanLyrics ?? "",
                seconds: seconds, sourceImage: sourceImage)
        }.value
        guard preparationID == preparation, accepts(expectedOwnerGeneration, ownerID: expectedOwnerID),
              expectedIdentityGeneration == nil || expectedIdentityGeneration == session.identityGeneration
        else { return false }
        if let validationProblem {
            errorMessage = localizedFailure(validationProblem, language: language)
            return false
        }

        let creation = MediaCreation(
            ownerID: ownerID,
            kind: kind,
            prompt: "",
            aspect: aspect,
            seconds: seconds,
            cid: binding.cid, chatID: binding.chatID, tier: tier.rawValue,
            languageCode: language.rawValue, startAttempted: false,
            sourceWasProvided: sourceImage != nil
        )
        creations.insert(creation, at: 0)
        trimHistory()
        guard persistCurrentHistory() else {
            creations.removeAll { $0.id == creation.id }
            errorMessage = localizedFailure("media_storage_unavailable", language: language)
            return false
        }
        errorMessage = nil
        confirmationMessage = nil
        freshInputs[creation.id] = FreshInput(prompt: cleanPrompt, lyrics: cleanLyrics, sourceImage: sourceImage)
        // This continuation reports server acceptance. The independent owned
        // worker continues after the caller or the Studio view disappears.
        return await withCheckedContinuation { continuation in
            acceptanceWaiters[creation.id] = continuation
            isCreating = true
            beginWork(for: creation.id, language: language)
        }
    }

    private func adopt(ownerID: String?, creations: [MediaCreation]) {
        guard loadedOwnerID != ownerID || adoptedIdentityGeneration != session.identityGeneration else { return }
        ownerGeneration &+= 1
        adoptedIdentityGeneration = session.identityGeneration
        workTasks.values.forEach { $0.cancel() }
        workTasks.removeAll()
        workIDs.removeAll()
        freshInputs.removeAll()
        startingIDs.removeAll()
        preparationID = nil
        let retired = acceptanceWaiters.values
        acceptanceWaiters.removeAll()
        retired.forEach { $0.resume(returning: false) }
        isCreating = false
        loadedOwnerID = ownerID
        self.creations = creations.map(Self.receiptOnly).sorted { $0.createdAt > $1.createdAt }
        isLoading = false
        loadingAssetIDs.removeAll()
        errorMessage = nil
        confirmationMessage = nil
        if ownerID != nil { _ = persistCurrentHistory() }
    }

    private func resumeLoadedCreations() {
        guard let ownerID = loadedOwnerID, session.identityID == ownerID else { return }
        for creation in creations where creation.ownerID == ownerID {
            if creation.phase.isActive {
                beginWork(for: creation.id, language: currentLanguage())
            }
        }
    }

    private func beginWork(for creationID: UUID, language: AppLanguage) {
        guard workTasks[creationID] == nil, let ownerID = loadedOwnerID else { return }
        let ticket = ownerGeneration
        let workID = UUID()
        workIDs[creationID] = workID
        workTasks[creationID] = Task { [weak self] in
            guard let self else { return }
            defer { self.completeWork(creationID, workID: workID, ticket: ticket) }
            guard self.accepts(ticket, ownerID: ownerID) else { return }
            do {
                let credentials = try await self.api.mediaCredentialSnapshot()
                guard self.accepts(ticket, ownerID: ownerID) else { return }
                await MediaCredentialScope.$current.withValue(credentials) {
                    await self.enqueueOrResume(creationID, language: language, ticket: ticket)
                }
            } catch {
                guard self.accepts(ticket, ownerID: ownerID) else { return }
                self.resolveAcceptance(creationID, accepted: false)
                if self.creation(id: creationID)?.startAttempted == true {
                    self.update(creationID) { $0.errorCode = "receipt_pending" }
                } else {
                    self.freshInputs[creationID] = nil
                    self.update(creationID) { $0.phase = .failed; $0.errorCode = "media_session_unavailable" }
                }
                self.errorMessage = self.localizedFailure("media_session_unavailable", language: language)
                _ = self.persistCurrentHistory()
            }
        }
    }

    private func beginHydration(for creationID: UUID, language: AppLanguage) {
        guard workTasks[creationID] == nil, let ownerID = loadedOwnerID else { return }
        let ticket = ownerGeneration
        let workID = UUID()
        workIDs[creationID] = workID
        workTasks[creationID] = Task { [weak self] in
            guard let self else { return }
            defer { self.completeWork(creationID, workID: workID, ticket: ticket) }
            guard self.accepts(ticket, ownerID: ownerID) else { return }
            do {
                let credentials = try await self.api.mediaCredentialSnapshot()
                guard self.accepts(ticket, ownerID: ownerID) else { return }
                await MediaCredentialScope.$current.withValue(credentials) {
                    await self.hydrateCompletedCreation(creationID, language: language, ticket: ticket)
                }
            } catch {
                guard self.accepts(ticket, ownerID: ownerID) else { return }
                self.update(creationID) { $0.errorCode = "result_download_pending" }
                self.errorMessage = self.localizedFailure("media_session_unavailable", language: language)
            }
        }
    }

    private func retireWork(_ id: UUID) {
        workIDs[id] = nil
        workTasks.removeValue(forKey: id)?.cancel()
        loadingAssetIDs.remove(id)
        isLoading = !loadingAssetIDs.isEmpty
    }

    private func completeWork(_ id: UUID, workID: UUID, ticket: Int) {
        guard ownerGeneration == ticket, workIDs[id] == workID else { return }
        workIDs[id] = nil
        workTasks[id] = nil
        startingIDs.remove(id)
        freshInputs[id] = nil
        resolveAcceptance(id, accepted: false)
    }

    private func resolveAcceptance(_ id: UUID, accepted: Bool) {
        let continuation = acceptanceWaiters.removeValue(forKey: id)
        isCreating = preparationID != nil || !acceptanceWaiters.isEmpty
        continuation?.resume(returning: accepted)
    }

    private func enqueueOrResume(_ creationID: UUID, language: AppLanguage, ticket: Int) async {
        guard let initial = creation(id: creationID),
              accepts(ticket, ownerID: initial.ownerID)
        else { return }

        guard initial.phase.isActive else { resolveAcceptance(creationID, accepted: false); return }

        if let jobID = initial.jobID {
            if initial.stopRequested == true {
                await stopKnown(creationID, jobID: jobID, language: language, ticket: ticket)
            } else {
                await poll(creationID: creationID, jobID: jobID, language: language, ticket: ticket)
            }
            return
        }

        guard let cid = initial.cid, Self.validCID(cid), initial.chatID != nil else {
            // Old versions stored no receipt or bound Chat. Opening Studio may
            // show that history, but cannot authorise a fresh paid render.
            await fail(creationID, code: "legacy_media_binding_missing", language: language, ticket: ticket)
            return
        }
        guard initial.startAttempted == false else {
            await poll(creationID: creationID, jobID: nil, language: language, ticket: ticket)
            return
        }
        guard freshInputs[creationID] != nil else {
            await fail(creationID, code: "media_resume_requires_receipt", language: language, ticket: ticket)
            return
        }
        guard initial.stopRequested != true else {
            update(creationID) { $0.phase = .stopped; $0.errorCode = nil }
            _ = persistCurrentHistory()
            resolveAcceptance(creationID, accepted: false)
            return
        }

        // Persist the uncertain boundary BEFORE dispatch. Even a process exit
        // here can only reconnect by CID; it can never replay this POST.
        update(creationID) { $0.startAttempted = true; $0.phase = .queued }
        guard persistCurrentHistory() else {
            await fail(creationID, code: "media_storage_unavailable", language: language, ticket: ticket)
            return
        }
        startingIDs.insert(creationID)
        do {
            let response = try await start(initial)
            guard accepts(ticket, ownerID: initial.ownerID) else { return }
            startingIDs.remove(creationID)
            guard response.ok == true, response.cid == initial.cid, response.chatId == initial.chatID,
                  Self.validKey(response.jobId), let phase = response.phase,
                  ["queued", "running", "done", "fail"].contains(phase),
                  response.key == nil || response.key == response.jobId
            else { throw APIError.invalidResponse }
            let status = MediaJobStatusResponse(phase: phase, key: response.key,
                error: response.error, reason: nil, jobId: response.jobId, cid: response.cid, chatId: response.chatId, ok: true)
            try await applyStatus(status, creationID: creationID, language: language, ticket: ticket)
            guard accepts(ticket, ownerID: initial.ownerID), let current = creation(id: creationID) else { return }
            resolveAcceptance(creationID, accepted: phase != "fail" && current.stopRequested != true)
            _ = await NotificationCoordinator.shared.requestAuthorizationIfNeeded(
                context: .durableJobStarted, preferredLanguageCode: language.rawValue
            )
            guard accepts(ticket, ownerID: initial.ownerID) else { return }
            if current.phase == .completed {
                await hydrateCompletedCreation(creationID, language: language, ticket: ticket)
            } else if current.phase.isActive {
                await poll(creationID: creationID, jobID: current.jobID, language: language, ticket: ticket)
            }
        } catch is CancellationError {
            startingIDs.remove(creationID)
            return
        } catch {
            guard accepts(ticket, ownerID: initial.ownerID) else { return }
            startingIDs.remove(creationID)
            if definitiveRejection(error) {
                await fail(creationID, error: error, language: language, ticket: ticket)
            } else {
                update(creationID) { $0.errorCode = "receipt_pending" }
                _ = persistCurrentHistory()
                // Three original-CID reads bound the caller's wait. Unknown or
                // invalid receipts retain the draft and keep admission blocked.
                for attempt in 0..<3 {
                    if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
                    guard accepts(ticket, ownerID: initial.ownerID) else { return }
                    do {
                        let status = try await api.mediaJobReceipt(kind: initial.kind, cid: cid)
                        guard accepts(ticket, ownerID: initial.ownerID) else { return }
                        try await applyStatus(status, creationID: creationID, language: language, ticket: ticket)
                        guard let current = creation(id: creationID) else { return }
                        if status.phase != "unknown", current.jobID != nil {
                            resolveAcceptance(creationID, accepted: status.phase != "fail" && current.stopRequested != true)
                            if current.phase == .completed {
                                await hydrateCompletedCreation(creationID, language: language, ticket: ticket)
                            } else if current.phase.isActive {
                                await poll(creationID: creationID, jobID: current.jobID, language: language, ticket: ticket)
                            }
                            return
                        }
                    } catch is CancellationError { return }
                    catch { /* A read failure never grants another paid POST. */ }
                }
                resolveAcceptance(creationID, accepted: false)
                await poll(creationID: creationID, jobID: nil, language: language, ticket: ticket)
            }
        }
    }

    private func start(_ creation: MediaCreation) async throws -> MediaJobStartResponse {
        // Keep large source data in this short-lived dispatch frame, rather
        // than retaining it in the polling loop until the cloud render ends.
        guard let input = freshInputs.removeValue(forKey: creation.id) else {
            throw APIError.invalidRequest("media_fresh_input_missing")
        }
        guard let cid = creation.cid, let chatID = creation.chatID else {
            throw APIError.invalidRequest("The media conversation binding is missing.")
        }
        let binding = MediaTurnBinding(ownerID: creation.ownerID, chatID: chatID, cid: cid)
        let tier = creation.tier ?? ModelTier.pro.rawValue
        let languageCode = creation.languageCode ?? "ar"
        switch creation.kind {
        case .image:
            return try await api.startImageJob(
                prompt: input.prompt,
                preset: creation.aspect ?? .square,
                sourceImage: input.sourceImage,
                binding: binding, tier: tier, languageCode: languageCode
            )
        case .video:
            return try await api.startVideoJob(
                prompt: input.prompt,
                seconds: creation.seconds ?? 10,
                sourceImage: input.sourceImage,
                binding: binding, tier: tier, languageCode: languageCode
            )
        case .music:
            return try await api.startMusicJob(
                prompt: input.prompt,
                lyrics: input.lyrics ?? "",
                seconds: creation.seconds ?? 90,
                binding: binding, tier: tier, languageCode: languageCode
            )
        }
    }

    private func poll(
        creationID: UUID,
        jobID: String?,
        language: AppLanguage,
        ticket: Int
    ) async {
        guard let initial = creation(id: creationID), accepts(ticket, ownerID: initial.ownerID) else { return }
        var knownJobID = jobID
        update(creationID) {
            if $0.phase != .completed {
                $0.phase = $0.stopRequested == true ? .stopping : knownJobID == nil ? .queued : .running
            }
        }
        persistCurrentHistory()

        var delay: Duration = .milliseconds(1_500)
        var transportFailures = 0

        // The server owns the durable terminal state. A client-side clock must
        // never turn a still-rendering cloud job into a permanent failure.
        while !Task.isCancelled {
            guard let current = creation(id: creationID),
                  accepts(ticket, ownerID: current.ownerID)
            else { return }
            if current.stopRequested == true, let knownJobID {
                await stopKnown(creationID, jobID: knownJobID, language: language, ticket: ticket)
                return
            }
            do {
                let status: MediaJobStatusResponse
                if let knownJobID {
                    status = try await api.mediaJobStatus(kind: current.kind, id: knownJobID)
                } else if let cid = current.cid {
                    status = try await api.mediaJobReceipt(kind: current.kind, cid: cid)
                } else { return }
                guard accepts(ticket, ownerID: current.ownerID) else { return }
                try await applyStatus(status, creationID: creationID, language: language, ticket: ticket)
                guard accepts(ticket, ownerID: current.ownerID), let updated = creation(id: creationID) else { return }
                knownJobID = updated.jobID
                transportFailures = 0
                if updated.phase == .completed {
                    await hydrateCompletedCreation(creationID, language: language, ticket: ticket)
                    return
                } else if updated.phase.isTerminal {
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                guard accepts(ticket, ownerID: current.ownerID) else { return }
                transportFailures += 1
                if error as? APIError == .invalidResponse {
                    update(creationID) { $0.errorCode = "media_receipt_mismatch" }
                    resolveAcceptance(creationID, accepted: false)
                    _ = persistCurrentHistory()
                    return
                }
                if transportFailures >= 3 {
                    errorMessage = message(for: error, language: language)
                }
            }

            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            delay = nextPollDelay(delay)
        }
    }

    private func applyStatus(_ status: MediaJobStatusResponse, creationID: UUID,
                             language: AppLanguage, ticket: Int) async throws {
        guard let current = creation(id: creationID), accepts(ticket, ownerID: current.ownerID) else { return }
        guard status.ok != false, ["queued", "running", "done", "fail", "unknown"].contains(status.phase),
              current.cid == nil || status.cid == nil || current.cid == status.cid,
              current.chatID == nil || status.chatId == nil || current.chatID == status.chatId,
              status.cid == nil || Self.validCID(status.cid!),
              status.chatId == nil || (!status.chatId!.isEmpty && status.chatId!.utf16.count <= 128)
        else { throw APIError.invalidResponse }
        let returnedID = status.jobId.flatMap { $0.isEmpty ? nil : $0 }
        if status.phase == "unknown" {
            guard returnedID == nil, status.key == nil else { throw APIError.invalidResponse }
        } else {
            guard let returnedID, MediaRequestPolicy.validKey(returnedID),
                  current.jobID == nil || current.jobID == returnedID else { throw APIError.invalidResponse }
            if current.startAttempted == true, let cid = current.cid {
                guard returnedID == MediaRequestPolicy.receiptKey(kind: current.kind, ownerID: current.ownerID, cid: cid)
                else { throw APIError.invalidResponse }
            }
        }
        if let key = status.key {
            guard MediaRequestPolicy.validKey(key), key == returnedID else { throw APIError.invalidResponse }
        }
        if status.phase == "done", status.key == nil { throw APIError.invalidResponse }
        update(creationID) {
            if $0.cid == nil { $0.cid = status.cid }
            if $0.chatID == nil { $0.chatID = status.chatId }
            if let returnedID { $0.jobID = returnedID }
            if let key = status.key { $0.resultKey = key }
            $0.errorCode = nil
            if status.phase == "unknown" { $0.errorCode = "receipt_pending" }
            $0.phase = $0.stopRequested == true ? .stopping : returnedID == nil ? .queued : .running
        }
        _ = persistCurrentHistory()
        if status.phase == "done", let key = status.key {
            await finish(creationID, key: key, language: language, ticket: ticket)
        } else if status.phase == "fail" {
            let code = safeFailureCode(status.resolvedError)
            if code == current.kind.rawValue + "_cancelled" {
                update(creationID) { $0.phase = .stopped; $0.errorCode = nil }
                _ = persistCurrentHistory()
                resolveAcceptance(creationID, accepted: false)
            } else {
                await fail(creationID, code: code, language: language, ticket: ticket)
            }
        }
    }

    private func stopKnown(_ creationID: UUID, jobID: String, language: AppLanguage, ticket: Int) async {
        guard let current = creation(id: creationID), accepts(ticket, ownerID: current.ownerID),
              MediaRequestPolicy.cancellationID(kind: current.kind, key: jobID) != nil else { return }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(300 * (attempt + 1))) }
            guard accepts(ticket, ownerID: current.ownerID) else { return }
            var acknowledged = false
            do {
                let response = try await api.cancelMediaJob(kind: current.kind, jobID: jobID)
                guard accepts(ticket, ownerID: current.ownerID) else { return }
                acknowledged = response.ok && response.stopped
            } catch is CancellationError { return }
            catch { /* Idempotent Stop retries only, never a creation replay. */ }
            do {
                let status = try await api.mediaJobStatus(kind: current.kind, id: jobID)
                guard accepts(ticket, ownerID: current.ownerID) else { return }
                try await applyStatus(status, creationID: creationID, language: language, ticket: ticket)
                if creation(id: creationID)?.phase == .completed {
                    await hydrateCompletedCreation(creationID, language: language, ticket: ticket)
                    return
                }
                if creation(id: creationID)?.phase.isTerminal == true { return }
            } catch is CancellationError { return }
            catch { /* A failed status read does not erase an acknowledged Stop. */ }
            guard accepts(ticket, ownerID: current.ownerID) else { return }
            if acknowledged {
                update(creationID) { $0.phase = .stopped; $0.errorCode = nil }
                _ = persistCurrentHistory()
                return
            }
        }
        guard accepts(ticket, ownerID: current.ownerID) else { return }
        update(creationID) { $0.phase = .stopping; $0.errorCode = "stop_unconfirmed" }
        _ = persistCurrentHistory()
        errorMessage = localizedFailure("stop_unconfirmed", language: language)
    }

    private func finish(_ creationID: UUID, key: String, language: AppLanguage, ticket: Int) async {
        guard let current = creation(id: creationID),
              accepts(ticket, ownerID: current.ownerID)
        else { return }

        guard await FirasCompletionCue.prepareForReveal(
            productID: "media-\(current.kind.rawValue)",
            jobID: current.jobID ?? key
        ),
        !Task.isCancelled,
        accepts(ticket, ownerID: current.ownerID)
        else { return }

        update(creationID) {
            $0.phase = .completed
            $0.resultKey = key
            $0.errorCode = nil
            $0.stopRequested = false
        }
        persistCurrentHistory()

        await NotificationCoordinator.shared.scheduleLocalFallbackIfNeeded(
            product: .ai,
            jobID: current.jobID ?? key,
            chatID: current.chatID,
            mediaKind: current.kind,
            outcome: .completed
        )
    }

    private func hydrateCompletedCreation(_ creationID: UUID, language: AppLanguage, ticket: Int) async {
        guard let current = creation(id: creationID),
              accepts(ticket, ownerID: current.ownerID),
              let workID = workIDs[creationID], current.phase == .completed,
              let key = current.resultKey,
              !hasReadableLocalAsset(current)
        else { return }

        loadingAssetIDs.insert(creationID)
        isLoading = true
        defer {
            if ownerGeneration == ticket && workIDs[creationID] == workID {
                loadingAssetIDs.remove(creationID)
                isLoading = !loadingAssetIDs.isEmpty
            }
        }

        var attempts = 0
        while !Task.isCancelled, attempts < 3 {
            do {
                let download = try await api.mediaAssetFile(kind: current.kind, key: key)
                // Every transfer owns a unique staging file. A retired response
                // is cleaned without exposing or deleting another owner's cache.
                defer { try? FileManager.default.removeItem(at: download.fileURL) }
                guard accepts(ticket, ownerID: current.ownerID), workIDs[creationID] == workID else { return }
                let url = try await repository.save(
                    download,
                    kind: current.kind,
                    identifier: key,
                    ownerID: current.ownerID
                )
                guard accepts(ticket, ownerID: current.ownerID), workIDs[creationID] == workID,
                      let activeRow = creation(id: creationID), activeRow.phase == .completed,
                      activeRow.resultKey == key else {
                    // Imports use a unique owner-scoped destination, so stale
                    // cleanup cannot remove another transfer's cached file.
                    try? await repository.remove(url)
                    return
                }
                update(creationID) {
                    $0.localFileURL = url
                    $0.errorCode = nil
                }
                persistCurrentHistory()
                return
            } catch is CancellationError {
                return
            } catch {
                guard accepts(ticket, ownerID: current.ownerID) else { return }
                attempts += 1
                if attempts == 3 {
                    update(creationID) { $0.errorCode = "result_download_pending" }
                    persistCurrentHistory()
                    errorMessage = language == .arabic
                        ? "اكتملت النتيجة. اضغط تنزيل للمحاولة عند عودة الاتصال."
                        : "The result is ready. Tap Download to try again when connected."
                    return
                }
                try? await Task.sleep(for: .seconds(attempts * 2))
            }
        }
    }

    private func fail(_ creationID: UUID, error: Error, language: AppLanguage, ticket: Int) async {
        let code: String
        if let apiError = error as? APIError {
            switch apiError {
            case .httpStatus(_, let message): code = safeFailureCode(message)
            default: code = "render_failed"
            }
        } else {
            code = "render_failed"
        }
        await fail(creationID, code: code, language: language, ticket: ticket)
    }

    private func fail(_ creationID: UUID, code: String, language: AppLanguage, ticket: Int) async {
        guard let current = creation(id: creationID), accepts(ticket, ownerID: current.ownerID) else { return }
        update(creationID) {
            $0.phase = .failed
            $0.errorCode = safeFailureCode(code)
        }
        resolveAcceptance(creationID, accepted: false)
        persistCurrentHistory()
        errorMessage = localizedFailure(code, language: language)
        await NotificationCoordinator.shared.scheduleLocalFallbackIfNeeded(
            product: .ai,
            jobID: current.jobID ?? current.id.uuidString,
            chatID: current.chatID,
            mediaKind: current.kind,
            outcome: .failed
        )
    }

    private func creation(id: UUID) -> MediaCreation? {
        creations.first { $0.id == id }
    }

    private func accepts(_ ticket: Int, ownerID: String) -> Bool {
        ownerGeneration == ticket && loadedOwnerID == ownerID &&
            session.identityID == ownerID && session.identityGeneration == adoptedIdentityGeneration &&
            session.isAuthenticated && !session.isWorking && !Task.isCancelled
    }

    private func update(_ id: UUID, mutate: (inout MediaCreation) -> Void) {
        guard let index = creations.firstIndex(where: { $0.id == id }) else { return }
        var next = creations[index]
        mutate(&next)
        guard next != creations[index] else { return }
        next.updatedAt = Date()
        creations[index] = next
    }

    private func hasReadableLocalAsset(_ creation: MediaCreation) -> Bool {
        guard let url = creation.localFileURL else { return false }
        return repository.owns(url, ownerID: creation.ownerID) && FileManager.default.fileExists(atPath: url.path)
    }

    private func trimHistory() {
        creations.sort { $0.createdAt > $1.createdAt }
        guard creations.count > Self.historyLimit else { return }
        let active = creations.filter(\.phase.isActive)
        let finished = creations.filter { !$0.phase.isActive }
        // Never evict a receipt whose paid submission is still unresolved.
        // The bounded display history applies only to finished creations.
        creations = (active + Array(finished.prefix(Self.historyLimit)))
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func historyMap() -> [String: [MediaCreation]] {
        let raw = defaults.data(forKey: Self.historyMapKey)
        if hasHistoryCache, raw == cachedHistoryData {
            historyReadable = cachedHistoryMap != nil
            return cachedHistoryMap?.mapValues { $0.map(Self.receiptOnly) } ?? [:]
        }
        hasHistoryCache = true
        cachedHistoryData = raw
        guard let data = raw else { cachedHistoryMap = [:]; historyReadable = true; return [:] }
        guard data.count <= Self.maximumHistoryBytes,
              let map = try? JSONDecoder().decode([String: [MediaCreation]].self, from: data),
              map.count <= 256,
              map.allSatisfy({ ownerID, rows in
                  !ownerID.isEmpty && rows.count <= Self.maximumActiveReceipts + Self.historyLimit &&
                      rows.allSatisfy { $0.ownerID == ownerID }
              })
        else { cachedHistoryMap = nil; historyReadable = false; return [:] }
        cachedHistoryMap = map
        historyReadable = true
        return map.mapValues { $0.map(Self.receiptOnly) }
    }

    @discardableResult private func persistCurrentHistory() -> Bool {
        guard let loadedOwnerID else { return false }
        trimHistory()
        var map = historyMap()
        guard historyReadable else { return false }
        map[loadedOwnerID] = creations.map(Self.receiptOnly)
        if map == cachedHistoryMap { return true }
        guard let data = try? JSONEncoder().encode(map), data.count <= Self.maximumHistoryBytes else { return false }
        defaults.set(data, forKey: Self.historyMapKey)
        cachedHistoryData = data
        cachedHistoryMap = map
        hasHistoryCache = true
        return true
    }

    private static func receiptOnly(_ row: MediaCreation) -> MediaCreation {
        MediaCreation(id: row.id, ownerID: row.ownerID, kind: row.kind, prompt: "",
            aspect: row.aspect, seconds: row.seconds, createdAt: row.createdAt, updatedAt: row.updatedAt,
            phase: row.phase, jobID: row.jobID, resultKey: row.resultKey,
            localFileURL: row.localFileURL, errorCode: row.errorCode,
            cid: row.cid, chatID: row.chatID, tier: row.tier, languageCode: row.languageCode,
            startAttempted: row.startAttempted, stopRequested: row.stopRequested, sourceWasProvided: row.sourceWasProvided)
    }

    private static func validCID(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func validKey(_ value: String) -> Bool {
        value.utf8.count == 64 && MediaRequestPolicy.validKey(value)
    }

    private func safeFailureCode(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw.utf8.count <= 80,
              raw.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 })
        else { return "render_failed" }
        return raw
    }

    private func currentLanguage() -> AppLanguage {
        let raw = defaults.string(forKey: "lang") ?? "ar"
        return AppLanguage(rawValue: raw) ?? .arabic
    }

    private func nextPollDelay(_ current: Duration) -> Duration {
        switch current {
        case ..<Duration.seconds(2): .seconds(2)
        case ..<Duration.seconds(3): .seconds(3)
        case ..<Duration.seconds(4): .seconds(4)
        default: .seconds(6)
        }
    }

    private func definitiveRejection(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .transport, .invalidResponse, .decoding:
            return false
        case .httpStatus(let code, _):
            // An HTTP request timeout or duplicate-receipt conflict can follow
            // acceptance. Neither authorizes another paid creation.
            return (400...499).contains(code) && code != 408 && code != 409
        case .invalidRequest(let code):
            // Credential retirement can happen after a paid request reached
            // the server. It cannot become a definite admission rejection.
            return code != "media_session_changed" && code != "media_session_required"
        case .invalidURL, .encoding, .skillValidation:
            return true
        }
    }

    private func localizedFailure(_ code: String, language: AppLanguage) -> String {
        let key = code.lowercased()
        if key == "stop_unconfirmed" {
            return language == .arabic ? "لم يتأكد الإيقاف بعد. يمكنك الضغط على إيقاف مجدداً."
                : "Stop is not confirmed yet. You can tap Stop again."
        }
        if key == "media_storage_unavailable" || key == "media_resume_requires_receipt" {
            return language == .arabic ? "تعذّر استرجاع إيصال المهمة. لم يُرسل طلب إنشاء جديد."
                : "The job receipt could not be restored. No new creation was sent."
        }
        if key == "media_session_unavailable" {
            return language == .arabic ? "تحقّق من تسجيل الدخول ثم افتح المهمة مجدداً."
                : "Check your sign-in, then reopen this job."
        }
        if key == "media_input_invalid" {
            return language == .arabic ? "راجع طول الوصف والمدة قبل الإنشاء."
                : "Check the brief length and duration before creating."
        }
        if key.contains("submission_uncertain") || key == "media_receipt_mismatch" {
            return language == .arabic
                ? "تعذّر تأكيد نتيجة الطلب الأصلي. لم يُرسل طلب إنشاء آخر."
                : "The original result could not be confirmed. It has not been submitted again."
        }
        if language == .arabic {
            if key.contains("signin_required") || key.contains("auth") { return "سجّل الدخول لبدء الإنشاء." }
            if key.contains("daily_limit") { return "وصلت إلى حد إنشاء الصور اليومي." }
            if key.contains("rate_window") || key.contains("rate_limited") { return "الإنشاء مزدحم الآن؛ حاول بعد قليل." }
            if key.contains("site_media_ceiling") { return "توقّف إنشاء الوسائط مؤقتاً لحماية الرصيد." }
            if key.contains("not_configured") || key.contains("unconfigured") { return "محرك الوسائط غير متاح حالياً." }
            if key.contains("timeout") { return "استغرقت المهمة وقتاً أطول من المتوقع. يمكنك المحاولة مجدداً." }
            return "تعذّر إكمال الإنشاء. جرّب وصفاً مختلفاً أو أعد المحاولة."
        }
        if key.contains("signin_required") || key.contains("auth") { return "Sign in to start creating." }
        if key.contains("daily_limit") { return "You reached today's image creation limit." }
        if key.contains("rate_window") || key.contains("rate_limited") { return "Creation is busy right now. Try again shortly." }
        if key.contains("site_media_ceiling") { return "Media creation is temporarily paused to protect capacity." }
        if key.contains("not_configured") || key.contains("unconfigured") { return "The media engine is currently unavailable." }
        if key.contains("timeout") { return "This job took longer than expected. You can try it again." }
        return "Creation could not finish. Try another brief or retry."
    }

    private func message(for error: Error, language: AppLanguage) -> String {
        if let apiError = error as? APIError {
            return localizedFailure(apiError.errorDescription ?? "network", language: language)
        }
        return language == .arabic ? "تعذّر إكمال العملية." : "The connection could not complete this operation."
    }
}

actor MediaAssetRepository {
    private nonisolated let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let root = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.directory = root
                .appendingPathComponent("FirasAI", isDirectory: true)
                .appendingPathComponent("MediaStudio", isDirectory: true)
        }
    }

    func save(
        _ download: MediaAssetFileDownload,
        kind: MediaStudioKind,
        identifier: String,
        ownerID: String
    ) throws -> URL {
        guard !ownerID.isEmpty, MediaRequestPolicy.validKey(identifier) else { throw APIError.invalidResponse }
        try Task.checkCancellation()
        let values = try download.fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw APIError.invalidResponse }
        let handle = try FileHandle(forReadingFrom: download.fileURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 512) ?? Data()
        guard let metadata = MediaAssetPolicy.inspect(kind: kind, key: identifier, mimeType: download.mimeType,
            prefix: prefix, totalBytes: Int64(size)) else { throw APIError.invalidResponse }
        let ownerDirectory = directory.appendingPathComponent(Self.ownerFolder(ownerID), isDirectory: true)
        try FileManager.default.createDirectory(
            at: ownerDirectory,
            withIntermediateDirectories: true
        )
        let filename = "firas-\(kind.rawValue)-\(identifier)-\(UUID().uuidString).\(metadata.fileExtension)"
        let url = ownerDirectory.appendingPathComponent(filename, isDirectory: false)
        guard owns(url, ownerID: ownerID) else { throw APIError.invalidResponse }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: download.fileURL, to: url)
        return url
    }

    nonisolated func owns(_ url: URL, ownerID: String) -> Bool {
        guard url.isFileURL, !ownerID.isEmpty else { return false }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let expected = root.appendingPathComponent(Self.ownerFolder(ownerID), isDirectory: true)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        return expected.deletingLastPathComponent() == root && resolved.deletingLastPathComponent() == expected
    }

    private nonisolated static func ownerFolder(_ ownerID: String) -> String {
        SHA256.hash(data: Data(ownerID.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func remove(_ url: URL) throws {
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedURL.deletingLastPathComponent().deletingLastPathComponent() == resolvedDirectory else { return }
        if FileManager.default.fileExists(atPath: resolvedURL.path) {
            try FileManager.default.removeItem(at: resolvedURL)
        }
    }

}

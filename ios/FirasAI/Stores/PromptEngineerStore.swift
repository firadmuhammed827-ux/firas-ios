import Foundation
import Observation

/// An app-owned observer of one durable helper. Only the in-memory Start frame
/// carries a request; a restored pointer can only GET/cancel its original job.
@MainActor @Observable
final class PromptEngineerStore {
    private(set) var pointer: PromptEngineerPointer?
    private(set) var phase: PromptEngineerPhase?
    private(set) var text = ""
    private(set) var problem: String?
    private(set) var automaticallyApplied = false
    private(set) var isObserving = false
    private(set) var ownerID: String?
    private(set) var identityGeneration = 0
    private(set) var presentationID: UUID?
    private(set) var canForgetUnavailableReceipt = false

    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let api: any PromptEngineerAPI
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let chatStore: ChatStore
    @ObservationIgnored private let pollDelay: Duration
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var workID: UUID?
    @ObservationIgnored private var dispatchingID: UUID?
    @ObservationIgnored private var leases: Set<UUID> = []
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var corruptPointer = false
    @ObservationIgnored private var applicationSnapshot: ChatDraftSnapshot<DraftContextSelection>?

    init(session: SessionStore, chatStore: ChatStore, api: any PromptEngineerAPI,
         defaults: UserDefaults = .standard, pollDelay: Duration = .seconds(1)) {
        self.session = session
        self.chatStore = chatStore
        self.api = api
        self.defaults = defaults
        self.pollDelay = pollDelay
    }

    var isCurrentOwner: Bool {
        !session.isWorking && (session.isAuthenticated || session.isGuest) &&
        ownerID == session.identityID && identityGeneration == session.identityGeneration
    }
    var visibleText: String { isCurrentOwner ? text : "" }
    var blocksNewHelper: Bool { isCurrentOwner && phase != nil && phase?.isTerminal == false }
    var blocksOrdinarySend: Bool {
        guard isCurrentOwner, let phase else { return false }
        return [.preparing, .queued, .processing, .stopping].contains(phase)
    }
    var canApply: Bool { isCurrentOwner && phase?.isTerminal == true && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasResult: Bool { isCurrentOwner && (pointer != nil || corruptPointer) }

    func synchronizeOwner() {
        let owner = session.isAuthenticated || session.isGuest ? session.identityID : nil
        guard ownerID != owner || identityGeneration != session.identityGeneration else { return }
        retireWork()
        ownerID = owner
        identityGeneration = session.identityGeneration
        pointer = nil
        phase = nil
        text = ""
        problem = nil
        automaticallyApplied = false
        applicationSnapshot = nil
        presentationID = nil
        corruptPointer = false
        canForgetUnavailableReceipt = false
        guard let owner else { return }
        let key = storageKey(owner)
        guard let data = defaults.data(forKey: key) else { return }
        guard data.count <= 4_096,
              let saved = try? JSONDecoder().decode(PromptEngineerPointer.self, from: data),
              saved.ownerID == owner, PromptEngineerPolicy.validCID(saved.cid),
              saved.jobID == nil || saved.jobID == PromptEngineerPolicy.jobID(ownerID: owner, cid: saved.cid),
              ["ar", "en"].contains(saved.languageCode) else {
            corruptPointer = true
            phase = .uncertain
            problem = "storage_unavailable"
            return
        }
        pointer = saved
        phase = saved.stopRequested ? .stopping : .uncertain
        resumeIfNeeded()
    }

    /// Reserve synchronously, before the credential snapshot or any transport.
    @discardableResult
    func start(snapshot: ChatDraftSnapshot<DraftContextSelection>, languageCode: String) -> Bool {
        synchronizeOwner()
        guard !Task.isCancelled, !session.isWorking, ownerID == snapshot.ownerID,
              identityGeneration == snapshot.identityGeneration, !chatStore.isSending,
              !blocksNewHelper, workID == nil, !corruptPointer,
              let source = PromptEngineerPolicy.source(snapshot.text) else {
            if !blocksNewHelper { problem = "input_invalid" }
            return false
        }
        let cid = "pe_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let saved = PromptEngineerPointer(ownerID: snapshot.ownerID, cid: cid, jobID: nil,
            languageCode: languageCode == "en" ? "en" : "ar", startedAt: .now, stopRequested: false)
        guard save(saved) else { problem = "storage_unavailable"; return false }
        pointer = saved
        phase = .preparing
        text = ""
        problem = nil
        automaticallyApplied = false
        canForgetUnavailableReceipt = false
        applicationSnapshot = snapshot
        launch(fresh: PromptEngineerJobRequest(cid: cid, source: source, languageCode: saved.languageCode))
        return true
    }

    func acquireObservation() -> UUID {
        let lease = UUID()
        leases.insert(lease)
        synchronizeOwner()
        resumeIfNeeded()
        return lease
    }

    func releaseObservation(_ lease: UUID) {
        leases.remove(lease)
        if leases.isEmpty { pauseObservation() }
    }

    func setForeground(_ value: Bool) {
        foreground = value
        if value { synchronizeOwner(); resumeIfNeeded() }
        else { pauseObservation() }
    }

    func resumeIfNeeded() {
        guard foreground, !leases.isEmpty, !session.isWorking else { return }
        synchronizeOwner()
        guard pointer != nil, workID == nil, phase?.isTerminal != true else { return }
        launch(fresh: nil)
    }

    /// Navigation never calls this. The tap carries the row's immutable owner,
    /// identity epoch and CID, so a queued old Stop cannot affect a replacement.
    func stop(cid: String, expectedOwnerID: String, expectedIdentityGeneration: Int) {
        synchronizeOwner()
        guard ownerID == expectedOwnerID, identityGeneration == expectedIdentityGeneration,
              !session.isWorking, var saved = pointer, saved.cid == cid,
              phase?.isTerminal != true else { return }
        saved.stopRequested = true
        guard save(saved) else { problem = "storage_unavailable"; return }
        pointer = saved
        phase = .stopping
        // A submitted POST is allowed to settle; its continuation resolves the
        // original receipt. No second POST exists in this store.
        if dispatchingID != nil { return }
        retireWork()
        launch(fresh: nil, explicitStop: true)
    }

    func requestPresentation() { synchronizeOwner(); if hasResult { presentationID = UUID() } }
    func consumePresentation(_ id: UUID) { if presentationID == id { presentationID = nil } }

    /// Explicit local removal after an owned read proved the receipt absent.
    /// It is never a server Stop, a retry, or automatic permission to dispatch.
    func forgetUnavailableReceipt(cid: String, expectedOwnerID: String, expectedIdentityGeneration: Int) {
        synchronizeOwner()
        guard canForgetUnavailableReceipt, workID == nil, !session.isWorking,
              ownerID == expectedOwnerID, identityGeneration == expectedIdentityGeneration,
              let saved = pointer, saved.cid == cid else { return }
        removePointer(saved)
        pointer = nil; phase = nil; text = ""; problem = nil
        applicationSnapshot = nil; automaticallyApplied = false
        canForgetUnavailableReceipt = false
    }

    func matchesNotification(jobID: String) -> Bool {
        synchronizeOwner()
        guard !session.isWorking, let saved = pointer, saved.ownerID == ownerID else { return false }
        return jobID == (saved.jobID ?? PromptEngineerPolicy.jobID(ownerID: saved.ownerID, cid: saved.cid))
    }

    /// Explicit application uses the current revision captured by the tap.
    @discardableResult
    func apply(snapshot: ChatDraftSnapshot<DraftContextSelection>) -> Bool {
        synchronizeOwner()
        guard canApply, snapshot.ownerID == ownerID, snapshot.identityGeneration == identityGeneration else { return false }
        let applied = chatStore.replaceDraft(with: text, matching: snapshot)
        if applied { automaticallyApplied = true }
        return applied
    }

    private func launch(fresh: PromptEngineerJobRequest?, explicitStop: Bool = false) {
        guard let saved = pointer, workID == nil, ownerID == saved.ownerID, !session.isWorking else { return }
        let id = UUID()
        let epoch = identityGeneration
        workID = id
        if fresh != nil { dispatchingID = id }
        isObserving = true
        work = Task { [weak self] in
            guard let self else { return }
            await self.run(id: id, epoch: epoch, original: saved, fresh: fresh, explicitStop: explicitStop)
        }
    }

    private func run(id: UUID, epoch: Int, original: PromptEngineerPointer,
                     fresh: PromptEngineerJobRequest?, explicitStop: Bool) async {
        var attempted = false
        defer {
            if workID == id { work = nil; workID = nil; isObserving = false }
            if dispatchingID == id { dispatchingID = nil }
        }
        do {
            let credentials = try await api.mediaCredentialSnapshot()
            guard accepts(id, epoch: epoch, cid: original.cid) else { return }
            try await MediaCredentialScope.$current.withValue(credentials) {
                // Consumed only by this initial in-memory Start frame. Restore
                // and local observer replacement never possess the source.
                if let fresh {
                    if pointer?.stopRequested == true {
                        finishBeforeAdmission(original, id: id, epoch: epoch)
                        return
                    }
                    guard accepts(id, epoch: epoch, cid: original.cid) else { return }
                    do {
                        attempted = true
                        let ack = try await api.startPromptEngineer(fresh)
                        guard accepts(id, epoch: epoch, cid: original.cid) else { return }
                        if ack.ok, ack.jobId == PromptEngineerPolicy.jobID(ownerID: original.ownerID, cid: original.cid),
                           ["queued", "processing", "completed", "done", "failed", "fail"].contains(ack.phase) {
                            guard recordJobID(ack.jobId) else { return }
                            phase = pointer?.stopRequested == true ? .stopping : .queued
                        } else { phase = .uncertain; problem = "receipt_invalid" }
                    } catch {
                        guard accepts(id, epoch: epoch, cid: original.cid) else { return }
                        if definiteRejection(error) {
                            removePointer(original)
                            pointer = nil; phase = .failed; problem = "admission_rejected"
                            applicationSnapshot = nil
                            return
                        }
                        phase = .uncertain; problem = "receipt_unavailable"
                    }
                    if dispatchingID == id { dispatchingID = nil }
                }
                guard accepts(id, epoch: epoch, cid: original.cid) else { return }
                var failures = 0
                while accepts(id, epoch: epoch, cid: original.cid) {
                    do {
                        if pointer?.jobID == nil {
                            let receipt = try await api.promptEngineerReceipt(cid: original.cid)
                            guard accepts(id, epoch: epoch, cid: original.cid) else { return }
                            guard let saved = pointer, PromptEngineerPolicy.acceptsReceipt(receipt, pointer: saved) else {
                                if receipt.phase == "unknown", receipt.jobId.isEmpty { canForgetUnavailableReceipt = true }
                                phase = .uncertain; problem = "receipt_unavailable"
                                return
                            }
                            canForgetUnavailableReceipt = false
                            guard recordJobID(receipt.jobId) else { return }
                        }
                        guard let saved = pointer, let jobID = saved.jobID else { return }
                        if saved.stopRequested {
                            await cancelOriginal(saved, id: id, epoch: epoch)
                            return
                        }
                        // The admission is resolved even if the viewer left.
                        guard foreground, !leases.isEmpty || explicitStop else { return }
                        let status = try await api.promptEngineerStatus(id: jobID)
                        guard accepts(id, epoch: epoch, cid: original.cid) else { return }
                        await publish(status, saved: saved, id: id, epoch: epoch)
                        guard accepts(id, epoch: epoch, cid: original.cid), phase?.isTerminal != true,
                              phase != .uncertain else { return }
                        failures = 0
                    } catch {
                        guard accepts(id, epoch: epoch, cid: original.cid) else { return }
                        failures += 1
                        problem = "network_unavailable"
                        if failures >= 4 { phase = .uncertain; return }
                    }
                    try await Task.sleep(for: pollDelay * (1 << min(failures, 3)))
                    guard accepts(id, epoch: epoch, cid: original.cid) else { return }
                }
            }
        } catch {
            guard accepts(id, epoch: epoch, cid: original.cid, permitCancelled: true) else { return }
            if fresh != nil, !attempted {
                let stopped = pointer?.stopRequested == true
                removePointer(original)
                pointer = nil
                phase = stopped ? .stopped : .failed
                problem = "session_unavailable"
                applicationSnapshot = nil
                return
            }
            phase = .uncertain
            problem = "session_unavailable"
        }
    }

    private func cancelOriginal(_ saved: PromptEngineerPointer, id: UUID, epoch: Int) async {
        guard let jobID = saved.jobID else { return }
        for attempt in 0..<3 {
            guard accepts(id, epoch: epoch, cid: saved.cid) else { return }
            // Completion is checked before Stop; a terminal authoritative
            // receipt wins over a late tap or a cancel HTTP 409.
            if let status = try? await api.promptEngineerStatus(id: jobID) {
                guard accepts(id, epoch: epoch, cid: saved.cid) else { return }
                await publish(status, saved: saved, id: id, epoch: epoch)
                guard accepts(id, epoch: epoch, cid: saved.cid) else { return }
                if phase?.isTerminal == true { return }
            }
            do {
                _ = try await api.stopPromptEngineer(id: jobID)
                guard accepts(id, epoch: epoch, cid: saved.cid) else { return }
            } catch {
                guard accepts(id, epoch: epoch, cid: saved.cid) else { return }
            }
            if let status = try? await api.promptEngineerStatus(id: jobID) {
                guard accepts(id, epoch: epoch, cid: saved.cid) else { return }
                await publish(status, saved: saved, id: id, epoch: epoch)
                guard accepts(id, epoch: epoch, cid: saved.cid) else { return }
                if phase?.isTerminal == true { return }
            }
            if attempt < 2 {
                do { try await Task.sleep(for: pollDelay * (attempt + 1)) } catch { return }
                guard accepts(id, epoch: epoch, cid: saved.cid) else { return }
            }
        }
        guard accepts(id, epoch: epoch, cid: saved.cid) else { return }
        phase = .stopping
        problem = "stop_unconfirmed"
    }

    private func publish(_ status: PromptEngineerStatus, saved: PromptEngineerPointer, id: UUID, epoch: Int) async {
        let previous = text
        // Terminal proof hashing and large-text checks have no UI dependencies.
        let outcome = await Task.detached(priority: .userInitiated) {
            PromptEngineerPolicy.outcome(status, pointer: saved, previous: previous)
        }.value
        guard accepts(id, epoch: epoch, cid: saved.cid) else { return }
        if text != outcome.text { text = outcome.text }
        phase = pointer?.stopRequested == true && !outcome.phase.isTerminal ? .stopping : outcome.phase
        problem = outcome.problem
        canForgetUnavailableReceipt = status.phase == "unknown"
        if outcome.phase == .completed, let applicationSnapshot {
            automaticallyApplied = chatStore.replaceDraft(with: text, matching: applicationSnapshot)
            self.applicationSnapshot = nil
        }
        if outcome.phase.isTerminal { applicationSnapshot = nil }
    }

    private func recordJobID(_ jobID: String) -> Bool {
        guard var saved = pointer else { return false }
        saved.jobID = jobID
        // Preserve the accepted identity in memory even when post-ack storage
        // fails; its earlier CID-only pointer still permits GET-only recovery.
        pointer = saved
        if !save(saved) { problem = "storage_unavailable" }
        return true
    }

    private func finishBeforeAdmission(_ saved: PromptEngineerPointer, id: UUID, epoch: Int) {
        guard accepts(id, epoch: epoch, cid: saved.cid) else { return }
        removePointer(saved)
        pointer = nil
        phase = .stopped
        problem = "stopped"
        applicationSnapshot = nil
    }

    private func accepts(_ id: UUID, epoch: Int, cid: String, permitCancelled: Bool = false) -> Bool {
        (permitCancelled || !Task.isCancelled) && workID == id && identityGeneration == epoch &&
        session.identityGeneration == epoch && !session.isWorking && ownerID == session.identityID &&
        pointer?.ownerID == ownerID && pointer?.cid == cid
    }

    private func pauseObservation() {
        // Never abort an initial dispatch merely because the view/app left.
        if dispatchingID == nil { retireWork() }
    }

    private func retireWork() {
        let old = work
        work = nil; workID = nil; dispatchingID = nil; isObserving = false
        old?.cancel()
    }

    private func definiteRejection(_ error: Error) -> Bool {
        guard let error = error as? APIError, case .httpStatus(let status, _) = error else { return false }
        return [400, 401, 403, 413, 422, 429].contains(status)
    }

    private func storageKey(_ owner: String) -> String {
        "firas.ios.prompt-engineer.v1." + String(PromptEngineerPolicy.jobID(ownerID: owner, cid: "pointer").prefix(10))
    }

    private func save(_ value: PromptEngineerPointer) -> Bool {
        guard let data = try? JSONEncoder().encode(value), data.count <= 4_096 else { return false }
        let key = storageKey(value.ownerID)
        defaults.set(data, forKey: key)
        return defaults.data(forKey: key) == data
    }

    private func removePointer(_ saved: PromptEngineerPointer) {
        let key = storageKey(saved.ownerID)
        guard let data = defaults.data(forKey: key),
              let current = try? JSONDecoder().decode(PromptEngineerPointer.self, from: data),
              current.cid == saved.cid else { return }
        defaults.removeObject(forKey: key)
    }
}

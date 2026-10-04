import Foundation

/// Transport only is synthetic. Tests compile both production stores and the
/// real immutable draft/replacement policy; no runtime, account or HTTP exists.
@MainActor final class SyntheticPromptEngineerAPI: PromptEngineerAPI {
    var holdCredentials = false
    var credentialFailure: APIError?
    var cookie = "synthetic-owner-one"
    var credentials: [CheckedContinuation<MediaCredentialSnapshot, Error>] = []
    var starts: [PromptEngineerJobRequest] = []
    var startWaiters: [CheckedContinuation<PromptEngineerStart, Error>] = []
    var receiptCalls: [String] = []
    var receiptWaiters: [CheckedContinuation<PromptEngineerReceipt, Error>] = []
    var statusCalls: [String] = []
    var statusWaiters: [CheckedContinuation<PromptEngineerStatus, Error>] = []
    var stopCalls: [String] = []
    var stopFailure: APIError?
    var holdStops = false
    var stopWaiters: [CheckedContinuation<Bool, Error>] = []
    var scopes: [String] = []

    @MainActor func mediaCredentialSnapshot() async throws -> MediaCredentialSnapshot {
        if let credentialFailure { throw credentialFailure }
        if holdCredentials { return try await withCheckedThrowingContinuation { credentials.append($0) } }
        return snapshot()
    }
    @MainActor func startPromptEngineer(_ request: PromptEngineerJobRequest) async throws -> PromptEngineerStart {
        recordScope(); starts.append(request)
        return try await withCheckedThrowingContinuation { startWaiters.append($0) }
    }
    @MainActor func promptEngineerReceipt(cid: String) async throws -> PromptEngineerReceipt {
        recordScope(); receiptCalls.append(cid)
        return try await withCheckedThrowingContinuation { receiptWaiters.append($0) }
    }
    @MainActor func promptEngineerStatus(id: String) async throws -> PromptEngineerStatus {
        recordScope(); statusCalls.append(id)
        return try await withCheckedThrowingContinuation { statusWaiters.append($0) }
    }
    @MainActor func stopPromptEngineer(id: String) async throws -> Bool {
        recordScope(); stopCalls.append(id)
        if let stopFailure { throw stopFailure }
        if holdStops { return try await withCheckedThrowingContinuation { stopWaiters.append($0) } }
        return true
    }
    func snapshot() -> MediaCredentialSnapshot {
        MediaCredentialSnapshot(origin: URL(string: "https://synthetic.invalid")!, cookieHeader: cookie)
    }
    func acknowledge(_ pointer: PromptEngineerPointer) {
        startWaiters.removeFirst().resume(returning: PromptEngineerStart(ok: true,
            jobId: PromptEngineerPolicy.jobID(ownerID: pointer.ownerID, cid: pointer.cid), phase: "queued"))
    }
    func receipt(_ pointer: PromptEngineerPointer, phase: String = "processing", chatID: String = "") {
        receiptWaiters.removeFirst().resume(returning: PromptEngineerReceipt(
            jobId: PromptEngineerPolicy.jobID(ownerID: pointer.ownerID, cid: pointer.cid),
            phase: phase, cid: pointer.cid, chatId: chatID))
    }
    func deliver(_ status: PromptEngineerStatus) { statusWaiters.removeFirst().resume(returning: status) }
    private func recordScope() {
        precondition(MediaCredentialScope.current != nil, "Every helper transport is credential scoped")
        scopes.append(MediaCredentialScope.current!.cookieHeader)
    }
}

@MainActor func promptFixture(defaults: UserDefaults? = nil) ->
    (SessionStore, FirasAPI, ChatStore, SyntheticPromptEngineerAPI, PromptEngineerStore, UserDefaults) {
    let session = SessionStore()
    let chatAPI = FirasAPI()
    let storage = defaults ?? UserDefaults(suiteName: "firas-prompt-test-" + UUID().uuidString)!
    let chat = ChatStore(session: session, api: chatAPI, defaults: storage)
    let api = SyntheticPromptEngineerAPI()
    let store = PromptEngineerStore(session: session, chatStore: chat, api: api,
        defaults: storage, pollDelay: .milliseconds(1))
    chat.updateDraftText("/prompteng Build a working Arabic study website", expectedOwnerID: session.identityID,
        expectedIdentityGeneration: session.identityGeneration)
    return (session, chatAPI, chat, api, store, storage)
}

nonisolated func helperStatus(_ pointer: PromptEngineerPointer, text: String, reasoning: String = "",
                              phase: String = "completed", status: Int = 0, notice: String = "",
                              proofOwner: String? = nil, digest: String? = nil) -> PromptEngineerStatus {
    let proof = PromptEngineerStatus.Surface.Proof(v: 1, id: pointer.jobID!, uid: proofOwner ?? pointer.ownerID,
        cid: pointer.cid, tier: "ultra", phase: phase, status: status, code: status == 499 ? "cancelled" : "",
        notice: notice, sha256: digest ?? PromptEngineerPolicy.digest(text, reasoning))
    return PromptEngineerStatus(phase: phase, text: text + (notice.isEmpty ? "" : (text.isEmpty ? "" : "\n\n") + "> " + notice),
        reasoning: reasoning, error: nil, status: status, surface: PromptEngineerStatus.Surface(chatReceipt: proof))
}

nonisolated func processingStatus(_ text: String = "") -> PromptEngineerStatus {
    PromptEngineerStatus(phase: "processing", text: text, reasoning: "", error: "", status: 0, surface: nil)
}

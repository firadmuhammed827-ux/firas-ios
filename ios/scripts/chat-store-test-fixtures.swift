import Foundation

// Only transport, session and device notifications are
// replaced here. The race tests compile the actual ChatStore and chat models.
nonisolated enum AppLanguage: String, Codable, Sendable { case arabic = "ar", english = "en" }
nonisolated struct Subscription: Codable, Equatable, Sendable {}
nonisolated struct MediaCredentialSnapshot: Equatable, Sendable {
    let origin: URL
    let cookieHeader: String
}
nonisolated enum MediaCredentialScope {
    @TaskLocal static var current: MediaCredentialSnapshot?
}
nonisolated enum APIError: Error, Equatable, LocalizedError, Sendable {
    case transport(code: Int, message: String)
    case httpStatus(Int, String?)
    case invalidURL, invalidRequest(String), invalidResponse, encoding, decoding
    case skillValidation([String])
    var errorDescription: String? { "Test transport failure" }

    var statusCode: Int? {
        if case .skillValidation = self { return 400 }
        guard case .httpStatus(let code, _) = self else { return nil }
        return code
    }
}

@MainActor final class SessionStore {
    var identityID: String? = "owner-one"
    var isAuthenticated = true
    var isGuest: Bool { !isAuthenticated && identityID != nil }
    var isWorking = false
    var identityGeneration = 0
}
@MainActor enum FirasCompletionCue {
    static func prepareForReveal(product: ProductKind, jobID: String) async -> Bool { true }
}
@MainActor final class NotificationCoordinator {
    enum Context { case durableJobStarted }
    enum Outcome { case completed, failed }
    static let shared = NotificationCoordinator()
    func requestAuthorizationIfNeeded(context: Context, preferredLanguageCode: String) async {}
    var delayFallback = false
    var pendingFallbacks: [CheckedContinuation<Void, Never>] = []
    func scheduleLocalFallbackIfNeeded(product: ProductKind, jobID: String, chatID: String?, outcome: Outcome) async {
        if delayFallback { await withCheckedContinuation { pendingFallbacks.append($0) } }
    }
}

@MainActor final class FirasAPI {
    var starts: [ChatJobRequest] = []
    var cancelledJobs: [String] = []
    var createCount = 0
    var classificationCount = 0
    var classificationResult = IntentDecision.unavailable
    var delayClassification = false
    var pendingClassifications: [CheckedContinuation<IntentDecision, Error>] = []
    var delayCreation = false
    var delayedChatIDs: Set<String> = []
    var chats: [String: ChatConversation] = [:]
    var chatRequests: [String] = []
    var pendingStarts: [CheckedContinuation<ChatJobStartResponse, Error>] = []
    var pendingCreations: [CheckedContinuation<CreateChatResponse, Error>] = []
    var pendingChats: [String: CheckedContinuation<ChatConversation, Error>] = [:]
    var updates: [(id: String, request: UpdateChatRequest)] = []
    var delayUpdates = false
    var updateFailure: APIError?
    var pendingUpdates: [CheckedContinuation<Void, Error>] = []
    var delayMediaCredentials = false
    var pendingMediaCredentials: [CheckedContinuation<MediaCredentialSnapshot, Error>] = []
    var listedChats: [ChatSummary] = []
    var delayList = false
    var pendingLists: [CheckedContinuation<[ChatSummary], Error>] = []
    var deletedChatIDs: [String] = []
    var delayDeletion = false
    var deleteFailure: APIError?
    var pendingDeletions: [String: CheckedContinuation<Void, Error>] = [:]
    var receiptRequests: [String] = []
    var receipts: [String: ChatJobReceipt] = [:]
    var delayReceipts = false
    var pendingReceipts: [CheckedContinuation<ChatJobReceipt, Error>] = []
    var statusRequests: [String] = []
    var statusResults: [ChatJobStatus] = []
    var delayStatuses = false
    var pendingStatuses: [CheckedContinuation<ChatJobStatus, Error>] = []
    var cancelFailure: APIError?
    var delayCancellation = false
    var pendingCancellations: [CheckedContinuation<CancelChatJobResponse, Error>] = []
    var operationScopes: [(route: String, cookie: String?)] = []

    func mediaCredentialSnapshot() async throws -> MediaCredentialSnapshot {
        if delayMediaCredentials {
            return try await withCheckedThrowingContinuation { pendingMediaCredentials.append($0) }
        }
        return MediaCredentialSnapshot(origin: URL(string: "https://firasai.org")!, cookieHeader: "test-owned-cookie")
    }

    func updateMediaChat(id: String, request: UpdateChatRequest) async throws {
        guard MediaCredentialScope.current != nil else { throw APIError.invalidRequest("media_session_required") }
        guard try JSONEncoder().encode(request).count <= 2_000_000 else {
            throw APIError.invalidRequest("media_history_too_large")
        }
        try await updateChat(id: id, request: request)
    }

    var historyReadScopes: [(route: String, cookie: String?)] = []
    func listChats() async throws -> [ChatSummary] {
        historyReadScopes.append(("list", MediaCredentialScope.current?.cookieHeader))
        if delayList { return try await withCheckedThrowingContinuation { pendingLists.append($0) } }
        return listedChats
    }
    func chat(id: String) async throws -> ChatConversation {
        historyReadScopes.append(("chat", MediaCredentialScope.current?.cookieHeader))
        chatRequests.append(id)
        if delayedChatIDs.contains(id) {
            return try await withCheckedThrowingContinuation { pendingChats[id] = $0 }
        }
        return chats[id] ?? ChatConversation(id: id, title: id, messages: [])
    }
    func createChat(_ request: CreateChatRequest) async throws -> CreateChatResponse {
        createCount += 1
        if delayCreation {
            return try await withCheckedThrowingContinuation { pendingCreations.append($0) }
        }
        return createdResponse(id: "created-\(createCount)")
    }
    func deleteChat(id: String) async throws {
        deletedChatIDs.append(id)
        if let deleteFailure { throw deleteFailure }
        if delayDeletion { try await withCheckedThrowingContinuation { pendingDeletions[id] = $0 } }
    }
    func updateChat(id: String, request: UpdateChatRequest) async throws {
        updates.append((id, request))
        if let updateFailure { throw updateFailure }
        if delayUpdates { try await withCheckedThrowingContinuation { pendingUpdates.append($0) } }
        let existing = chats[id] ?? ChatConversation(id: id, title: id, messages: [])
        chats[id] = ChatConversation(id: id, title: request.title ?? existing.title,
                                    messages: request.messages ?? existing.messages)
    }
    func chargeUsage(product: ProductKind, cid: String) async throws -> UsageChargeResponse {
        UsageChargeResponse(ok: true, sub: Subscription())
    }
    func classifyIntent(text: String, context: IntentContext) async throws -> IntentDecision {
        classificationCount += 1
        if delayClassification {
            return try await withCheckedThrowingContinuation { pendingClassifications.append($0) }
        }
        return classificationResult
    }
    func webSearch(query: String) async throws -> WebSearchResponse {
        WebSearchResponse(q: query, results: [], via: "test")
    }
    func startChatJob(_ request: ChatJobRequest) async throws -> ChatJobStartResponse {
        operationScopes.append(("start", MediaCredentialScope.current?.cookieHeader))
        starts.append(request)
        return try await withCheckedThrowingContinuation { pendingStarts.append($0) }
    }
    func cancelChatJob(id: String) async throws -> CancelChatJobResponse {
        operationScopes.append(("cancel", MediaCredentialScope.current?.cookieHeader))
        cancelledJobs.append(id)
        if let cancelFailure { throw cancelFailure }
        if delayCancellation { return try await withCheckedThrowingContinuation { pendingCancellations.append($0) } }
        return CancelChatJobResponse(ok: true, stopped: true)
    }
    func chatJobReceipt(cid: String) async throws -> ChatJobReceipt {
        guard MediaCredentialScope.current != nil else { throw APIError.invalidRequest("chat_session_required") }
        operationScopes.append(("receipt", MediaCredentialScope.current?.cookieHeader))
        receiptRequests.append(cid)
        if delayReceipts { return try await withCheckedThrowingContinuation { pendingReceipts.append($0) } }
        return receipts[cid] ?? ChatJobReceipt(jobId: "", phase: .unknown, cid: nil, chatId: nil)
    }
    func chatJobStatus(id: String) async throws -> ChatJobStatus {
        operationScopes.append(("status", MediaCredentialScope.current?.cookieHeader))
        statusRequests.append(id)
        if delayStatuses { return try await withCheckedThrowingContinuation { pendingStatuses.append($0) } }
        if !statusResults.isEmpty { return statusResults.removeFirst() }
        return ChatJobStatus(phase: .processing, text: nil, reasoning: nil, error: nil,
                             status: nil, surface: nil, progress: nil)
    }
    func resolveStart(jobID: String, phase: ChatJobPhase = .processing, text: String? = nil) {
        pendingStarts.removeFirst().resume(returning: ChatJobStartResponse(
            ok: true, jobId: jobID, phase: phase, text: text, reasoning: nil,
            surface: nil, progress: nil, error: nil, retryRequiresNewCid: nil
        ))
    }
    func resolveCreation(id: String) {
        pendingCreations.removeFirst().resume(returning: createdResponse(id: id))
    }
    func failStart(_ error: Error) {
        pendingStarts.removeFirst().resume(throwing: error)
    }
    func resolveClassification(_ result: IntentDecision) {
        pendingClassifications.removeFirst().resume(returning: result)
    }
    func resolveChat(id: String) {
        pendingChats.removeValue(forKey: id)?.resume(returning:
            chats[id] ?? ChatConversation(id: id, title: id, messages: []))
    }
    func resolveUpdate() { pendingUpdates.removeFirst().resume(returning: ()) }
    func resolveDeletion(id: String) { pendingDeletions.removeValue(forKey: id)?.resume(returning: ()) }
    func resolveList(_ chats: [ChatSummary]) { pendingLists.removeFirst().resume(returning: chats) }
    private func createdResponse(id: String) -> CreateChatResponse {
        CreateChatResponse(id: id, title: "New chat", createdAt: "test", updatedAt: "test")
    }
}

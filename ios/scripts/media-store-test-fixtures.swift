import Foundation

// Only session/notification/device and HTTP boundaries are replaced. The real
// MediaStudioStore, file repository and Models compile unchanged on macOS.
// Delayed continuations deliberately survive cancellation until tests resolve
// them, so post-await owner/epoch and task-lease checks are actually exercised.
nonisolated enum AppLanguage: String, Codable, Sendable {
    case arabic = "ar", english = "en"
}
nonisolated enum APIError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL, invalidRequest(String), transport(code: Int, message: String), invalidResponse
    case httpStatus(code: Int, message: String), skillValidation([String]), encoding(String), decoding(String)
    var errorDescription: String? { "operation_failed" }
}
nonisolated struct CancelChatJobResponse: Sendable {
    let ok: Bool
    let stopped: Bool
}
nonisolated struct MediaCredentialSnapshot: Equatable, Sendable {
    let origin: URL
    let cookieHeader: String
}
nonisolated enum MediaCredentialScope {
    @TaskLocal static var current: MediaCredentialSnapshot?
}
@MainActor final class SessionStore {
    var identityID: String? = "owner-a"
    var identityGeneration = 1
    var isAuthenticated = true
    var isWorking = false
    func transition(to ownerID: String?) {
        identityGeneration += 1
        identityID = ownerID
        isAuthenticated = ownerID != nil
    }
}
@MainActor final class FirasAPI {
    struct Start: Equatable {
        let kind: MediaStudioKind
        let prompt: String
        let lyrics: String?
        let sourceImage: String?
        let binding: MediaTurnBinding
        let tier: String
        let languageCode: String
    }
    var cookieHeader = "synthetic-owner-a"
    var holdSnapshot = false
    private(set) var snapshotCount = 0
    private(set) var starts: [Start] = []
    private(set) var receipts: [(MediaStudioKind, String)] = []
    private(set) var statuses: [(MediaStudioKind, String)] = []
    private(set) var assets: [(MediaStudioKind, String)] = []
    private(set) var stops: [String] = []
    private(set) var capturedScopes: [String] = []
    var pendingSnapshots: [CheckedContinuation<MediaCredentialSnapshot, Error>] = []
    var pendingStarts: [CheckedContinuation<MediaJobStartResponse, Error>] = []
    var pendingReceipts: [CheckedContinuation<MediaJobStatusResponse, Error>] = []
    var pendingStatuses: [CheckedContinuation<MediaJobStatusResponse, Error>] = []
    var pendingAssets: [CheckedContinuation<MediaAssetFileDownload, Error>] = []
    var pendingStops: [CheckedContinuation<CancelChatJobResponse, Error>] = []

    func mediaCredentialSnapshot() async throws -> MediaCredentialSnapshot {
        snapshotCount += 1
        if holdSnapshot { return try await withCheckedThrowingContinuation { pendingSnapshots.append($0) } }
        await Task.yield()
        return MediaCredentialSnapshot(origin: URL(string: "https://firasai.org")!, cookieHeader: cookieHeader)
    }
    private func checkScope() throws {
        guard let scope = MediaCredentialScope.current, scope.cookieHeader == cookieHeader else {
            throw CancellationError()
        }
        capturedScopes.append(scope.cookieHeader)
    }
    private func start(_ kind: MediaStudioKind, prompt: String, lyrics: String? = nil,
                       sourceImage: String? = nil, binding: MediaTurnBinding, tier: String,
                       languageCode: String) async throws -> MediaJobStartResponse {
        try checkScope()
        starts.append(Start(kind: kind, prompt: prompt, lyrics: lyrics, sourceImage: sourceImage,
            binding: binding, tier: tier, languageCode: languageCode))
        let response = try await withCheckedThrowingContinuation { pendingStarts.append($0) }
        try checkScope()
        return response
    }
    func startImageJob(prompt: String, preset: ImageAspectPreset, sourceImage: String? = nil,
                       binding: MediaTurnBinding, tier: String, languageCode: String) async throws -> MediaJobStartResponse {
        try await start(.image, prompt: prompt, sourceImage: sourceImage, binding: binding, tier: tier, languageCode: languageCode)
    }
    func startVideoJob(prompt: String, seconds: Int, sourceImage: String? = nil,
                       binding: MediaTurnBinding, tier: String, languageCode: String) async throws -> MediaJobStartResponse {
        try await start(.video, prompt: prompt, sourceImage: sourceImage, binding: binding, tier: tier, languageCode: languageCode)
    }
    func startMusicJob(prompt: String, lyrics: String, seconds: Int, binding: MediaTurnBinding,
                       tier: String, languageCode: String) async throws -> MediaJobStartResponse {
        try await start(.music, prompt: prompt, lyrics: lyrics, binding: binding, tier: tier, languageCode: languageCode)
    }
    func mediaJobReceipt(kind: MediaStudioKind, cid: String) async throws -> MediaJobStatusResponse {
        try checkScope(); receipts.append((kind, cid))
        let result = try await withCheckedThrowingContinuation { pendingReceipts.append($0) }
        try checkScope(); return result
    }
    func mediaJobStatus(kind: MediaStudioKind, id: String) async throws -> MediaJobStatusResponse {
        try checkScope(); statuses.append((kind, id))
        let result = try await withCheckedThrowingContinuation { pendingStatuses.append($0) }
        try checkScope(); return result
    }
    func cancelMediaJob(kind: MediaStudioKind, jobID: String) async throws -> CancelChatJobResponse {
        try checkScope()
        guard let controlID = MediaRequestPolicy.cancellationID(kind: kind, key: jobID) else { throw APIError.invalidResponse }
        stops.append(controlID)
        let result = try await withCheckedThrowingContinuation { pendingStops.append($0) }
        try checkScope(); return result
    }
    func mediaAssetFile(kind: MediaStudioKind, key: String) async throws -> MediaAssetFileDownload {
        try checkScope(); assets.append((kind, key))
        let result = try await withCheckedThrowingContinuation { pendingAssets.append($0) }
        // Return the staged file even for an uncooperative retired transfer;
        // Store must remove it before accepting any local result.
        return result
    }
    func drain() {
        pendingSnapshots.forEach { $0.resume(throwing: CancellationError()) }; pendingSnapshots = []
        pendingStarts.forEach { $0.resume(throwing: CancellationError()) }; pendingStarts = []
        pendingReceipts.forEach { $0.resume(throwing: CancellationError()) }; pendingReceipts = []
        pendingStatuses.forEach { $0.resume(throwing: CancellationError()) }; pendingStatuses = []
        pendingAssets.forEach { $0.resume(throwing: CancellationError()) }; pendingAssets = []
        pendingStops.forEach { $0.resume(throwing: CancellationError()) }; pendingStops = []
    }
}
@MainActor enum FirasCompletionCue {
    static func prepareForReveal(productID: String, jobID: String) async -> Bool { !Task.isCancelled }
}
@MainActor final class NotificationCoordinator {
    enum Context { case durableJobStarted }
    enum Outcome { case completed, failed }
    static let shared = NotificationCoordinator()
    func requestAuthorizationIfNeeded(context: Context, preferredLanguageCode: String) async -> Bool { false }
    func scheduleLocalFallbackIfNeeded(product: ProductKind, jobID: String, chatID: String?,
                                       mediaKind: MediaStudioKind?, outcome: Outcome) async {}
}

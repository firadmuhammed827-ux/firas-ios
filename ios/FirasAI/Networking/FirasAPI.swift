import Foundation

nonisolated struct FirasAPI: Sendable, PromptEngineerAPI {
    private let client: APIClient

    init(baseURL: URL) {
        client = APIClient(baseURL: baseURL)
    }

    @MainActor
    init(configuration: AppConfiguration = .live) {
        self.init(baseURL: configuration.apiBaseURL)
    }

    func login(email: String, password: String) async throws -> User {
        let envelope: UserEnvelope = try await client.request(
            .post,
            path: "/api/auth/login",
            body: LoginRequest(email: email, password: password)
        )
        return envelope.user
    }

    func signInWithFirebaseIDToken(_ idToken: String) async throws -> User {
        let token = idToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 20, token.count <= 8_192 else {
            throw APIError.invalidRequest("A valid Firebase ID token is required.")
        }

        let envelope: UserEnvelope = try await client.request(
            .post,
            path: "/api/auth/firebase",
            body: FirebaseIDTokenRequest(idToken: token)
        )
        return envelope.user
    }

    /// Exchanges an authorization code created by the configured iOS Google
    /// OAuth client. This deliberately does not call `/api/auth/firebase`:
    /// Google's ID token has a different issuer/audience and must first be
    /// exchanged for a Firebase ID token by Firebase Auth.
    func exchangeGoogleAuthorizationCode(
        _ code: String,
        codeVerifier: String
    ) async throws -> GoogleOAuthCodeExchangeResponse {
        let authorizationCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifier = codeVerifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authorizationCode.isEmpty, authorizationCode.count <= 8_192 else {
            throw APIError.invalidRequest("A Google authorization code is required.")
        }
        guard (43...128).contains(verifier.count),
              verifier.unicodeScalars.allSatisfy(Self.isPKCEVerifierScalar)
        else {
            throw APIError.invalidRequest("The PKCE code verifier is invalid.")
        }

        return try await client.request(
            .post,
            path: "/api/oauth/google/exchange",
            body: GoogleOAuthCodeExchangeRequest(
                code: authorizationCode,
                codeVerifier: verifier
            )
        )
    }

    func signInWithGoogleNative(
        _ authorization: GoogleNativeAuthorization
    ) async throws -> User {
        let code = authorization.code.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifier = authorization.codeVerifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonce = authorization.nonce.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (8...8_192).contains(code.count) else {
            throw APIError.invalidRequest("A Google authorization code is required.")
        }
        guard (43...128).contains(verifier.count),
              verifier.unicodeScalars.allSatisfy(Self.isPKCEVerifierScalar)
        else {
            throw APIError.invalidRequest("The PKCE code verifier is invalid.")
        }
        guard (16...256).contains(nonce.count),
              nonce.unicodeScalars.allSatisfy(Self.isBase64URLScalar)
        else {
            throw APIError.invalidRequest("The Google OpenID nonce is invalid.")
        }

        let envelope: UserEnvelope = try await client.request(
            .post,
            path: "/api/auth/google-native",
            body: GoogleNativeAuthRequest(
                authorization: GoogleNativeAuthorization(
                    code: code,
                    codeVerifier: verifier,
                    nonce: nonce
                )
            )
        )
        return envelope.user
    }

    func signup(name: String, email: String, password: String) async throws -> SignupResponse {
        try await client.request(
            .post,
            path: "/api/auth/signup",
            body: SignupRequest(name: name, email: email, password: password)
        )
    }

    func verifySignup(token: String) async throws -> User {
        let envelope: VerifiedUserEnvelope = try await client.request(
            .post,
            path: "/api/auth/verify-signup",
            body: VerifySignupRequest(token: token)
        )
        return envelope.user
    }

    func verificationStatus(pid: String) async throws -> VerificationStatusResponse {
        try await client.request(
            .post,
            path: "/api/auth/verify-status",
            body: VerificationStatusRequest(pid: pid)
        )
    }

    func me() async throws -> User {
        let envelope: UserEnvelope = try await client.request(.get, path: "/api/auth/me")
        return envelope.user
    }

    func changeEmail(currentPassword: String, newEmail: String) async throws -> User {
        let email = newEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (3...254).contains(email.count), email.contains("@") else {
            throw APIError.invalidRequest("A valid email address is required.")
        }
        guard currentPassword.count <= 200 else {
            throw APIError.invalidRequest("The current password is too long.")
        }

        let response: ChangeEmailResponse = try await client.request(
            .post,
            path: "/api/auth/change-email",
            body: ChangeEmailRequest(current: currentPassword, email: email)
        )
        return response.user
    }

    func changePassword(currentPassword: String, newPassword: String) async throws {
        guard currentPassword.count <= 200, (8...200).contains(newPassword.count) else {
            throw APIError.invalidRequest("Password must contain between 8 and 200 characters.")
        }

        let _: OperationResponse = try await client.request(
            .post,
            path: "/api/auth/change-password",
            body: ChangePasswordRequest(current: currentPassword, password: newPassword)
        )
    }

    func deleteAccount(currentPassword: String) async throws {
        guard currentPassword.count <= 200 else {
            throw APIError.invalidRequest("The current password is too long.")
        }

        let _: OperationResponse = try await client.request(
            .post,
            path: "/api/auth/delete-account",
            body: DeleteAccountRequest(current: currentPassword)
        )
    }

    func logout() async throws {
        let _: OperationResponse = try await client.request(.post, path: "/api/auth/logout")
    }

    func startGuestSession() async throws -> GuestSessionResponse {
        try await client.request(.post, path: "/api/guest")
    }

    func endGuestSession() async throws {
        let _: OperationResponse = try await client.request(.delete, path: "/api/guest")
    }

    func listChats() async throws -> [ChatSummary] {
        try await client.request(
            .get,
            path: "/api/chats",
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func accountSkills() async throws -> [AccountSkill] {
        let response: AccountSkillsResponse = try await client.request(
            .get, path: "/api/skills", cachePolicy: .reloadIgnoringLocalCacheData
        )
        return response.skills
    }

    func saveAccountSkill(_ request: AccountSkillRequest) async throws -> AccountSkill {
        guard request.validationProblems.isEmpty else {
            throw APIError.skillValidation(request.validationProblems)
        }
        if let id = request.id, !AccountSkillRequest.permitsID(id) {
            throw APIError.invalidRequest("The skill identifier is invalid.")
        }
        let response: AccountSkillResponse = try await client.request(
            // POST replaces full content, including edits to an existing id.
            // PATCH on the website changes only enabled/mode.
            .post, path: "/api/skills", body: request,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        return response.skill
    }

    func setAccountSkillEnabled(id: String, enabled: Bool) async throws -> AccountSkill {
        guard AccountSkillRequest.permitsID(id) else {
            throw APIError.invalidRequest("The skill identifier is invalid.")
        }
        let response: AccountSkillResponse = try await client.request(
            .patch, path: "/api/skills", body: AccountSkillToggleRequest(id: id, enabled: enabled),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        return response.skill
    }

    func deleteAccountSkill(id: String) async throws {
        guard AccountSkillRequest.permitsID(id) else {
            throw APIError.invalidRequest("The skill identifier is invalid.")
        }
        let _: AccountSkillDeleteResponse = try await client.request(
            .delete, path: "/api/skills", query: [URLQueryItem(name: "id", value: id)],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func chat(id: String) async throws -> ChatConversation {
        try requireIdentifier(id)
        return try await client.request(
            .get,
            path: "/api/chats/\(id)",
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func createChat(_ request: CreateChatRequest) async throws -> CreateChatResponse {
        try await client.request(.post, path: "/api/chats", body: request)
    }

    func updateChat(id: String, request: UpdateChatRequest) async throws {
        try requireIdentifier(id)
        let _: OperationResponse = try await client.request(
            .put,
            path: "/api/chats/\(id)",
            body: request
        )
    }

    func deleteChat(id: String) async throws {
        try requireIdentifier(id)
        let _: OperationResponse = try await client.request(.delete, path: "/api/chats/\(id)")
    }

    func updateMediaChat(id: String, request: UpdateChatRequest) async throws {
        guard MediaCredentialScope.current != nil else { throw APIError.invalidRequest("media_session_required") }
        try requireIdentifier(id)
        let _: OperationResponse = try await client.request(.put, path: "/api/chats/\(id)",
            body: request, cachePolicy: .reloadIgnoringLocalCacheData, maximumBodyBytes: 2_000_000)
    }

    func makeChatBackup() async throws -> FirasChatBackup {
        let summaries = try await listChats()
        var entries: [FirasChatBackupEntry] = []
        entries.reserveCapacity(summaries.count)

        // Match the website's resilient export: a single unavailable chat does
        // not make every other conversation impossible to save.
        for summary in summaries {
            let conversation = try? await chat(id: summary.id)
            let messages = conversation?.messages ?? []
            entries.append(FirasChatBackupEntry(summary: summary, messages: messages))
        }

        return FirasChatBackup(
            chats: entries,
            exportedAt: Date.now.formatted(.iso8601)
        )
    }

    func importChatBackup(_ backup: FirasChatBackup) async throws -> Int {
        let validated = try backup.validatedForImport()
        var importedCount = 0

        for entry in validated.chats {
            let request = CreateChatRequest(
                clientId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                title: entry.title,
                messages: entry.messages,
                pinned: entry.pinned == true,
                agent: entry.agent == true,
                codeProj: entry.codeProj == true,
                brainNb: entry.brainNb == true
            )
            _ = try await createChat(request)
            importedCount += 1
        }

        return importedCount
    }

    func startChatJob(_ request: ChatJobRequest) async throws -> ChatJobStartResponse {
        try await client.request(
            .post,
            path: "/api/chat/job",
            body: request,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func startPromptEngineer(_ request: PromptEngineerJobRequest) async throws -> PromptEngineerStart {
        guard MediaCredentialScope.current != nil, PromptEngineerPolicy.validCID(request.cid),
              request.messages.count == 2, request.messages[1].content.utf16.count <= PromptEngineerPolicy.sourceLimit,
              !request.messages[1].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.invalidRequest("prompt_engineer_invalid")
        }
        return try await client.request(.post, path: "/api/chat/job", body: request,
            cachePolicy: .reloadIgnoringLocalCacheData, maximumBodyBytes: 80_000,
            maximumResponseBytes: PromptEngineerPolicy.responseLimit)
    }

    func promptEngineerReceipt(cid: String) async throws -> PromptEngineerReceipt {
        guard MediaCredentialScope.current != nil, PromptEngineerPolicy.validCID(cid) else {
            throw APIError.invalidRequest("prompt_engineer_invalid")
        }
        return try await client.request(.get, path: "/api/chat/job",
            query: [URLQueryItem(name: "cid", value: cid)], cachePolicy: .reloadIgnoringLocalCacheData,
            maximumResponseBytes: PromptEngineerPolicy.responseLimit)
    }

    func promptEngineerStatus(id: String) async throws -> PromptEngineerStatus {
        guard MediaCredentialScope.current != nil else { throw APIError.invalidRequest("prompt_engineer_session_required") }
        try requireIdentifier(id)
        return try await client.request(.get, path: "/api/chat/job",
            query: [URLQueryItem(name: "id", value: id)], cachePolicy: .reloadIgnoringLocalCacheData,
            maximumResponseBytes: PromptEngineerPolicy.responseLimit)
    }

    func stopPromptEngineer(id: String) async throws -> Bool {
        guard MediaCredentialScope.current != nil else { throw APIError.invalidRequest("prompt_engineer_session_required") }
        let response = try await cancelChatJob(id: id)
        return response.ok && response.stopped
    }

    func classifyIntent(text: String, context: IntentContext) async throws -> IntentDecision {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 60_000 else { return .unavailable }
        let response: IntentDecision = try await client.request(.post, path: "/api/intent",
            body: IntentRequest(text: text, context: context), cachePolicy: .reloadIgnoringLocalCacheData)
        return response.isValidated ? response : .unavailable
    }

    func omnixAccess() async throws -> OmnixAccessRecord {
        try await client.request(.get, path: "/api/omnix/access", cachePolicy: .reloadIgnoringLocalCacheData)
    }

    func omnixCloudStatus() async throws -> OmnixCloudStatus {
        try await client.request(.get, path: "/api/omnix/cloud", cachePolicy: .reloadIgnoringLocalCacheData)
    }

    func submitOmnixCloud(_ request: OmnixCloudRunRequest) async throws -> OmnixCloudJob {
        guard request.isValid else { throw APIError.invalidRequest("The cloud request is invalid.") }
        return try await client.request(.post, path: "/api/omnix/runs", body: request, cachePolicy: .reloadIgnoringLocalCacheData)
    }

    func pollOmnixCloud(jobID: String) async throws -> OmnixCloudJob {
        guard OmnixCloudPolicy.jobID(jobID) else { throw APIError.invalidRequest("The job identifier is invalid.") }
        return try await client.request(.get, path: "/api/omnix/runs/\(jobID)", cachePolicy: .reloadIgnoringLocalCacheData)
    }

    func cancelOmnixCloud(jobID: String) async throws {
        guard OmnixCloudPolicy.jobID(jobID) else { throw APIError.invalidRequest("The job identifier is invalid.") }
        let _: OmnixCloudAcknowledgement = try await client.request(.post, path: "/api/omnix/runs/\(jobID)/cancel", body: OmnixCloudEmptyBody(), cachePolicy: .reloadIgnoringLocalCacheData)
    }

    func reconcileOmnixCloud(jobID: String) async throws -> OmnixCloudJob {
        guard OmnixCloudPolicy.jobID(jobID) else { throw APIError.invalidRequest("The job identifier is invalid.") }
        return try await client.request(.post, path: "/api/omnix/runs/\(jobID)/reconcile", body: OmnixCloudEmptyBody(), cachePolicy: .reloadIgnoringLocalCacheData)
    }

    func approveOmnixCloud(jobID: String, request: OmnixCloudApprovalRequest) async throws {
        guard OmnixCloudPolicy.jobID(jobID), request.isValid else { throw APIError.invalidRequest("The approval request is invalid.") }
        let _: OmnixCloudAcknowledgement = try await client.request(.post, path: "/api/omnix/runs/\(jobID)/approval", body: request, cachePolicy: .reloadIgnoringLocalCacheData)
    }

    func omnixCloudFiles() async throws -> OmnixCloudFiles {
        try await client.request(.get, path: "/api/omnix/files", cachePolicy: .reloadIgnoringLocalCacheData)
    }

    func downloadOmnixCloudFile(id: String) async throws -> ArtifactDownload {
        guard OmnixCloudPolicy.fileID(id) else { throw APIError.invalidRequest("The file identifier is invalid.") }
        let artifact = try await client.download(path: "/api/omnix/files/\(id)", query: [])
        guard artifact.data.count <= 25 * 1024 * 1024 else { throw APIError.invalidResponse }
        return artifact
    }

    func requestOmnixAccess(_ request: OmnixAccessRequest) async throws -> OmnixAccessRecord {
        guard request.isValid else { throw APIError.invalidRequest("Use 20–1200 characters for the access request.") }
        return try await client.request(.post, path: "/api/omnix/access", body: request, cachePolicy: .reloadIgnoringLocalCacheData)
    }

    func chatJobStatus(id: String) async throws -> ChatJobStatus {
        try requireIdentifier(id)
        return try await client.request(
            .get,
            path: "/api/chat/job",
            query: [URLQueryItem(name: "id", value: id)],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func chatJobReceipt(cid: String) async throws -> ChatJobReceipt {
        guard MediaCredentialScope.current != nil else {
            throw APIError.invalidRequest("chat_job_session_required")
        }
        guard (1...64).contains(cid.utf8.count), cid.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }) else { throw APIError.invalidRequest("chat_job_invalid_cid") }
        return try await client.request(.get, path: "/api/chat/job",
            query: [URLQueryItem(name: "cid", value: cid)], cachePolicy: .reloadIgnoringLocalCacheData,
            maximumResponseBytes: 128_000)
    }

    func cancelChatJob(id: String) async throws -> CancelChatJobResponse {
        try requireIdentifier(id)
        return try await client.request(
            .post,
            path: "/api/chat/cancel",
            body: CancelChatJobRequest(id: id),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func chargeUsage(product: ProductKind, cid: String) async throws -> UsageChargeResponse {
        guard product == .code else {
            throw APIError.invalidRequest("Usage charge accepts only the code product.")
        }
        return try await client.request(
            .post,
            path: "/api/usage/charge",
            body: UsageChargeRequest(product: product, cid: cid)
        )
    }

    func brainDocuments() async throws -> BrainLibraryResponse {
        try await client.request(
            .get,
            path: "/api/brain/docs",
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func uploadBrainDocument(_ request: BrainUploadRequest) async throws -> BrainUploadResponse {
        try await client.request(.post, path: "/api/brain/doc", body: request)
    }

    func deleteBrainDocument(id: String) async throws {
        try requireIdentifier(id)
        let _: OperationResponse = try await client.request(
            .delete,
            path: "/api/brain/doc",
            query: [URLQueryItem(name: "id", value: id)]
        )
    }

    func searchBrain(_ request: BrainSearchRequest) async throws -> BrainSearchResponse {
        try await client.request(.post, path: "/api/brain/search", body: request)
    }

    func brainPassage(documentID: String, chunkIndex: Int, window: Int = 2) async throws -> BrainPassage {
        try requireIdentifier(documentID)
        guard chunkIndex >= 0 else {
            throw APIError.invalidRequest("The passage index must be non-negative.")
        }
        return try await client.request(
            .get,
            path: "/api/brain/passage",
            query: [
                URLQueryItem(name: "doc", value: documentID),
                URLQueryItem(name: "i", value: String(chunkIndex)),
                URLQueryItem(name: "w", value: String(min(max(window, 0), 5))),
            ],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func webSearch(query: String) async throws -> WebSearchResponse {
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
        guard !trimmed.isEmpty else {
            throw APIError.invalidRequest("The search query is empty.")
        }
        return try await client.request(
            .get,
            path: "/api/search",
            query: [URLQueryItem(name: "q", value: trimmed)],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func startImageJob(
        prompt: String,
        preset: ImageAspectPreset,
        sourceImage: String? = nil,
        binding: MediaTurnBinding,
        tier: String,
        languageCode: String
    ) async throws -> MediaJobStartResponse {
        try requireMediaBinding(binding)
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = await Task.detached(priority: .userInitiated, operation: {
            MediaRequestPolicy.validationProblem(kind: .image, prompt: cleanPrompt, sourceImage: sourceImage)
        }).value {
            throw APIError.invalidRequest(problem)
        }
        return try await client.request(
            .post,
            path: "/api/image/job",
            body: MediaImageJobRequest(
                prompt: cleanPrompt, w: preset.width, h: preset.height,
                cid: binding.cid, chatId: binding.chatID, tier: tier, lang: languageCode, image: sourceImage
            ),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func startVideoJob(
        prompt: String,
        seconds: Int,
        sourceImage: String? = nil,
        binding: MediaTurnBinding,
        tier: String,
        languageCode: String
    ) async throws -> MediaJobStartResponse {
        try requireMediaBinding(binding)
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = await Task.detached(priority: .userInitiated, operation: {
            MediaRequestPolicy.validationProblem(kind: .video, prompt: cleanPrompt, seconds: seconds, sourceImage: sourceImage)
        }).value {
            throw APIError.invalidRequest(problem)
        }
        return try await client.request(
            .post,
            path: "/api/video/job",
            body: MediaVideoJobRequest(
                prompt: cleanPrompt,
                seconds: seconds,
                cid: binding.cid, chatId: binding.chatID, tier: tier, lang: languageCode, image: sourceImage
            ),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func startMusicJob(
        prompt: String,
        lyrics: String,
        seconds: Int,
        binding: MediaTurnBinding,
        tier: String,
        languageCode: String
    ) async throws -> MediaJobStartResponse {
        try requireMediaBinding(binding)
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLyrics = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = await Task.detached(priority: .userInitiated, operation: {
            MediaRequestPolicy.validationProblem(kind: .music, prompt: cleanPrompt, lyrics: cleanLyrics, seconds: seconds)
        }).value {
            throw APIError.invalidRequest(problem)
        }
        return try await client.request(
            .post,
            path: "/api/music/job",
            body: MediaMusicJobRequest(
                prompt: cleanPrompt,
                lyrics: cleanLyrics,
                seconds: seconds,
                cid: binding.cid, chatId: binding.chatID, tier: tier, lang: languageCode
            ),
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    func mediaJobStatus(
        kind: MediaStudioKind,
        id: String
    ) async throws -> MediaJobStatusResponse {
        guard MediaRequestPolicy.validKey(id), MediaCredentialScope.current != nil else {
            throw APIError.invalidRequest("media_receipt_invalid")
        }
        return try await client.request(
            .get,
            path: mediaJobPath(kind),
            query: [URLQueryItem(name: "id", value: id)],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    /// Reconnect after an uncertain POST using its original receipt identity.
    /// An unknown receipt is not permission to replay the creation request.
    func mediaJobReceipt(
        kind: MediaStudioKind,
        cid: String
    ) async throws -> MediaJobStatusResponse {
        guard MediaCredentialScope.current != nil, (1...64).contains(cid.utf8.count),
              cid.unicodeScalars.allSatisfy(Self.isBase64URLScalar)
        else { throw APIError.invalidRequest("The media receipt identifier is invalid.") }
        return try await client.request(
            .get,
            path: mediaJobPath(kind),
            query: [URLQueryItem(name: "cid", value: cid)],
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    private func requireMediaBinding(_ binding: MediaTurnBinding) throws {
        guard MediaCredentialScope.current != nil, !binding.ownerID.isEmpty,
              !binding.chatID.isEmpty, binding.chatID.utf16.count <= 128,
              binding.chatID.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
              (1...64).contains(binding.cid.utf8.count),
              binding.cid.unicodeScalars.allSatisfy(Self.isBase64URLScalar)
        else { throw APIError.invalidRequest("The media conversation binding is invalid.") }
    }

    func mediaCredentialSnapshot() async throws -> MediaCredentialSnapshot {
        try await client.mediaCredentialSnapshot()
    }

    func cancelMediaJob(kind: MediaStudioKind, jobID: String) async throws -> CancelChatJobResponse {
        guard MediaCredentialScope.current != nil,
              let id = MediaRequestPolicy.cancellationID(kind: kind, key: jobID) else {
            throw APIError.invalidRequest("media_stop_unavailable")
        }
        return try await cancelChatJob(id: id)
    }

    func mediaAssetFile(
        kind: MediaStudioKind,
        key: String
    ) async throws -> MediaAssetFileDownload {
        guard MediaRequestPolicy.validKey(key) else { throw APIError.invalidRequest("media_asset_invalid") }
        let path: String
        let queryName: String
        switch kind {
        case .image:
            path = "/api/image"
            queryName = "key"
        case .video:
            path = "/api/video/file"
            queryName = "id"
        case .music:
            path = "/api/music/file"
            queryName = "id"
        }
        return try await client.mediaFile(
            kind: kind, key: key, path: path,
            query: [URLQueryItem(name: queryName, value: key)]
        )
    }

    private func mediaJobPath(_ kind: MediaStudioKind) -> String {
        switch kind {
        case .image: "/api/image/job"
        case .video: "/api/video/job"
        case .music: "/api/music/job"
        }
    }

    private func requireIdentifier(_ value: String) throws {
        guard !value.isEmpty,
              value.count <= 160,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
              })
        else {
            throw APIError.invalidRequest("The resource identifier is invalid.")
        }
    }

    private static func isPKCEVerifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 46, 48...57, 65...90, 95, 97...122, 126:
            return true
        default:
            return false
        }
    }

    private static func isBase64URLScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 48...57, 65...90, 95, 97...122:
            return true
        default:
            return false
        }
    }
}

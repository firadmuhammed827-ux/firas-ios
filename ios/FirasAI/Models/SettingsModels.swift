import Foundation

nonisolated struct ChangeEmailRequest: Encodable, Equatable, Sendable {
    let current: String
    let email: String
}

nonisolated struct ChangeEmailResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let user: User
}

nonisolated struct ChangePasswordRequest: Encodable, Equatable, Sendable {
    let current: String
    let password: String
}

nonisolated struct DeleteAccountRequest: Encodable, Equatable, Sendable {
    let current: String
}

nonisolated enum ChatBackupValidationError: Error, Equatable, Sendable {
    case fileTooLarge
    case unsupportedFormat
    case noChats
    case tooManyChats
}

/// Compatible with the website's `{ app, format, exportedAt, chats }` backup.
/// Server identifiers are deliberately omitted: importing always creates new
/// conversations owned by the currently authenticated user.
nonisolated struct FirasChatBackup: Codable, Equatable, Sendable {
    static let currentFormat = 1
    static let maximumFileBytes = 50 * 1_024 * 1_024
    static let maximumChats = 500

    let app: String
    let format: Int
    let exportedAt: String?
    let chats: [FirasChatBackupEntry]

    init(chats: [FirasChatBackupEntry], exportedAt: String) {
        app = "Firas AI"
        format = Self.currentFormat
        self.exportedAt = exportedAt
        self.chats = chats
    }

    static func decodeValidated(from data: Data) throws -> FirasChatBackup {
        guard data.count <= maximumFileBytes else {
            throw ChatBackupValidationError.fileTooLarge
        }

        let decoded = try JSONDecoder().decode(FirasChatBackup.self, from: data)
        return try decoded.validatedForImport()
    }

    func validatedForImport() throws -> FirasChatBackup {
        guard app == "Firas AI", format == Self.currentFormat else {
            throw ChatBackupValidationError.unsupportedFormat
        }
        guard !chats.isEmpty else {
            throw ChatBackupValidationError.noChats
        }
        guard chats.count <= Self.maximumChats else {
            throw ChatBackupValidationError.tooManyChats
        }

        return FirasChatBackup(
            chats: chats.map(\.sanitizedForImport),
            exportedAt: exportedAt ?? Date.now.formatted(.iso8601)
        )
    }
}

nonisolated struct FirasChatBackupEntry: Codable, Equatable, Sendable {
    let title: String
    let pinned: Bool?
    let agent: Bool?
    let codeProj: Bool?
    let brainNb: Bool?
    let messages: [ChatMessage]

    init(summary: ChatSummary, messages: [ChatMessage]) {
        title = summary.title
        pinned = summary.pinned
        agent = summary.agent
        codeProj = summary.codeProj
        brainNb = summary.brainNb
        self.messages = messages
    }

    private init(
        title: String,
        pinned: Bool?,
        agent: Bool?,
        codeProj: Bool?,
        brainNb: Bool?,
        messages: [ChatMessage]
    ) {
        self.title = title
        self.pinned = pinned
        self.agent = agent
        self.codeProj = codeProj
        self.brainNb = brainNb
        self.messages = messages
    }

    fileprivate var sanitizedForImport: FirasChatBackupEntry {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedTitle = cleanTitle.isEmpty ? "Firas AI" : String(cleanTitle.prefix(120))

        return FirasChatBackupEntry(
            title: boundedTitle,
            pinned: pinned == true,
            agent: agent == true,
            codeProj: codeProj == true,
            brainNb: brainNb == true,
            messages: messages
                .lazy
                .filter { $0.role == .user || $0.role == .assistant }
                .prefix(2_000)
                .map(\.sanitizedForImport)
        )
    }
}

private extension ChatMessage {
    nonisolated var sanitizedForImport: ChatMessage {
        let safeAlternatives = (alts ?? [])
            .prefix(5)
            .map { alternative in
                AnswerVersion(
                    content: String(alternative.content.prefix(200_000)),
                    reasoning: alternative.reasoning.map { String($0.prefix(200_000)) },
                    tier: alternative.tier.map { String($0.prefix(20)) },
                    lang: alternative.lang.map { String($0.prefix(5)) },
                    generation: alternative.modelGeneration
                )
            }

        return ChatMessage(
            role: role,
            content: String(content.prefix(200_000)),
            tier: tier.map { String($0.prefix(20)) },
            generation: modelGeneration,
            lang: lang.map { String($0.prefix(5)) },
            files: files?.prefix(12).map {
                ChatAttachment(name: String($0.name.prefix(200)))
            },
            askAnswered: askAnswered == true ? true : nil,
            cid: cid.map { String($0.prefix(64)) },
            retryOf: retryOf.map {
                RetryReference(
                    cid: String($0.cid.prefix(64)),
                    tier: String($0.tier.prefix(20)),
                    generation: $0.modelGeneration
                )
            },
            retried: retried == true ? true : nil,
            mode: mode.map { String($0.prefix(20)) },
            mergedFrom: mergedFrom.map { String($0.prefix(120)) },
            reasoning: reasoning.map { String($0.prefix(200_000)) },
            images: nil,
            imageThumbs: imageThumbs?
                .lazy
                .filter { $0.count <= 300_000 }
                .prefix(6)
                .map { $0 },
            alts: safeAlternatives.count > 1 ? safeAlternatives : nil,
            altAt: safeAlternatives.count > 1
                ? min(max(altAt ?? safeAlternatives.count - 1, 0), safeAlternatives.count - 1)
                : nil,
            state: .delivered
        )
    }
}

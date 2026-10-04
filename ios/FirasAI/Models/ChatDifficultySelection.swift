import Foundation

/// A choice authorizes one exact editable draft, account epoch and navigation.
/// It contains no credential and is never written to disk.
nonisolated struct ChatDifficultyScope<Draft: Equatable & Sendable>: Equatable, Sendable {
    let ownerID: String
    let identityGeneration: Int
    let conversationID: String?
    let selectionGeneration: Int
    let draft: Draft
}

nonisolated struct ChatDifficultyRequest<Draft: Equatable & Sendable>: Identifiable, Equatable, Sendable {
    let id: UUID
    let scope: ChatDifficultyScope<Draft>
    let decision: DifficultyDecision
}

nonisolated struct ChatDifficultySubmission<Draft: Equatable & Sendable>: Equatable, Sendable {
    let id: UUID
    let scope: ChatDifficultyScope<Draft>
    let calibration: DifficultyCalibration
}

nonisolated enum ChatDifficultyAdmission<Draft: Equatable & Sendable>: Equatable, Sendable {
    case choose(ChatDifficultyRequest<Draft>)
    case ready(ChatDifficultySubmission<Draft>)
}

nonisolated struct ChatDifficultySelection<Draft: Equatable & Sendable>: Sendable {
    private var pending: ChatDifficultyRequest<Draft>?
    private var ready: ChatDifficultySubmission<Draft>?

    mutating func begin(scope: ChatDifficultyScope<Draft>, decision: DifficultyDecision,
                        asks: Bool) -> ChatDifficultyAdmission<Draft> {
        retire()
        let id = UUID()
        if asks {
            let request = ChatDifficultyRequest(id: id, scope: scope, decision: decision)
            pending = request
            return .choose(request)
        }
        let submission = ChatDifficultySubmission(id: id, scope: scope, calibration: decision.calibration)
        ready = submission
        return .ready(submission)
    }

    mutating func choose(_ request: ChatDifficultyRequest<Draft>, level: Int,
                         currentScope: ChatDifficultyScope<Draft>) -> ChatDifficultySubmission<Draft>? {
        guard pending == request, request.scope == currentScope, (1...7).contains(level) else { return nil }
        let previous = request.decision.calibration.level
        let calibration = DifficultyCalibration(level: level,
            previous: level == previous ? nil : previous,
            direction: level == previous ? 0 : (level > previous ? 1 : -1))
        let submission = ChatDifficultySubmission(id: request.id, scope: request.scope, calibration: calibration)
        pending = nil
        ready = submission
        return submission
    }

    mutating func consume(_ submission: ChatDifficultySubmission<Draft>,
                          currentScope: ChatDifficultyScope<Draft>) -> DifficultyCalibration? {
        guard ready == submission else { return nil }
        ready = nil
        guard submission.scope == currentScope else { return nil }
        return submission.calibration
    }

    mutating func cancel(requestID: UUID) {
        guard pending?.id == requestID else { return }
        pending = nil
    }

    func permits(_ submission: ChatDifficultySubmission<Draft>,
                 currentScope: ChatDifficultyScope<Draft>) -> Bool {
        ready == submission && submission.scope == currentScope
    }

    mutating func retire() {
        pending = nil
        ready = nil
    }
}

/// Only numeric conversation preselection is persisted. Drafts, instructions,
/// subject labels, one-use permits and account credentials stay in memory.
@MainActor
final class ChatDifficultyLevelRepository {
    private nonisolated struct Entry: Codable {
        let ownerID: String
        let conversationID: String
        let level: Int
    }

    private let defaults: UserDefaults
    private static let key = "firas.ios.chat-difficulty.v1"
    private var entries: [Entry]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = Array(decoded.filter {
            !$0.ownerID.isEmpty && !$0.conversationID.isEmpty && (1...7).contains($0.level)
        }.suffix(600))
    }

    func level(ownerID: String, conversationID: String?) -> Int {
        guard let conversationID else { return DifficultyPolicy.defaultLevel }
        return entries.last { $0.ownerID == ownerID && $0.conversationID == conversationID }?.level
            ?? DifficultyPolicy.defaultLevel
    }

    func set(_ level: Int, ownerID: String, conversationID: String) {
        guard (1...7).contains(level), !ownerID.isEmpty, !conversationID.isEmpty else { return }
        if entries.last(where: { $0.ownerID == ownerID && $0.conversationID == conversationID })?.level == level { return }
        entries.removeAll { $0.ownerID == ownerID && $0.conversationID == conversationID }
        entries.append(Entry(ownerID: ownerID, conversationID: conversationID, level: level))
        entries = Array(entries.suffix(600))
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}

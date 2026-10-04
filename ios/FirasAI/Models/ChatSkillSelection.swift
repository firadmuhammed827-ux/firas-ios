import Foundation

/// Editable input stays in memory across native navigation. Only the exact
/// accepted submission may consume unchanged portions of its draft snapshot.
nonisolated struct ChatDraftSnapshot<Context: Equatable & Sendable>: Equatable, Sendable {
    let ownerID: String
    let identityGeneration: Int
    let text: String
    let context: Context
    fileprivate let textRevision: Int
    fileprivate let contextRevision: Int
    fileprivate let submissionRevision: Int
}

nonisolated struct ChatDraftSelection<Context: Equatable & Sendable>: Equatable, Sendable {
    private(set) var ownerID: String?
    private(set) var identityGeneration = 0
    private(set) var text = ""
    private(set) var context: Context
    private let emptyContext: Context
    private var textRevision = 0
    private var contextRevision = 0
    private var submissionRevision = 0
    private var submission: Submission?

    private struct Submission: Equatable, Sendable {
        let cid: String
        let snapshot: ChatDraftSnapshot<Context>
    }

    init(emptyContext: Context) {
        self.emptyContext = emptyContext
        context = emptyContext
    }

    mutating func bind(ownerID: String?, identityGeneration: Int) {
        guard self.ownerID != ownerID || self.identityGeneration != identityGeneration else { return }
        if self.ownerID != ownerID {
            updateText("")
            updateContext(emptyContext)
        }
        self.ownerID = ownerID
        self.identityGeneration = identityGeneration
        submission = nil
        submissionRevision &+= 1
    }

    mutating func updateText(_ value: String) {
        guard text != value else { return }
        text = value
        textRevision &+= 1
    }

    mutating func updateContext(_ value: Context) {
        guard context != value else { return }
        context = value
        contextRevision &+= 1
    }

    func snapshot() -> ChatDraftSnapshot<Context>? {
        guard let ownerID else { return nil }
        return ChatDraftSnapshot(ownerID: ownerID, identityGeneration: identityGeneration,
            text: text, context: context, textRevision: textRevision, contextRevision: contextRevision,
            submissionRevision: submissionRevision)
    }

    /// Helper replacement checks the whole immutable draft, including edits
    /// made and reverted, newer context and navigation's submission retirement.
    mutating func replaceText(_ text: String, matching snapshot: ChatDraftSnapshot<Context>) -> Bool {
        guard self.snapshot() == snapshot else { return false }
        updateText(text)
        return true
    }

    mutating func beginSubmission(cid: String, snapshot: ChatDraftSnapshot<Context>) {
        guard !cid.isEmpty, ownerID == snapshot.ownerID,
              identityGeneration == snapshot.identityGeneration,
              submissionRevision == snapshot.submissionRevision else { return }
        submission = Submission(cid: cid, snapshot: snapshot)
    }

    /// Failure, Stop and navigation retire consumption, retaining editable input.
    mutating func retireSubmission(cid: String? = nil) {
        guard cid == nil || submission?.cid == cid else { return }
        submission = nil
        submissionRevision &+= 1
    }

    mutating func accept(_ receipt: ChatSendReceipt, currentOwnerID: String?, identityGeneration: Int) {
        guard let submission, receipt.cid == submission.cid,
              receipt.ownerID == submission.snapshot.ownerID, ownerID == currentOwnerID,
              receipt.ownerID == ownerID, self.identityGeneration == identityGeneration,
              submission.snapshot.identityGeneration == identityGeneration else { return }
        self.submission = nil
        if textRevision == submission.snapshot.textRevision, text == submission.snapshot.text {
            updateText("")
        }
        if contextRevision == submission.snapshot.contextRevision, context == submission.snapshot.context {
            updateContext(emptyContext)
        }
    }
}

/// Draft pins belong to one account and one accepted turn. A transport failure
/// leaves them selected; a receipt from another account or turn cannot clear them.
nonisolated struct ChatSkillSelection: Equatable, Sendable {
    static let maximumCount = 3
    private(set) var ownerID: String?
    private(set) var skills: [AccountSkill] = []
    private var submission: ChatSendReceipt?

    var ids: [String] { skills.map(\.id) }

    mutating func bind(ownerID: String?) {
        guard self.ownerID != ownerID else { return }
        self.ownerID = ownerID
        skills = []
        submission = nil
    }

    @discardableResult
    mutating func toggle(_ skill: AccountSkill, available: [AccountSkill], expectedOwnerID: String) -> Bool {
        guard ownerID == expectedOwnerID, skill.enabled,
              AccountSkillRequest.permitsID(skill.id), available.contains(skill) else { return false }
        if skills.contains(where: { $0.id == skill.id }) {
            skills.removeAll { $0.id == skill.id }
            return true
        }
        guard skills.count < Self.maximumCount else { return false }
        skills.append(skill)
        return true
    }

    mutating func remove(id: String, expectedOwnerID: String) {
        guard ownerID == expectedOwnerID else { return }
        skills.removeAll { $0.id == id }
    }

    /// Use only after a successful current-account refresh. An unavailable
    /// catalogue is not evidence that a previously selected skill was deleted.
    mutating func reconcile(available: [AccountSkill], expectedOwnerID: String) {
        guard ownerID == expectedOwnerID else { return }
        skills = skills.compactMap { selected in
            available.first { $0.id == selected.id && $0.enabled && AccountSkillRequest.permitsID($0.id) }
        }
    }

    mutating func beginSubmission(cid: String, ids: [String], expectedOwnerID: String) {
        guard ownerID == expectedOwnerID else { return }
        submission = ChatSendReceipt(ownerID: expectedOwnerID, cid: cid, skillIDs: ids)
    }

    mutating func accept(_ receipt: ChatSendReceipt) {
        guard receipt == submission, receipt.ownerID == ownerID else { return }
        let sent = Set(receipt.skillIDs)
        skills.removeAll { sent.contains($0.id) }
        submission = nil
    }
}

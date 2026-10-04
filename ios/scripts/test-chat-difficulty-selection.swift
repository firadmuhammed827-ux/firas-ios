import Foundation

@main
@MainActor enum ChatDifficultySelectionTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ description: String) {
            precondition(value(), description)
            checks += 1
        }
        struct Draft: Equatable, Sendable {
            var text = "Generate integral exercises"
            var revision = 0
            var context = ""
        }
        let draft = Draft()
        func scope(owner: String = "one", epoch: Int = 0, chat: String? = "chat-one",
                   navigation: Int = 0, draft suppliedDraft: Draft? = nil) -> ChatDifficultyScope<Draft> {
            ChatDifficultyScope(ownerID: owner, identityGeneration: epoch, conversationID: chat,
                selectionGeneration: navigation, draft: suppliedDraft ?? draft)
        }
        let original = scope()
        let decision = DifficultyDecision(calibration: DifficultyCalibration(), subject: "math", ask: true)
        var selection = ChatDifficultySelection<Draft>()
        guard case .choose(let request) = selection.begin(scope: original, decision: decision, asks: true) else {
            preconditionFailure("first generated problem set must ask")
        }
        expect(request.decision.calibration.level == 5, "new conversation defaults to level five")
        expect(selection.choose(request, level: 8, currentScope: original) == nil, "out-of-range choices cannot issue a permit")
        expect(selection.choose(request, level: 1, currentScope: scope(owner: "two")) == nil, "foreign owner cannot choose")
        expect(selection.choose(request, level: 1, currentScope: scope(epoch: 1)) == nil, "same-account new epoch cannot choose")
        expect(selection.choose(request, level: 1, currentScope: scope(chat: "chat-two")) == nil, "different conversation cannot choose")
        expect(selection.choose(request, level: 1, currentScope: scope(navigation: 1)) == nil, "navigation away and back cannot choose")
        var changed = draft
        changed.revision = 2
        expect(selection.choose(request, level: 1, currentScope: scope(draft: changed)) == nil, "edited and restored text still invalidates old revision")
        changed = draft
        changed.context = "new attachment"
        expect(selection.choose(request, level: 1, currentScope: scope(draft: changed)) == nil, "a new context cannot inherit an old choice")
        let submission = selection.choose(request, level: 7, currentScope: original)!
        expect(submission.calibration.level == 7 && submission.calibration.previous == 5 && submission.calibration.direction == 1,
               "a confirmed move captures the previous rung once")
        expect(selection.choose(request, level: 2, currentScope: original) == nil, "rapid second choice cannot replace the confirmed permit")
        selection.cancel(requestID: request.id)
        expect(selection.permits(submission, currentScope: original), "sheet dismissal after confirmation cannot cancel the ready permit")
        expect(selection.consume(submission, currentScope: original) == submission.calibration, "exact ready permit is consumed")
        expect(selection.consume(submission, currentScope: original) == nil, "a consumed choice cannot send twice")
        guard case .choose(let next) = selection.begin(scope: original, decision: decision, asks: true) else {
            preconditionFailure("each subsequent eligible send must ask")
        }
        expect(next.id != request.id, "remembered conversation level never bypasses a fresh chooser")
        selection.cancel(requestID: request.id)
        let nextSubmission = selection.choose(next, level: 5, currentScope: original)!
        expect(nextSubmission.calibration.previous == nil && nextSubmission.calibration.direction == 0,
               "Use current issues a real choice without a synthetic difficulty move")
        selection.retire()
        expect(selection.consume(nextSubmission, currentScope: original) == nil, "modal or navigation retirement prevents a queued send")
        guard case .choose(let cancelled) = selection.begin(scope: original, decision: decision, asks: true) else {
            preconditionFailure("cancel fixture")
        }
        selection.cancel(requestID: cancelled.id)
        expect(selection.choose(cancelled, level: 5, currentScope: original) == nil, "Cancel cannot later resume submission")
        guard case .ready(let attached) = selection.begin(scope: original, decision: decision, asks: false) else {
            preconditionFailure("attachment bypass fixture")
        }
        expect(attached.calibration.level == 5, "attachment bypass retains calibration without opening a chooser")
        expect(selection.consume(attached, currentScope: scope(epoch: 2)) == nil, "retired credential epoch cannot consume attachment bypass")
        expect(selection.consume(attached, currentScope: original) == nil, "a rejected mismatched permit is single-use too")

        let suite = "firas-difficulty-selection-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let levels = ChatDifficultyLevelRepository(defaults: defaults)
        expect(levels.level(ownerID: "one", conversationID: nil) == 5, "uncreated conversation has no stored record")
        levels.set(7, ownerID: "one", conversationID: "chat-one")
        expect(levels.level(ownerID: "one", conversationID: "chat-one") == 7, "stored level is only a conversation preselection")
        expect(levels.level(ownerID: "two", conversationID: "chat-one") == 5, "same chat identifier cannot leak another owner’s preselection")
        expect(levels.level(ownerID: "one", conversationID: "chat-two") == 5, "another conversation defaults independently")
        levels.set(0, ownerID: "one", conversationID: "chat-one")
        expect(levels.level(ownerID: "one", conversationID: "chat-one") == 7, "invalid persisted level cannot overwrite a real selection")
        let restored = ChatDifficultyLevelRepository(defaults: defaults)
        expect(restored.level(ownerID: "one", conversationID: "chat-one") == 7, "numeric preselection survives local recreation")
        let stored = String(data: defaults.data(forKey: "firas.ios.chat-difficulty.v1")!, encoding: .utf8)!
        expect(!stored.contains(draft.text) && !stored.contains("calibration") && !stored.contains("subject"),
               "local repository contains no editable text, calibration instructions or subject")
        for n in 0...600 { restored.set(2, ownerID: "one", conversationID: "bounded-\(n)") }
        expect(restored.level(ownerID: "one", conversationID: "chat-one") == 5,
               "the numeric local repository evicts old records at its bounded capacity")
        expect(restored.level(ownerID: "one", conversationID: "bounded-600") == 2,
               "the newest numeric record survives bounded eviction")
        print("PASS \(checks) difficulty selection and numeric repository checks")
    }
}

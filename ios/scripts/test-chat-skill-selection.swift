import Foundation

// Production selection state and JSONEncoder exercise the actual wire contract.
@main enum ChatSkillSelectionTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label)
            checks += 1
        }
        func skill(_ digit: String, enabled: Bool = true, name: String = "Skill") -> AccountSkill {
            AccountSkill(id: "usk-" + String(repeating: digit, count: 16), name: name,
                         cues: ["physics", "report", "Arabic"], rules: ["Preserve the full request."], mode: .auto, enabled: enabled)
        }
        let first = skill("1"), second = skill("2"), third = skill("3"), fourth = skill("4"), disabled = skill("5", enabled: false)
        let catalogue = [first, second, third, fourth, disabled]
        var selection = ChatSkillSelection()
        selection.bind(ownerID: "one")
        expect(!selection.toggle(first, available: catalogue, expectedOwnerID: "two"), "queued selection cannot cross owners even for identical catalogue IDs")
        expect(!selection.toggle(disabled, available: catalogue, expectedOwnerID: "one"), "disabled skill cannot be pinned")
        let unlisted = skill("6")
        expect(!selection.toggle(unlisted, available: catalogue, expectedOwnerID: "one"), "unlisted skill cannot be forged into the picker")
        let malformed = AccountSkill(id: "usk_bad", name: "Bad", cues: [], rules: [], mode: .auto, enabled: true)
        expect(!selection.toggle(malformed, available: [malformed], expectedOwnerID: "one"), "malformed IDs fail the shared account model validator")
        for item in [first, second, third] {
            expect(selection.toggle(item, available: catalogue, expectedOwnerID: "one"), "enabled current-account row can be selected")
        }
        expect(!selection.toggle(fourth, available: catalogue, expectedOwnerID: "one"), "native picker obeys the website's three-pin limit")
        expect(selection.ids == [first.id, second.id, third.id], "pins preserve user selection order")

        let request = ChatJobRequest(messages: [ChatMessage(role: .user, content: "اشرح المسألة")],
                                     tier: .pro, generation: .v11, thinking: false, cid: "turn-one", product: .ai,
                                     skillIDs: selection.ids)
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        expect(wire["skillIds"] as? [String] == selection.ids, "pins are carried by the real job JSON field skillIds")
        expect(wire["mgen"] as? String == "1.1", "pinning keeps the captured generation in the same job payload")
        let plain = ChatJobRequest(messages: [], tier: .pro, thinking: false, cid: "plain", product: .ai)
        let plainWire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! [String: Any]
        expect(plainWire["skillIds"] == nil, "ordinary unpinned and helper-compatible jobs omit the optional field")

        selection.beginSubmission(cid: "turn-one", ids: selection.ids, expectedOwnerID: "one")
        selection.accept(ChatSendReceipt(ownerID: "one", cid: "previous", skillIDs: selection.ids))
        expect(selection.skills.count == 3, "a previous turn's receipt does not consume this draft")
        selection.accept(ChatSendReceipt(ownerID: "two", cid: "turn-one", skillIDs: selection.ids))
        expect(selection.skills.count == 3, "a previous account's acceptance cannot consume pins")
        // Absence of a matching server receipt is exactly the enqueue-failure
        // state: retry still uses all three pins.
        expect(selection.ids == [first.id, second.id, third.id], "failed submission retains its complete selection")
        selection.accept(ChatSendReceipt(ownerID: "one", cid: "turn-one", skillIDs: selection.ids))
        expect(selection.skills.isEmpty, "accepted turn consumes only the sent selection")

        selection.toggle(first, available: catalogue, expectedOwnerID: "one")
        selection.beginSubmission(cid: "sent-first", ids: [first.id], expectedOwnerID: "one")
        selection.toggle(second, available: catalogue, expectedOwnerID: "one")
        selection.accept(ChatSendReceipt(ownerID: "one", cid: "sent-first", skillIDs: [first.id]))
        expect(selection.ids == [second.id], "acceptance does not erase a later selection")
        let renamed = skill("2", name: "Updated name")
        selection.reconcile(available: [renamed], expectedOwnerID: "one")
        expect(selection.skills.first?.name == "Updated name", "successful refresh updates selected labels")
        selection.reconcile(available: [skill("2", enabled: false)], expectedOwnerID: "one")
        expect(selection.skills.isEmpty, "a known disabled row is removed after a successful refresh")
        selection.toggle(first, available: catalogue, expectedOwnerID: "one")
        selection.beginSubmission(cid: "old-one", ids: [first.id], expectedOwnerID: "one")
        selection.bind(ownerID: "two")
        expect(selection.skills.isEmpty, "account switch immediately clears private pins")
        selection.toggle(first, available: catalogue, expectedOwnerID: "two")
        selection.accept(ChatSendReceipt(ownerID: "one", cid: "old-one", skillIDs: [first.id]))
        expect(selection.ids == [first.id], "late acceptance leaves the new account's identical skill untouched")
        selection.bind(ownerID: nil)
        expect(selection.skills.isEmpty, "guest transition clears account skills")

        let originalContext = ["image-one", "file-one"]
        func draft() -> ChatDraftSelection<[String]> {
            var value = ChatDraftSelection(emptyContext: [String]())
            value.bind(ownerID: "one", identityGeneration: 4)
            value.updateText("  Keep my exact draft\n")
            value.updateContext(originalContext)
            return value
        }
        let receipt = ChatSendReceipt(ownerID: "one", cid: "accepted", skillIDs: [])
        do {
            var value = draft()
            value.beginSubmission(cid: receipt.cid, snapshot: value.snapshot()!)
            expect(value.text == "  Keep my exact draft\n" && value.context == originalContext,
                   "local reservation retains exact editable whitespace and context without a server receipt")
            value.accept(ChatSendReceipt(ownerID: "one", cid: "unrelated", skillIDs: []), currentOwnerID: "one", identityGeneration: 4)
            value.accept(ChatSendReceipt(ownerID: "two", cid: receipt.cid, skillIDs: []), currentOwnerID: "one", identityGeneration: 4)
            value.accept(receipt, currentOwnerID: "one", identityGeneration: 5)
            expect(value.text == "  Keep my exact draft\n" && value.context == originalContext,
                   "unrelated cid, account and epoch receipts cannot consume editable input")
            value.accept(receipt, currentOwnerID: "one", identityGeneration: 4)
            expect(value.text.isEmpty && value.context.isEmpty, "matching accepted receipt consumes its unchanged snapshot")
        }
        do {
            var value = draft()
            value.beginSubmission(cid: receipt.cid, snapshot: value.snapshot()!)
            value.updateText("A newer editable request")
            value.accept(receipt, currentOwnerID: "one", identityGeneration: 4)
            expect(value.text == "A newer editable request" && value.context.isEmpty,
                   "accepted old text preserves newer edits while consuming unchanged sent context")
        }
        do {
            var value = draft()
            value.beginSubmission(cid: receipt.cid, snapshot: value.snapshot()!)
            value.updateContext(originalContext + ["later-photo"])
            value.accept(receipt, currentOwnerID: "one", identityGeneration: 4)
            expect(value.text.isEmpty && value.context == originalContext + ["later-photo"],
                   "a newly imported attachment survives acceptance of the previous context snapshot")
        }
        do {
            var value = draft()
            let snapshot = value.snapshot()!
            value.beginSubmission(cid: receipt.cid, snapshot: snapshot)
            value.updateText("Temporary edit")
            value.updateText(snapshot.text)
            value.updateContext([])
            value.updateContext(snapshot.context)
            value.accept(receipt, currentOwnerID: "one", identityGeneration: 4)
            expect(value.text == snapshot.text && value.context == snapshot.context,
                   "edit-away-and-back revisions cannot be mistaken for an untouched sent snapshot")
        }
        for reason in ["failure", "Stop", "navigation"] {
            var value = draft()
            value.beginSubmission(cid: receipt.cid, snapshot: value.snapshot()!)
            value.retireSubmission()
            value.accept(receipt, currentOwnerID: "one", identityGeneration: 4)
            expect(value.text == "  Keep my exact draft\n" && value.context == originalContext,
                   "\(reason) retires late consumption without erasing editable input")
        }
        do {
            var value = draft()
            let captured = value.snapshot()!
            value.retireSubmission()
            value.beginSubmission(cid: receipt.cid, snapshot: captured)
            value.accept(receipt, currentOwnerID: "one", identityGeneration: 4)
            expect(value.text == captured.text && value.context == captured.context,
                   "retirement before cid registration rejects the queued captured snapshot as well as an existing submission")
        }
        do {
            var value = draft()
            let old = value.snapshot()!
            value.beginSubmission(cid: receipt.cid, snapshot: old)
            value.bind(ownerID: "one", identityGeneration: 5)
            value.beginSubmission(cid: receipt.cid, snapshot: old)
            value.accept(receipt, currentOwnerID: "one", identityGeneration: 5)
            expect(value.text == old.text && value.context == old.context,
                   "same-account auth changes retain unsent input but reject queued old-epoch submission and receipt")
            value.bind(ownerID: "two", identityGeneration: 6)
            expect(value.text.isEmpty && value.context.isEmpty, "account switch removes the previous owner's private draft")
            value.updateText("New owner")
            value.updateContext(originalContext)
            value.accept(receipt, currentOwnerID: "two", identityGeneration: 6)
            expect(value.text == "New owner" && value.context == originalContext,
                   "late old-account acceptance cannot consume the new owner's identical attachment IDs")
            value.bind(ownerID: nil, identityGeneration: 7)
            expect(value.snapshot() == nil && value.text.isEmpty && value.context.isEmpty,
                   "absent identity exposes no private draft snapshot")
        }
        print("PASS: \(checks) production chat draft/skill-selection/wire checks")
    }
}

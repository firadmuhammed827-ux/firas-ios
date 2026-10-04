import Foundation

@main
struct AccountSkillChecks {
    static func main() throws {
        let cues = ["report", "research", "worksheet"]
        let rules = (1...4).map { "Instruction \($0): use clear headings and verify all citations." }
        let good = AccountSkillRequest(name: "Report style", cues: cues, rules: rules)
        precondition(good.validationProblems.isEmpty)
        precondition(AccountSkillRequest.permitsID("usk-0123456789abcdef"))
        for bad in ["usk_0123456789abcdef", "../files", "usk-0123456789abcdefx", "usk-0123456789abcdef\n"] {
            precondition(!AccountSkillRequest.permitsID(bad))
        }
        let emojiName = String(repeating: "😀", count: 41)
        precondition(AccountSkillRequest(name: emojiName, cues: cues, rules: rules)
            .validationProblems.contains("name_length"))
        precondition(AccountSkillRequest(name: "valid", cues: ["x"], rules: rules)
            .validationProblems.contains("cues_length"))
        precondition(AccountSkillRequest(name: "valid", cues: cues, rules: ["too short"])
            .validationProblems.contains("rules_length"))
        precondition(AccountSkillRequest(name: "valid", cues: cues,
            rules: Array(repeating: String(repeating: "a", count: 290), count: 10))
            .validationProblems.contains("rules_total"))
        let normalized = AccountSkillRequest(name: "  valid  ", cues: [" report ", "", "code", "study"], rules: rules)
        precondition(normalized.name == "valid" && normalized.cues == ["report", "code", "study"])
        let json = #"{"skills":[{"id":"usk-0123456789abcdef","name":"My rules","cues":["report","study","code"],"rules":[],"mode":"always","enabled":false,"createdAt":1}]}"#
        let decoded = try JSONDecoder().decode(AccountSkillsResponse.self, from: Data(json.utf8))
        precondition(decoded.skills.first?.enabled == false && decoded.skills.first?.mode == .always)
        let toggle = AccountSkillToggleRequest(id: decoded.skills[0].id, enabled: true)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(toggle)) as! [String: Any]
        precondition(encoded["id"] as? String == "usk-0123456789abcdef")
        precondition(encoded["enabled"] as? Bool == true)
        precondition(encoded.count == 2 && encoded["rules"] == nil)
        precondition(encoded["uid"] == nil && encoded["ownerID"] == nil)
        print("PASS: account skill wire format, UTF-16 limits, input validation and scoped toggle payload")
    }
}

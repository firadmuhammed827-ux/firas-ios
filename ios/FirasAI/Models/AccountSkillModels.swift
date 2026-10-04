import Foundation

nonisolated enum AccountSkillMode: String, Codable, CaseIterable, Sendable {
    case auto
    case always
}

nonisolated struct AccountSkill: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let cues: [String]
    let rules: [String]
    let mode: AccountSkillMode
    let enabled: Bool
}

nonisolated struct AccountSkillsResponse: Decodable, Sendable {
    let skills: [AccountSkill]
}

nonisolated struct AccountSkillResponse: Decodable, Sendable {
    let ok: Bool
    let skill: AccountSkill
}

nonisolated struct AccountSkillRequest: Encodable, Equatable, Sendable {
    let id: String?
    let name: String
    let cues: [String]
    let rules: [String]
    let mode: AccountSkillMode
    let enabled: Bool

    init(id: String? = nil, name: String, cues: [String], rules: [String],
         mode: AccountSkillMode = .auto, enabled: Bool = true) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cues = cues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.rules = rules.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.mode = mode
        self.enabled = enabled
    }

    init(skill: AccountSkill, enabled: Bool) {
        self.init(id: skill.id, name: skill.name, cues: skill.cues, rules: skill.rules,
                  mode: skill.mode, enabled: enabled)
    }

    // JS measures UTF-16; Swift's grapheme count gives different limits for emoji.
    // Content safety remains the server's authority; these checks are only feedback.
    var validationProblems: [String] {
        var problems: [String] = []
        if !(3...80).contains(name.utf16.count) { problems.append("name_length") }
        if !(3...24).contains(cues.count) || cues.contains(where: { !(2...60).contains($0.utf16.count) }) {
            problems.append("cues_length")
        }
        if !(4...24).contains(rules.count) || rules.contains(where: { !(28...300).contains($0.utf16.count) }) {
            problems.append("rules_length")
        }
        if rules.map({ "- " + $0 }).joined(separator: "\n").utf16.count > 2_600 {
            problems.append("rules_total")
        }
        return problems
    }

    static func permitsID(_ id: String) -> Bool {
        id.utf8.count == 20 && id.range(of: "^usk-[a-f0-9]{16}$", options: .regularExpression) != nil
    }
}

nonisolated struct AccountSkillDeleteResponse: Decodable, Sendable {
    let ok: Bool
}

nonisolated struct AccountSkillToggleRequest: Encodable, Sendable {
    let id: String
    let enabled: Bool
}

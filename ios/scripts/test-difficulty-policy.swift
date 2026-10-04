import Foundation
import CryptoKit

private nonisolated struct DifficultyFixture: Decodable {
    let version: Int
    let contractSHA256: String
    let defaultLevel: Int
    let levels: [DifficultyFixtureLevel]
    let cases: [DifficultyFixtureCase]
}
private nonisolated struct DifficultyFixtureLevel: Decodable {
    let level: Int
    let labels: [String: String]
    let hints: [String: String]
    let rule: String
    let ruleSHA256: String
}
private nonisolated struct DifficultyFixtureCase: Decodable {
    let id: String
    let text: String
    let currentLevel: Int
    let expected: DifficultyFixtureExpected
}
private nonisolated struct DifficultyFixtureExpected: Decodable {
    let calibration: DifficultyCalibration
    let subject: String?
    let ask: Bool
    let ruleSHA256: String
}

/// Executes the production policy; expected results came from actual shipping JavaScript.
/// The fixture path is an explicit runner input, never a production resource or network call.
@main
nonisolated struct DifficultyPolicyChecks {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Pass tools/fixtures/native-difficulty-contract.json as the sole argument")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixture = try JSONDecoder().decode(DifficultyFixture.self, from: data)
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            guard condition else { fatalError(message) }
        }
        func digest(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        expect(fixture.version == 1, "Supported actual-source fixture version")
        expect(fixture.contractSHA256 == DifficultyPolicy.sourceContractSHA256, "Pinned production source declarations")
        expect(fixture.defaultLevel == DifficultyPolicy.defaultLevel, "Shipping default is level five")
        expect(fixture.cases.count == 83, "All labelled shipping cases are present")
        expect(fixture.levels.count == 7, "All seven shipping rungs are present")

        for row in fixture.cases {
            let actual = DifficultyPolicy.decision(text: row.text, currentLevel: row.currentLevel)
            expect(actual.calibration == row.expected.calibration, "\(row.id): exact captured calibration")
            expect(actual.subject == row.expected.subject, "\(row.id): weighted subject eligibility")
            expect(actual.ask == row.expected.ask, "\(row.id): chooser decision")
            expect(digest(DifficultyPolicy.rule(actual.calibration)) == row.expected.ruleSHA256,
                   "\(row.id): complete calibration rule, including movement/clamp clauses")
        }
        for row in fixture.levels {
            let rule = DifficultyPolicy.rule(DifficultyCalibration(level: row.level))
            expect(rule == row.rule, "Level \(row.level): full shipping rule")
            expect(digest(rule) == row.ruleSHA256, "Level \(row.level): independent full-rule digest")
            for language in ["ar", "en"] {
                expect(DifficultyPolicy.label(level: row.level, language: language) == row.labels[language],
                       "Level \(row.level) \(language): full title")
                expect(DifficultyPolicy.hint(level: row.level, language: language) == row.hints[language],
                       "Level \(row.level) \(language): full hint")
            }
        }

        expect(DifficultyPolicy.decision(text: "Make it harderع", currentLevel: 3).calibration.level == 5,
               "JavaScript ASCII boundary permits Arabic adjacent to harder")
        expect(DifficultyPolicy.decision(text: "Make it ſimpler").calibration.level == 5,
               "Non-u JavaScript casefold does not treat long-s as s")
        expect(DifficultyPolicy.decision(text: "Make it SİMPLER").calibration.level == 5,
               "Non-u JavaScript casefold does not treat dotted-I as i")
        expect(DifficultyPolicy.decision(text: "Set level\u{FEFF}3").calibration.level == 3, "FEFF is JavaScript space")
        expect(DifficultyPolicy.decision(text: "Set level\u{202F}3").calibration.level == 3, "Narrow NBSP is JavaScript space")
        expect(DifficultyPolicy.decision(text: "Set level\u{0085}3").calibration.level == 5, "NEL is not JavaScript space")
        expect(DifficultyPolicy.decision(text: "raise\u{00A0}the\u{00A0}difficulty", currentLevel: 3).calibration.level == 5,
               "NBSP joins the actual relative instruction")
        expect(DifficultyPolicy.decision(text: "raise\u{0085}the\u{0085}difficulty", currentLevel: 3).calibration.level == 3,
               "NEL must not silently adopt ICU whitespace semantics")

        let captured = DifficultyCalibration(level: 99, previous: -5, direction: 1, magnitude: 3, clamp: "untrusted")
        expect(captured.level == 99 && captured.previous == -5, "Constructor preserves the captured immutable input")
        expect(DifficultyPolicy.decision(text: "", currentLevel: -99).calibration.level == 1, "Below-range state is bounded")
        expect(DifficultyPolicy.decision(text: "", currentLevel: 99).calibration.level == 7, "Above-range state is bounded")
        expect(DifficultyPolicy.label(level: -1, language: "ar") == DifficultyPolicy.label(level: 1, language: "ar"),
               "Title indexes cannot escape the actual ladder")
        expect(DifficultyPolicy.hint(level: 99, language: "en") == DifficultyPolicy.hint(level: 7, language: "en"),
               "Hint indexes cannot escape the actual ladder")
        let bounded = DifficultyCalibration(level: 7, previous: 1, direction: 1, magnitude: 3, clamp: "untrusted")
        expect(DifficultyPolicy.rule(captured) == DifficultyPolicy.rule(bounded), "Rule bounds state without rewriting it")
        expect(captured == DifficultyCalibration(level: 99, previous: -5, direction: 1, magnitude: 3, clamp: "untrusted"),
               "No parser or rule evaluation mutates the caller's snapshot")

        let transition = DifficultyPolicy.decision(text: "Make it much harder", currentLevel: 3).calibration
        let first = DifficultyPolicy.rule(transition)
        for _ in 0..<3 {
            expect(DifficultyPolicy.decision(text: "Make it much harder", currentLevel: 3).calibration == transition,
                   "Repeated decisions have no mutable conversation state")
            expect(DifficultyPolicy.rule(transition) == first, "A controller owns one-use admission; rule construction is pure")
            expect(DifficultyPolicy.decision(text: "Explain this").calibration.level == 5,
                   "Another conversation cannot inherit a prior transition")
        }
        expect(DifficultyPolicy.label(level: 5, language: "unsupported") == DifficultyPolicy.label(level: 5, language: "en"),
               "Unknown language uses the shipping English title")
        expect(DifficultyPolicy.hint(level: 5, language: "unsupported") == DifficultyPolicy.hint(level: 5, language: "en"),
               "Unknown language uses the shipping English hint")
        print("Difficulty policy: \(checks) checks passed across \(fixture.cases.count) actual-source cases and seven full rungs")
    }
}

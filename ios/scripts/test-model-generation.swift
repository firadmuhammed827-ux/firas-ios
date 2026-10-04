import Foundation

@main
struct ModelGenerationTests {
    static func main() throws {
        try expect(ModelGeneration.shippingDefault == .v11, "Website default must be 1.1")
        try expect(ModelGeneration.savedPreference(nil) == .v11, "Missing preference uses shipping default")
        try expect(ModelGeneration.savedPreference("") == .legacy, "Explicit legacy preference stays legacy")
        try expect(ModelGeneration.savedPreference("1.1") == .v11, "Saved 1.1 persists")
        try expect(ModelGeneration.savedPreference("future") == .v11, "Invalid preference follows website default")
        try expect(ModelGeneration.historyValue(nil) == .legacy, "Missing historical generation means 1")
        try expect(ModelGeneration.historyValue("future") == .legacy, "Unknown history never upgrades")
        try expect(ModelGeneration.historyValue("1.1\n") == .legacy, "Generation matching is exact")
        try expect(ModelGeneration(rawValue: "future") == nil, "Unknown enum cannot create a request")
        do {
            _ = try JSONDecoder().decode(ModelGeneration.self, from: Data(#""future""#.utf8))
            throw TestFailure(message: "Unknown typed generation must fail decoding")
        } catch is DecodingError {
            // Expected: typed durable request choices cannot accept unknown generations.
        }

        let names = ["luma", "nova", "titan", "atlas"]
        for (tier, name) in zip(ModelTier.allCases, names) {
            try expect(tier.label(generation: .legacy) == "\(name) 1", "Legacy tier label")
            try expect(tier.label(generation: .v11) == "\(name) 1.1", "Current tier label")
            for generation in ModelGeneration.allCases {
                let request = ChatJobRequest(
                    messages: [ChatMessage(role: .user, content: "hello")],
                    tier: tier,
                    generation: generation,
                    thinking: false,
                    cid: "generation-test",
                    product: .ai
                )
                let wire = try object(request)
                try expect(wire["tier"] as? String == tier.rawValue, "Tier wire name stays stable")
                if generation == .legacy {
                    try expect(wire["mgen"] == nil, "Legacy request omits mgen, never null or empty")
                } else {
                    try expect(wire["mgen"] as? String == "1.1", "1.1 request opts in explicitly")
                }
            }
        }

        let legacy = try JSONDecoder().decode(
            ChatMessage.self, from: Data(#"{"role":"assistant","content":"old","tier":"pro"}"#.utf8)
        )
        try expect(legacy.modelGeneration == .legacy, "Existing messages stay generation 1")
        try expect(try object(legacy)["mgen"] == nil, "Saving old history does not add mgen")
        let current = ChatMessage(role: .assistant, content: "new", tier: "pro", generation: .v11)
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(current))
        try expect(restored.modelGeneration == .v11, "1.1 history survives round trip")
        let unknown = try JSONDecoder().decode(
            ChatMessage.self, from: Data(#"{"role":"assistant","content":"unknown","mgen":"future"}"#.utf8)
        )
        try expect(unknown.modelGeneration == .legacy && unknown.mgen == nil, "Unknown history is not forwarded")
        let oldDefault = ChatJobRequest(messages: [], tier: .pro, thinking: false, cid: "old", product: .ai)
        try expect(try object(oldDefault)["mgen"] == nil, "Unchanged request call sites remain explicit legacy")

        let alternatives = [
            AnswerVersion(content: "old", reasoning: nil, tier: "pro", lang: "en"),
            AnswerVersion(content: "new", reasoning: nil, tier: "pro", lang: "en", generation: .v11),
        ]
        let message = ChatMessage(
            role: .assistant, content: "new", tier: "pro", generation: .v11,
            retryOf: RetryReference(cid: "original", tier: "pro", generation: .v11),
            alts: alternatives, altAt: 1
        )
        let backup = FirasChatBackup(chats: [
            FirasChatBackupEntry(
                summary: ChatSummary(id: "test", title: "Imported", updatedAt: "now", pinned: false,
                    agent: false, codeProj: false, brainNb: false),
                messages: [legacy, message]
            ),
        ], exportedAt: "now")
        let imported = try FirasChatBackup.decodeValidated(from: JSONEncoder().encode(backup))
        let importedMessages = imported.chats[0].messages
        try expect(importedMessages[0].modelGeneration == .legacy, "Import preserves legacy generation")
        try expect(importedMessages[1].modelGeneration == .v11, "Import preserves 1.1 generation")
        try expect(importedMessages[1].retryOf?.modelGeneration == .v11, "Import preserves retry provenance")
        try expect(importedMessages[1].alts?.map(\.modelGeneration) == [.legacy, .v11], "Import preserves each alternative")
        print("PASS: model generation preferences, exact labels, request omission, history and backup provenance")
    }

    private static func object<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let decoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        guard let object = decoded as? [String: Any] else { throw TestFailure(message: "Expected JSON object") }
        return object
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure(message: message) }
    }

    private struct TestFailure: Error { let message: String }
}

import CryptoKit
import Foundation

/// Independent helper wire: it deliberately has no Chat/history/skill fields.
nonisolated struct PromptEngineerJobRequest: Encodable, Equatable, Sendable {
    struct Message: Encodable, Equatable, Sendable { let role: String; let content: String }
    let cid: String
    let tier = "ultra"
    let think = false
    let nomem = true
    let promptEng = true
    let lang: String
    let messages: [Message]

    init(cid: String, source: String, languageCode: String) {
        self.cid = cid
        lang = languageCode == "en" ? "en" : "ar"
        messages = [Message(role: "system", content: PromptEngineerInstructions.system(languageCode: lang)),
                    Message(role: "user", content: source)]
    }
}

nonisolated struct PromptEngineerReceipt: Decodable, Equatable, Sendable {
    let jobId: String
    let phase: String
    let cid: String?
    let chatId: String?
}

nonisolated struct PromptEngineerStart: Decodable, Equatable, Sendable {
    let ok: Bool
    let jobId: String
    let phase: String
}

nonisolated struct PromptEngineerStatus: Decodable, Equatable, Sendable {
    struct Surface: Decodable, Equatable, Sendable {
        struct Proof: Decodable, Equatable, Sendable {
            let v: Int
            let id: String
            let uid: String
            let cid: String
            let tier: String
            let phase: String
            let status: Int
            let code: String
            let notice: String
            let sha256: String
        }
        let chatReceipt: Proof?
    }
    let phase: String
    let text: String?
    let reasoning: String?
    let error: String?
    let status: Int?
    let surface: Surface?
}

nonisolated struct PromptEngineerPointer: Codable, Equatable, Sendable {
    let ownerID: String
    let cid: String
    var jobID: String?
    let languageCode: String
    let startedAt: Date
    var stopRequested: Bool
}

nonisolated enum PromptEngineerPhase: String, Equatable, Sendable {
    case preparing, queued, processing, uncertain, stopping, completed, failed, stopped
    var isTerminal: Bool { self == .completed || self == .failed || self == .stopped }
}

nonisolated enum PromptEngineerPolicy {
    static let sourceLimit = 8_000
    static let outputLimit = 48_000
    static let responseLimit = 512_000

    /// Exact website token boundary: first /prompteng delimited by JS whitespace.
    static func matches(_ text: String) -> Bool {
        tokenRange(Array(text.unicodeScalars)) != nil
    }

    static func source(_ text: String) -> String? {
        var scalars = Array(text.unicodeScalars)
        guard let range = tokenRange(scalars) else { return nil }
        scalars.removeSubrange(range)
        var cleaned: [Unicode.Scalar] = []
        // JS replace(/[ \t]{2,}/g,' ') preserves a *single* tab. A run of
        // mixed whitespace becomes one space, handled without another grammar.
        var cursor = 0
        while cursor < scalars.count {
            if scalars[cursor].value == 32 || scalars[cursor].value == 9 {
                let start = cursor
                while cursor < scalars.count, scalars[cursor].value == 32 || scalars[cursor].value == 9 { cursor += 1 }
                if cursor - start > 1 {
                    cleaned.append(" ")
                } else { cleaned.append(scalars[start]) }
            } else { cleaned.append(scalars[cursor]); cursor += 1 }
        }
        var first = 0, last = cleaned.count
        while first < last, jsWhitespace(cleaned[first]) { first += 1 }
        while last > first, jsWhitespace(cleaned[last - 1]) { last -= 1 }
        let value = String(String.UnicodeScalarView(cleaned[first..<last]))
        guard !value.isEmpty, value.utf16.count <= sourceLimit else { return nil }
        return value
    }

    private static func tokenRange(_ value: [Unicode.Scalar]) -> Range<Int>? {
        let token = Array("/prompteng".unicodeScalars).map(\.value)
        guard value.count >= token.count else { return nil }
        for index in 0...(value.count - token.count) {
            guard index == 0 || jsWhitespace(value[index - 1]),
                  index + token.count == value.count || jsWhitespace(value[index + token.count]) else { continue }
            if token.indices.allSatisfy({ offset in
                let scalar = value[index + offset].value
                return (65...90).contains(scalar) ? scalar + 32 == token[offset] : scalar == token[offset]
            }) { return index..<(index + token.count) }
        }
        return nil
    }

    private static func jsWhitespace(_ value: Unicode.Scalar) -> Bool {
        switch value.value {
        case 9...13, 32, 160, 5760, 8192...8202, 8232, 8233, 8239, 8287, 12288, 65279: true
        default: false
        }
    }

    static func validCID(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...90).contains($0.value) ||
            (97...122).contains($0.value) || $0.value == 45 || $0.value == 95
        }
    }

    static func jobID(ownerID: String, cid: String) -> String {
        let prefix = Insecure.SHA1.hash(data: Data(ownerID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(10)
        return "\(prefix)-\(cid)"
    }

    static func acceptsReceipt(_ receipt: PromptEngineerReceipt, pointer: PromptEngineerPointer) -> Bool {
        receipt.cid == pointer.cid && (receipt.chatId ?? "").isEmpty &&
        receipt.jobId == jobID(ownerID: pointer.ownerID, cid: pointer.cid) &&
        ["queued", "processing", "completed", "done", "failed", "fail"].contains(receipt.phase)
    }

    struct Outcome: Equatable, Sendable {
        let phase: PromptEngineerPhase
        let text: String
        let problem: String?
    }

    static func outcome(_ value: PromptEngineerStatus, pointer: PromptEngineerPointer, previous: String) -> Outcome {
        let visible = value.text ?? ""
        let reasoning = value.reasoning ?? ""
        guard visible.utf16.count <= outputLimit + 4_000, reasoning.utf16.count <= outputLimit else {
            return Outcome(phase: .uncertain, text: previous, problem: "output_too_large")
        }
        if value.phase == "queued" || value.phase == "processing" {
            guard visible.utf16.count <= outputLimit else {
                return Outcome(phase: .uncertain, text: previous, problem: "output_too_large")
            }
            return Outcome(phase: value.phase == "queued" ? .queued : .processing,
                           text: visible.utf16.count >= previous.utf16.count ? visible : previous, problem: nil)
        }
        guard ["completed", "done", "failed", "fail"].contains(value.phase),
              let proof = value.surface?.chatReceipt,
              proof.v == 1, proof.id == pointer.jobID, proof.uid == pointer.ownerID,
              proof.cid == pointer.cid, proof.tier == "ultra", proof.notice.utf16.count <= 4_000,
              proof.phase == "completed" || proof.phase == "failed" else {
            return Outcome(phase: .uncertain, text: previous, problem: "receipt_unavailable")
        }
        var raw = visible
        if !proof.notice.isEmpty {
            let suffix = "\n\n> " + proof.notice
            if raw == "> " + proof.notice { raw = "" }
            else if raw.hasSuffix(suffix) { raw.removeLast(suffix.count) }
            else { return Outcome(phase: .uncertain, text: previous, problem: "receipt_invalid") }
        }
        // JavaScript JSON.stringify([text,reasoning]) is the server authority.
        guard raw.utf16.count <= outputLimit, digest(raw, reasoning) == proof.sha256,
              (proof.phase == "completed" ? proof.status == 0 && proof.notice.isEmpty : (400...599).contains(proof.status)),
              (proof.phase == "completed") == ["completed", "done"].contains(value.phase) else {
            return Outcome(phase: .uncertain, text: previous, problem: "receipt_invalid")
        }
        if proof.phase == "completed", !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Outcome(phase: .completed, text: raw, problem: nil)
        }
        return Outcome(phase: proof.status == 499 ? .stopped : .failed, text: raw,
                       problem: proof.status == 499 ? "stopped" : "generation_failed")
    }

    static func digest(_ text: String, _ reasoning: String) -> String {
        let data = Data(("[" + jsonString(text) + "," + jsonString(reasoning) + "]").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 0...31: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

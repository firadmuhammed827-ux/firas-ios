import Foundation

nonisolated struct CodeFile: Codable, Equatable, Identifiable, Sendable {
    let path: String
    let content: String

    var id: String { path }
}

nonisolated struct CodeProject: Codable, Equatable, Sendable {
    let name: String
    let files: [CodeFile]

    static func decode(fromJobText text: String) throws -> CodeProject {
        let marker = "```firas-project"
        guard let markerRange = text.range(of: marker) else {
            throw CodeProjectDecodingError.missingFence
        }

        let payloadStart = markerRange.upperBound
        let remaining = text[payloadStart...]
        // File contents are JSON strings and may themselves contain Markdown
        // fences. The protocol fence is the final line-level closing marker,
        // not the first three backticks in the payload.
        guard let closingRange = remaining.range(of: "\n```", options: .backwards),
              remaining[closingRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        else {
            throw CodeProjectDecodingError.missingFence
        }

        let payload = String(remaining[..<closingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = payload.data(using: .utf8) else {
            throw CodeProjectDecodingError.invalidUTF8
        }

        do {
            return try JSONDecoder().decode(CodeProject.self, from: data)
        } catch {
            throw CodeProjectDecodingError.invalidPayload
        }
    }
}

nonisolated enum CodeProjectDecodingError: Error, Equatable, Sendable {
    case missingFence
    case invalidUTF8
    case invalidPayload
}

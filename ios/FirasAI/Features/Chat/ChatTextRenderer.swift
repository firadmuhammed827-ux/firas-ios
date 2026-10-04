import Foundation

nonisolated struct ChatTextSegment: Identifiable, Sendable {
    // UTF-16 source offsets preserve each block's identity as the answer grows.
    let id: Int
    let kind: Kind

    nonisolated enum Kind: Sendable {
        case markdown(String, AttributedString?)
        case math(String, Bool)
    }
}

/// Parsing belongs to this actor, rather than a SwiftUI view initializer.
/// The bounded cache lets a row return to the viewport without parsing again.
actor ChatTextRenderer {
    static let shared = ChatTextRenderer()

    private let maximumCachedBytes = 1_000_000
    private let maximumEntries = 48
    private var cache: [String: [ChatTextSegment]] = [:]
    private var order: [String] = []
    private var cachedBytes = 0

    func render(_ text: String) throws -> [ChatTextSegment] {
        try Task.checkCancellation()
        if let existing = cache[text] { return existing }
        let segments = try ChatTextParser.segments(from: text)
        // Foundation parsing is synchronous; a retired task must not evict or populate the cache.
        try Task.checkCancellation()
        let cost = text.utf8.count
        guard cost <= maximumCachedBytes / 4 else { return segments }

        while !order.isEmpty,
              order.count >= maximumEntries || cachedBytes + cost > maximumCachedBytes {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
            cachedBytes -= oldest.utf8.count
        }
        cache[text] = segments
        order.append(text)
        cachedBytes += cost
        return segments
    }
}

nonisolated enum ChatTextParser {
    // This is the existing native scanner, moved unchanged and compiled once.
    // Keep recognition changes aligned with the website's scanMathSpans contract.
    private static let mathRegex = try? NSRegularExpression(
        pattern: #"(\$\$([\s\S]*?)\$\$|\$([^\n$]+)\$)"#
    )

    static func segments(from text: String) throws -> [ChatTextSegment] {
        try Task.checkCancellation()
        guard !text.isEmpty else {
            return [.init(id: 0, kind: .markdown(text, nil))]
        }

        var output: [ChatTextSegment] = []
        let source = text as NSString
        let matches = mathRegex?.matches(
            in: text,
            options: [.dotMatchesLineSeparators],
            range: NSRange(location: 0, length: source.length)
        ) ?? []
        var cursor = 0

        func appendMarkdown(_ range: NSRange) throws {
            try Task.checkCancellation()
            guard range.length > 0 else { return }
            let value = source.substring(with: range)
            output.append(.init(
                id: range.location,
                kind: .markdown(value, try? AttributedString(markdown: value))
            ))
        }

        for match in matches {
            try Task.checkCancellation()
            if match.range.location > cursor {
                try appendMarkdown(NSRange(
                    location: cursor,
                    length: match.range.location - cursor
                ))
            }
            let display = match.range(at: 2)
            let inline = match.range(at: 3)
            if display.location != NSNotFound, display.length > 0 {
                output.append(.init(id: match.range.location, kind: .math(
                    source.substring(with: display).trimmingCharacters(in: .whitespacesAndNewlines),
                    false
                )))
            } else if inline.location != NSNotFound, inline.length > 0 {
                output.append(.init(id: match.range.location, kind: .math(
                    source.substring(with: inline).trimmingCharacters(in: .whitespacesAndNewlines),
                    true
                )))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < source.length {
            try appendMarkdown(NSRange(location: cursor, length: source.length - cursor))
        }
        if output.isEmpty {
            try appendMarkdown(NSRange(location: 0, length: source.length))
        }
        return output
    }
}

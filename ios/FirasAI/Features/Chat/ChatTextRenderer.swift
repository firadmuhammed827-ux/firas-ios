import Foundation

nonisolated struct ChatTextSegment: Identifiable, Sendable {
    // UTF-16 source offsets preserve each block's identity as the answer grows.
    let id: Int
    let kind: Kind
    /// The block's dominant script, or the message's when the block has no
    /// letters: true for Arabic, false for Latin and other left-to-right
    /// scripts, nil (no letters anywhere, code, rules) to follow the reader.
    let rightToLeft: Bool?

    nonisolated enum Kind: Sendable {
        case paragraph([ChatTextPiece])
        /// Level 1 to 6.
        case heading(Int, [ChatTextPiece])
        /// Display marker ("1." or "•") and nesting depth. An empty marker is a
        /// later paragraph of the item above, aligned with that item's text.
        case listItem(String, Int, [ChatTextPiece])
        case quote([ChatTextPiece])
        /// Language and verbatim body of a fenced block.
        case code(String, String)
        case table([ChatTableRow])
        case rule
    }
}

/// Inline content of one block. Formulas stay separate pieces exactly as the
/// math scanner finds them; text is parsed inline only, whitespace preserved.
nonisolated struct ChatTextPiece: Identifiable, Sendable {
    let id: Int
    let kind: Kind

    nonisolated enum Kind: Sendable {
        case markdown(String, AttributedString)
        case math(String, Bool)
    }
}

nonisolated struct ChatTableRow: Identifiable, Sendable {
    let id: Int
    let cells: [AttributedString]
    let isHeader: Bool
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

/// Block structure is read here, line by line, because SwiftUI Text draws no
/// presentation intents: a full-syntax Markdown parse joins paragraphs, list
/// items and headings with no line break and drops every list number.
nonisolated enum ChatTextParser {
    // This is the existing native scanner, moved unchanged and compiled once.
    // Keep recognition changes aligned with the website's scanMathSpans contract.
    private static let mathRegex = try? NSRegularExpression(
        pattern: #"(\$\$([\s\S]*?)\$\$|\$([^\n$]+)\$)"#,
        options: [.dotMatchesLineSeparators]
    )

    fileprivate static let newline: UInt16 = 0x0A
    fileprivate static let carriageReturn: UInt16 = 0x0D
    fileprivate static let space: UInt16 = 0x20
    fileprivate static let tab: UInt16 = 0x09
    fileprivate static let hash: UInt16 = 0x23
    fileprivate static let dash: UInt16 = 0x2D
    fileprivate static let asterisk: UInt16 = 0x2A
    fileprivate static let plus: UInt16 = 0x2B
    fileprivate static let underscore: UInt16 = 0x5F
    fileprivate static let equals: UInt16 = 0x3D
    fileprivate static let greaterThan: UInt16 = 0x3E
    fileprivate static let pipe: UInt16 = 0x7C
    fileprivate static let colon: UInt16 = 0x3A
    fileprivate static let period: UInt16 = 0x2E
    fileprivate static let closingParenthesis: UInt16 = 0x29
    fileprivate static let backslash: UInt16 = 0x5C
    fileprivate static let backtick: UInt16 = 0x60
    fileprivate static let tilde: UInt16 = 0x7E
    fileprivate static let zero: UInt16 = 0x30

    static func segments(from text: String) throws -> [ChatTextSegment] {
        try Task.checkCancellation()
        guard !text.isEmpty else {
            return [.init(id: 0, kind: .paragraph([]), rightToLeft: nil)]
        }

        let source = text as NSString
        let units = Array(text.utf16)
        // Fenced blocks first, by line, as scanMathSpans does: code is never
        // scanned for formulas, and an unterminated fence runs to the end.
        let fences = fencedBlocks(units, source: source)
        var gaps: [NSRange] = []
        var cursor = 0
        for fence in fences {
            gaps.append(NSRange(location: cursor, length: fence.range.location - cursor))
            cursor = NSMaxRange(fence.range)
        }
        gaps.append(NSRange(location: cursor, length: units.count - cursor))

        var spans: [ChatMathSpan] = []
        for gap in gaps {
            spans += try mathSpans(in: text, source: source, range: gap)
        }

        var builder = ChatBlockBuilder(source: source, units: units, spans: spans)
        for (index, gap) in gaps.enumerated() {
            try builder.addLines(in: gap)
            if index < fences.count { builder.addCode(fences[index]) }
        }
        builder.close()
        guard !builder.output.isEmpty else {
            return [.init(id: 0, kind: .paragraph([]), rightToLeft: nil)]
        }

        // Each block is laid out in its own script's direction, as the website
        // sets dir on every block, so an English bullet in an Arabic answer
        // keeps its marker beside its first word. A block with no letters of
        // its own follows the message. Here this differs from the website,
        // whose autoDirOne falls back to the interface language: the parser
        // does not know it, so only a message with no letters at all
        // follows the reader.
        let direction = builder.letters.direction
        return builder.output.map { segment -> ChatTextSegment in
            switch segment.kind {
            case .code, .rule:
                return segment
            default:
                return ChatTextSegment(id: segment.id, kind: segment.kind, rightToLeft: segment.rightToLeft ?? direction)
            }
        }
    }

    static func inlineMarkdown(_ value: String) -> AttributedString {
        // Inline syntax only: block markers were read by the line scanner, and
        // whitespace, including single line breaks, must reach Text unchanged.
        (try? AttributedString(
            markdown: value,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(value)
    }

    private static func mathSpans(in text: String, source: NSString, range: NSRange) throws -> [ChatMathSpan] {
        try Task.checkCancellation()
        guard range.length > 0, let regex = mathRegex else { return [] }
        return regex.matches(in: text, options: [], range: range).compactMap { match -> ChatMathSpan? in
            let display = match.range(at: 2)
            let inline = match.range(at: 3)
            if display.location != NSNotFound, display.length > 0 {
                return ChatMathSpan(
                    range: match.range,
                    value: source.substring(with: display).trimmingCharacters(in: .whitespacesAndNewlines),
                    inline: false
                )
            }
            if inline.location != NSNotFound, inline.length > 0 {
                return ChatMathSpan(
                    range: match.range,
                    value: source.substring(with: inline).trimmingCharacters(in: .whitespacesAndNewlines),
                    inline: true
                )
            }
            return nil
        }
    }

    // Fences as the website's Markdown renderer reads them: three or more of
    // one fence character, and a backtick fence's info string has no
    // backtick, so ```a``` on one line stays inline code. A later run of the
    // same character, at least as long and with nothing after it, closes
    // it, so a nested "```python" is code. Unlike scanMathSpans, an opener
    // may sit at any indentation: under "10." or a nested bullet the item
    // indents it. A closer sits at most three columns deeper than its opener.
    private static func fencedBlocks(_ units: [UInt16], source: NSString) -> [ChatFence] {
        var fences: [ChatFence] = []
        var open: ChatOpenFence?
        var lineStart = 0
        while lineStart < units.count {
            var lineEnd = lineStart
            while lineEnd < units.count, units[lineEnd] != newline { lineEnd += 1 }
            let next = min(lineEnd + 1, units.count)
            var markerStart = lineStart
            while markerStart < lineEnd, isSpace(units[markerStart]) { markerStart += 1 }
            let marker = markerStart < lineEnd ? units[markerStart] : 0
            var markerEnd = markerStart
            if marker == backtick || marker == tilde {
                while markerEnd < lineEnd, units[markerEnd] == marker { markerEnd += 1 }
            }
            if markerEnd - markerStart >= 3 {
                var rest = markerEnd
                while rest < lineEnd, isSpace(units[rest]) || units[rest] == carriageReturn { rest += 1 }
                if let current = open {
                    if marker == current.marker, markerEnd - markerStart >= current.length,
                       rest == lineEnd, markerStart - lineStart <= current.indent + 3 {
                        fences.append(fence(current, bodyEnd: lineStart, end: next, terminated: true, source: source))
                        open = nil
                    }
                } else if marker == tilde
                            || !(markerEnd..<lineEnd).contains(where: { units[$0] == ChatTextParser.backtick }) {
                    open = ChatOpenFence(
                        start: lineStart,
                        marker: marker,
                        length: markerEnd - markerStart,
                        indent: markerStart - lineStart,
                        info: NSRange(location: markerEnd, length: lineEnd - markerEnd),
                        bodyStart: next
                    )
                }
            }
            lineStart = next
        }
        if let current = open {
            fences.append(fence(current, bodyEnd: units.count, end: units.count, terminated: false, source: source))
        }
        return fences
    }

    private static func fence(
        _ opening: ChatOpenFence, bodyEnd: Int, end: Int, terminated: Bool, source: NSString
    ) -> ChatFence {
        let info = source.substring(with: opening.info).trimmingCharacters(in: .whitespacesAndNewlines)
        let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let body = NSRange(location: opening.bodyStart, length: max(0, bodyEnd - opening.bodyStart))
        var lines = source.substring(with: body).components(separatedBy: "\n").map { raw -> String in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            return opening.indent > 0 ? ChatTextParser.dropIndent(line, opening.indent) : line
        }
        // While the closing fence is still streaming, its first marks are not code.
        if !terminated, let last = lines.last {
            let mark: Character = opening.marker == backtick ? "`" : "~"
            let marks = last.trimmingCharacters(in: .whitespaces)
            if !marks.isEmpty, marks.count < 3, marks.allSatisfy({ $0 == mark }) {
                lines.removeLast()
            }
        }
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return ChatFence(
            range: NSRange(location: opening.start, length: end - opening.start),
            indent: opening.indent,
            language: language,
            body: lines.joined(separator: "\n")
        )
    }

    private static func dropIndent(_ line: String, _ width: Int) -> String {
        var index = line.startIndex
        var dropped = 0
        // A tab is one unit of the opener's indent, so it is dropped as one.
        while dropped < width, index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
            dropped += 1
        }
        return String(line[index...])
    }

    fileprivate static func classify(_ line: NSRange, _ units: [UInt16], paragraphOpen: Bool, tableOpen: Bool) -> ChatLine {
        let start = line.location
        var end = NSMaxRange(line)
        while end > start, isSpace(units[end - 1]) || units[end - 1] == carriageReturn { end -= 1 }
        var first = start
        var indent = 0
        while first < end, isSpace(units[first]) {
            indent += units[first] == tab ? 4 - indent % 4 : 1
            first += 1
        }
        guard first < end else { return .blank }
        let mark = units[first]

        if indent <= 3 {
            if mark == hash {
                var level = 0
                while first + level < end, units[first + level] == hash { level += 1 }
                if level <= 6, first + level == end || isSpace(units[first + level]) {
                    return .heading(level, headingContent(first + level, end, units))
                }
            }
            // Three or more, so a streaming "-" or "= 5" never turns the
            // paragraph above it into a heading for one poll.
            if paragraphOpen, mark == equals || mark == dash, end - first >= 3,
               (first..<end).allSatisfy({ units[$0] == mark }) {
                return .underline(mark == equals ? 1 : 2)
            }
            if mark == dash || mark == asterisk || mark == underscore {
                var count = 0
                var onlyMarks = true
                for index in first..<end where !isSpace(units[index]) {
                    if units[index] == mark {
                        count += 1
                    } else {
                        onlyMarks = false
                        break
                    }
                }
                if onlyMarks, count >= 3 { return .rule }
            }
            if mark == greaterThan {
                var content = first
                while content < end, units[content] == greaterThan || isSpace(units[content]) { content += 1 }
                return .quote(NSRange(location: content, length: end - content))
            }
        }

        // An empty item cannot interrupt a paragraph (CommonMark), so a "-"
        // streaming under a line is not a bullet for one poll.
        if mark == dash || mark == asterisk || mark == plus, first + 1 == end || isSpace(units[first + 1]) {
            let content = contentRange(first + 1, end, units)
            if !paragraphOpen || content.length > 0 {
                return .item(indent, nil, "", content)
            }
        }
        if isDigit(mark) {
            var after = first
            var ordinal = 0
            while after < end, after - first < 9, isDigit(units[after]) {
                ordinal = ordinal * 10 + Int(units[after] - zero)
                after += 1
            }
            if after < end, units[after] == period || units[after] == closingParenthesis,
               after + 1 == end || isSpace(units[after + 1]) {
                let content = contentRange(after + 1, end, units)
                if !paragraphOpen || content.length > 0 {
                    return .item(indent, ordinal, units[after] == period ? "." : ")", content)
                }
            }
        }
        // Inside an open table a row needs only its opening bar, as in GFM,
        // so a streaming row joins the grid before its closing bar arrives.
        // Rows only gather here; close() builds a grid under a delimiter row.
        if mark == pipe, tableOpen || (end - first >= 2 && units[end - 1] == pipe) {
            return .tableRow
        }
        return .text(indent, NSRange(location: first, length: end - first))
    }

    private static func headingContent(_ from: Int, _ to: Int, _ units: [UInt16]) -> NSRange {
        var start = from
        while start < to, isSpace(units[start]) { start += 1 }
        var end = to
        var closing = end
        while closing > start, units[closing - 1] == hash { closing -= 1 }
        if closing < end, closing == start || isSpace(units[closing - 1]) {
            end = closing
            while end > start, isSpace(units[end - 1]) { end -= 1 }
        }
        return NSRange(location: start, length: end - start)
    }

    private static func contentRange(_ from: Int, _ end: Int, _ units: [UInt16]) -> NSRange {
        var start = from
        while start < end, isSpace(units[start]) { start += 1 }
        return NSRange(location: start, length: end - start)
    }

    fileprivate static func pieces(_ lines: [NSRange], source: NSString, spans: [ChatMathSpan]) -> [ChatTextPiece] {
        var result: [ChatTextPiece] = []
        var buffer = ""
        var bufferStart: Int?

        func flush() {
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start = bufferStart, !value.isEmpty {
                result.append(ChatTextPiece(id: start, kind: .markdown(value, ChatTextParser.inlineMarkdown(value))))
            }
            buffer = ""
            bufferStart = nil
        }

        func appendText(_ start: Int, _ end: Int) {
            guard end > start else { return }
            if bufferStart == nil { bufferStart = start }
            buffer += source.substring(with: NSRange(location: start, length: end - start))
        }

        for (index, line) in lines.enumerated() {
            if index > 0, bufferStart != nil { buffer += "\n" }
            let end = NSMaxRange(line)
            var cursor = line.location
            var spanIndex = firstSpan(spans, atOrAfter: cursor)
            while spanIndex < spans.count, spans[spanIndex].range.location < end {
                let span = spans[spanIndex]
                appendText(cursor, span.range.location)
                flush()
                result.append(ChatTextPiece(id: span.range.location, kind: .math(span.value, span.inline)))
                cursor = NSMaxRange(span.range)
                spanIndex += 1
            }
            appendText(cursor, end)
        }
        flush()
        return result
    }

    /// Text takes its base direction from its first strong letter. The mark
    /// makes it agree with the block's dominant script, so an Arabic sentence
    /// that opens with a Latin term still reads right to left.
    fileprivate static func marked(_ pieces: [ChatTextPiece], rightToLeft: Bool?) -> [ChatTextPiece] {
        guard let rightToLeft else { return pieces }
        let mark = AttributedString(rightToLeft ? "\u{200F}" : "\u{200E}")
        return pieces.map { piece -> ChatTextPiece in
            guard case .markdown(let value, let text) = piece.kind else { return piece }
            return ChatTextPiece(id: piece.id, kind: .markdown(value, mark + text))
        }
    }

    fileprivate static func cellRanges(_ line: NSRange, _ units: [UInt16], spans: [ChatMathSpan]) -> [NSRange] {
        var start = line.location
        var end = NSMaxRange(line)
        while start < end, isSpace(units[start]) { start += 1 }
        while end > start, isSpace(units[end - 1]) || units[end - 1] == carriageReturn { end -= 1 }
        if start < end, units[start] == pipe { start += 1 }
        if end > start, units[end - 1] == pipe { end -= 1 }

        var cells: [NSRange] = []
        var cellStart = start
        var index = start
        var spanIndex = firstSpan(spans, atOrAfter: start)
        while index < end {
            // A bar inside a formula, such as |x|, is not a column.
            if spanIndex < spans.count, spans[spanIndex].range.location <= index {
                index = max(index + 1, NSMaxRange(spans[spanIndex].range))
                spanIndex += 1
                continue
            }
            if units[index] == pipe {
                cells.append(trimmedRange(cellStart, index, units))
                cellStart = index + 1
            } else if units[index] == backslash {
                index += 1
            }
            index += 1
        }
        cells.append(trimmedRange(cellStart, max(cellStart, end), units))
        return cells
    }

    fileprivate static func isDelimiterRow(_ cells: [NSRange], _ units: [UInt16]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            let positions = cell.location..<NSMaxRange(cell)
            return positions.contains(where: { units[$0] == ChatTextParser.dash })
                && positions.allSatisfy({
                    units[$0] == ChatTextParser.dash || units[$0] == ChatTextParser.colon
                        || ChatTextParser.isSpace(units[$0])
                })
        }
    }

    /// A delimiter row still streaming in, such as "|" or "|:--": bars,
    /// dashes and colons only.
    fileprivate static func isPartialDelimiterRow(_ line: NSRange, _ units: [UInt16]) -> Bool {
        let content = lineContent(line, units)
        return content.length > 0 && (content.location..<NSMaxRange(content)).allSatisfy {
            units[$0] == ChatTextParser.pipe || units[$0] == ChatTextParser.dash
                || units[$0] == ChatTextParser.colon || ChatTextParser.isSpace(units[$0])
        }
    }

    /// A line without its indentation, trailing spaces or carriage return,
    /// as classify() hands over a text line.
    fileprivate static func lineContent(_ line: NSRange, _ units: [UInt16]) -> NSRange {
        var start = line.location
        var end = NSMaxRange(line)
        while end > start, isSpace(units[end - 1]) || units[end - 1] == carriageReturn { end -= 1 }
        while start < end, isSpace(units[start]) { start += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// A table cell is one line of Text, so a formula inside it is shown as
    /// code instead of being split into a row of its own.
    fileprivate static func cellText(_ range: NSRange, source: NSString, spans: [ChatMathSpan]) -> AttributedString {
        var text = AttributedString()
        var cursor = range.location
        let end = NSMaxRange(range)
        var spanIndex = firstSpan(spans, atOrAfter: cursor)
        while spanIndex < spans.count, spans[spanIndex].range.location < end {
            let span = spans[spanIndex]
            if span.range.location > cursor {
                text += inlineMarkdown(source.substring(with: NSRange(location: cursor, length: span.range.location - cursor)))
            }
            var formula = AttributedString(span.value)
            formula.inlinePresentationIntent = .code
            text += formula
            cursor = NSMaxRange(span.range)
            spanIndex += 1
        }
        if cursor < end {
            text += inlineMarkdown(source.substring(with: NSRange(location: cursor, length: end - cursor)))
        }
        return text
    }

    private static func trimmedRange(_ from: Int, _ to: Int, _ units: [UInt16]) -> NSRange {
        var start = from
        var end = to
        while start < end, isSpace(units[start]) { start += 1 }
        while end > start, isSpace(units[end - 1]) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    fileprivate static func firstSpan(_ spans: [ChatMathSpan], atOrAfter location: Int) -> Int {
        var low = 0
        var high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].range.location < location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    fileprivate static func isSpace(_ unit: UInt16) -> Bool {
        unit == space || unit == tab
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }
}

private nonisolated struct ChatMathSpan {
    let range: NSRange
    let value: String
    let inline: Bool
}

private nonisolated struct ChatOpenFence {
    let start: Int
    let marker: UInt16
    let length: Int
    let indent: Int
    let info: NSRange
    let bodyStart: Int
}

private nonisolated struct ChatFence {
    let range: NSRange
    let indent: Int
    let language: String
    let body: String
}

private nonisolated enum ChatLine {
    case blank
    case heading(Int, NSRange)
    /// A setext underline ("===" or "---") under an open paragraph.
    case underline(Int)
    case rule
    case quote(NSRange)
    /// Marker column, ordinal (nil for a bullet), delimiter and content.
    case item(Int, Int?, String, NSRange)
    case tableRow
    /// Indentation column and content.
    case text(Int, NSRange)
}

private nonisolated enum ChatOpenKind {
    case paragraph
    case item(String, Int)
    case quote
    case table

    var acceptsContinuation: Bool {
        if case .table = self { return false }
        return true
    }
}

private nonisolated struct ChatOpenBlock {
    let kind: ChatOpenKind
    let id: Int
    var lines: [NSRange]
}

private nonisolated struct ChatLetterCount {
    var rightToLeft = 0
    var other = 0

    /// Inline code is not counted, as the website's autoDirOne skips code and
    /// formula nodes: an identifier in an Arabic step does not make it
    /// English. Table formulas are tagged code, so they are skipped too.
    mutating func add(_ text: AttributedString) {
        for run in text.runs where run.inlinePresentationIntent?.contains(.code) != true {
            for scalar in text[run.range].unicodeScalars where scalar.properties.isAlphabetic {
                switch scalar.value {
                case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                    rightToLeft += 1
                default:
                    other += 1
                }
            }
        }
    }

    /// Dominant script, as the website's autoDirOne decides, not the first
    /// strong letter: right to left unless the other letters outnumber the
    /// right-to-left ones by more than one and a half times; nil when there
    /// are no letters at all. Every non-right-to-left letter counts, not
    /// only A to Z, so a Russian or Chinese answer stays left to right.
    var direction: Bool? {
        rightToLeft + other == 0 ? nil : !(Double(other) > Double(rightToLeft) * 1.5)
    }
}

private nonisolated struct ChatBlockBuilder {
    let source: NSString
    let units: [UInt16]
    let spans: [ChatMathSpan]
    var output: [ChatTextSegment] = []
    var letters = ChatLetterCount()
    var open: ChatOpenBlock?
    // Marker columns and next ordinals of the list levels still open.
    var listIndents: [Int] = []
    var listOrdinals: [Int] = []
    // After a blank line or a fenced block an indented line resumes a list item.
    var afterBreak = true

    init(source: NSString, units: [UInt16], spans: [ChatMathSpan]) {
        self.source = source
        self.units = units
        self.spans = spans
    }

    mutating func addLines(in range: NSRange) throws {
        let end = NSMaxRange(range)
        var lineStart = range.location
        var index = range.location
        var spanIndex = ChatTextParser.firstSpan(spans, atOrAfter: range.location)
        while index < end {
            if spanIndex < spans.count, spans[spanIndex].range.location == index {
                // A formula's own line breaks belong to the formula.
                index = NSMaxRange(spans[spanIndex].range)
                spanIndex += 1
            } else {
                if units[index] == ChatTextParser.newline {
                    try addLine(NSRange(location: lineStart, length: index - lineStart))
                    lineStart = index + 1
                }
                index += 1
            }
        }
        if lineStart < end {
            try addLine(NSRange(location: lineStart, length: end - lineStart))
        }
    }

    mutating func addCode(_ fence: ChatFence) {
        close()
        if fence.indent == 0 { resetList() }
        output.append(ChatTextSegment(id: fence.range.location, kind: .code(fence.language, fence.body), rightToLeft: nil))
        afterBreak = true
    }

    mutating func close() {
        guard let block = open else { return }
        open = nil
        switch block.kind {
        case .paragraph:
            emit(id: block.id, lines: block.lines) { .paragraph($0) }
        case .quote:
            emit(id: block.id, lines: block.lines) { .quote($0) }
        case .item(let marker, let depth):
            emit(id: block.id, lines: block.lines, keepsEmpty: true) { .listItem(marker, depth, $0) }
        case .table:
            if hasDelimiterRow(block) {
                let segment = table(block)
                output.append(segment)
            } else {
                // Bars with no delimiter row under them are text, as GFM reads
                // them: |x - 3| = |2x + 1| is absolute values, not three columns.
                let lines = block.lines.map { ChatTextParser.lineContent($0, units) }
                emit(id: block.id, lines: lines) { .paragraph($0) }
            }
        }
    }

    /// GFM builds a table only when the second line is a delimiter row. The
    /// input's last line may be that row still arriving, so a streaming table
    /// does not fall back to text between polls.
    private func hasDelimiterRow(_ block: ChatOpenBlock) -> Bool {
        guard block.lines.count >= 2 else { return false }
        let second = block.lines[1]
        if ChatTextParser.isDelimiterRow(ChatTextParser.cellRanges(second, units, spans: spans), units) {
            return true
        }
        return NSMaxRange(second) == units.count && ChatTextParser.isPartialDelimiterRow(second, units)
    }

    private mutating func addLine(_ line: NSRange) throws {
        try Task.checkCancellation()
        var paragraphOpen = false
        var tableOpen = false
        if case .paragraph? = open?.kind { paragraphOpen = true }
        if case .table? = open?.kind { tableOpen = true }

        switch ChatTextParser.classify(line, units, paragraphOpen: paragraphOpen, tableOpen: tableOpen) {
        case .blank:
            close()
            afterBreak = true
            return
        case .heading(let level, let content):
            close()
            resetList()
            emit(id: line.location, lines: [content]) { .heading(level, $0) }
        case .underline(let level):
            if let block = open {
                open = nil
                emit(id: block.id, lines: block.lines) { .heading(level, $0) }
            }
        case .rule:
            close()
            resetList()
            output.append(ChatTextSegment(id: line.location, kind: .rule, rightToLeft: nil))
        case .quote(let content):
            if case .quote? = open?.kind {
                open?.lines.append(content)
            } else {
                close()
                resetList()
                open = ChatOpenBlock(kind: .quote, id: line.location, lines: [content])
            }
        case .item(let indent, let ordinal, let delimiter, let content):
            close()
            let (marker, depth) = listMarker(indent: indent, ordinal: ordinal, delimiter: delimiter)
            open = ChatOpenBlock(kind: .item(marker, depth), id: line.location, lines: [content])
        case .tableRow:
            if case .table? = open?.kind {
                open?.lines.append(line)
            } else {
                close()
                resetList()
                open = ChatOpenBlock(kind: .table, id: line.location, lines: [line])
            }
        case .text(let indent, let content):
            if let kind = open?.kind, kind.acceptsContinuation {
                open?.lines.append(content)
            } else {
                close()
                if afterBreak, let depth = continuationDepth(indent) {
                    open = ChatOpenBlock(kind: .item("", depth), id: line.location, lines: [content])
                } else {
                    resetList()
                    open = ChatOpenBlock(kind: .paragraph, id: line.location, lines: [content])
                }
            }
        }
        afterBreak = false
    }

    private mutating func emit(
        id: Int,
        lines: [NSRange],
        keepsEmpty: Bool = false,
        _ kind: ([ChatTextPiece]) -> ChatTextSegment.Kind
    ) {
        let pieces = ChatTextParser.pieces(lines, source: source, spans: spans)
        guard keepsEmpty || !pieces.isEmpty else { return }
        var own = ChatLetterCount()
        for piece in pieces {
            if case .markdown(_, let text) = piece.kind { own.add(text) }
        }
        letters.rightToLeft += own.rightToLeft
        letters.other += own.other
        output.append(ChatTextSegment(
            id: id,
            kind: kind(ChatTextParser.marked(pieces, rightToLeft: own.direction)),
            rightToLeft: own.direction
        ))
    }

    private mutating func listMarker(indent: Int, ordinal: Int?, delimiter: String) -> (String, Int) {
        while let last = listIndents.last, last > indent {
            listIndents.removeLast()
            listOrdinals.removeLast()
        }
        if listIndents.last != indent {
            listIndents.append(indent)
            listOrdinals.append(0)
        }
        let depth = listIndents.count - 1
        guard let ordinal else {
            listOrdinals[depth] = 0
            return (depth % 2 == 0 ? "•" : "◦", depth)
        }
        // "1. 1. 1." counts on, as the website's ordered list does.
        let shown = listOrdinals[depth] > 0 ? listOrdinals[depth] : ordinal
        listOrdinals[depth] = shown + 1
        return ("\(shown)\(delimiter)", depth)
    }

    private func continuationDepth(_ indent: Int) -> Int? {
        guard let first = listIndents.first, indent > first else { return nil }
        return listIndents.filter { $0 < indent }.count - 1
    }

    private mutating func resetList() {
        listIndents.removeAll()
        listOrdinals.removeAll()
    }

    private mutating func table(_ block: ChatOpenBlock) -> ChatTextSegment {
        var rows: [ChatTableRow] = []
        var own = ChatLetterCount()
        for (index, line) in block.lines.enumerated() {
            let cells = ChatTextParser.cellRanges(line, units, spans: spans)
            // Line 1 is the delimiter row, complete or still streaming in
            // ("|:" is not a row of its own), as hasDelimiterRow checked.
            if index == 1 || ChatTextParser.isDelimiterRow(cells, units) {
                if index == 1, let header = rows.first {
                    rows[0] = ChatTableRow(id: header.id, cells: header.cells, isHeader: true)
                }
                continue
            }
            // A last line that is a lone bar is the next row still streaming.
            if index > 0, index == block.lines.count - 1, cells.count == 1, cells[0].length == 0 { continue }
            let texts = cells.map { ChatTextParser.cellText($0, source: source, spans: spans) }
            for text in texts { own.add(text) }
            rows.append(ChatTableRow(id: line.location, cells: texts, isHeader: false))
        }
        letters.rightToLeft += own.rightToLeft
        letters.other += own.other
        return ChatTextSegment(id: block.id, kind: .table(rows), rightToLeft: own.direction)
    }
}

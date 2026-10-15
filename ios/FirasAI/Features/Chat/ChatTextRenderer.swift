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
        /// LaTeX source, inline flag, and the readable Unicode drawn for it.
        case math(String, Bool, String)
    }
}

/// One drawn line of a block: running text with its inline formulas inside
/// it, or a display formula on a line of its own.
nonisolated struct ChatTextLine: Identifiable, Sendable {
    let id: Int
    let kind: Kind

    nonisolated enum Kind: Sendable {
        case text(AttributedString)
        case display(String)
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
    fileprivate static let dollar: UInt16 = 0x24
    fileprivate static let openingParenthesis: UInt16 = 0x28
    fileprivate static let openingBracket: UInt16 = 0x5B
    fileprivate static let closingBracket: UInt16 = 0x5D

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
            spans += try mathSpans(units, source: source, range: gap)
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

    /// A block's pieces as drawn lines. An inline formula joins the text
    /// around it, isolated left to right so it reads in order inside Arabic
    /// and never breaks its sentence; a display formula starts its own line.
    static func lines(_ pieces: [ChatTextPiece]) -> [ChatTextLine] {
        var lines: [ChatTextLine] = []
        var text = AttributedString()
        var textID: Int?
        var opensWithFormula = false
        var mark: Character?

        func flush() {
            guard let id = textID else { return }
            // A line that opens with a formula still takes its block's
            // direction, from the mark marked() put on the block's words; a
            // line of formulas and symbols alone reads left to right.
            if opensWithFormula { text = AttributedString(String(mark ?? "\u{200E}")) + text }
            lines.append(ChatTextLine(id: id, kind: .text(text)))
            text = AttributedString()
            textID = nil
            opensWithFormula = false
            mark = nil
        }

        for piece in pieces {
            switch piece.kind {
            case .markdown(_, let words):
                if textID == nil { textID = piece.id }
                if mark == nil, let first = words.characters.first, first == "\u{200F}" || first == "\u{200E}" {
                    mark = first
                }
                text += words
            case .math(_, true, let readable):
                if textID == nil {
                    textID = piece.id
                    opensWithFormula = true
                }
                text += AttributedString("\u{2066}" + readable + "\u{2069}")
            case .math(_, false, let readable):
                flush()
                lines.append(ChatTextLine(id: piece.id, kind: .display(readable)))
            }
        }
        flush()
        return lines
    }

    // The one native answer to "where is the math", walked as the website's
    // scanMathSpans walks it: \[…\] and $$…$$ are display, \(…\) and $…$
    // inline, an escaped character or a `code` span is never a delimiter,
    // and a $ pair is a formula only when it plausibly is one. Fences were
    // cut out by the caller. Unlike the website, nothing reaches past its
    // gap, and an inline formula or code span never reaches past its line.
    private static func mathSpans(_ units: [UInt16], source: NSString, range: NSRange) throws -> [ChatMathSpan] {
        try Task.checkCancellation()
        var spans: [ChatMathSpan] = []
        let end = NSMaxRange(range)

        func add(_ start: Int, body: Int, bodyEnd: Int, stop: Int, inline: Bool) {
            let value = source.substring(with: NSRange(location: body, length: bodyEnd - body))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            spans.append(ChatMathSpan(range: NSRange(location: start, length: stop - start), value: value, inline: inline))
        }

        var index = range.location
        while index < end {
            let unit = units[index]
            if unit == backslash {
                let next = index + 1 < end ? units[index + 1] : 0
                if next == openingBracket || next == openingParenthesis {
                    let inline = next == openingParenthesis
                    let closer = inline ? closingParenthesis : closingBracket
                    var search = index + 2
                    var close: Int?
                    while search + 1 < end, !(inline && units[search] == newline) {
                        if units[search] == backslash {
                            if units[search + 1] == closer {
                                close = search
                                break
                            }
                            search += 1
                        }
                        search += 1
                    }
                    if let close {
                        add(index, body: index + 2, bodyEnd: close, stop: close + 2, inline: inline)
                        index = close + 2
                        continue
                    }
                }
                index += 2
                continue
            }
            if unit == backtick {
                var run = index
                while run < end, units[run] == backtick { run += 1 }
                let length = run - index
                var search = run
                var close: Int?
                while search < end, units[search] != newline {
                    guard units[search] == backtick else {
                        search += 1
                        continue
                    }
                    var closing = search
                    while closing < end, units[closing] == backtick { closing += 1 }
                    if closing - search == length {
                        close = closing
                        break
                    }
                    search = closing
                }
                index = close ?? run
                continue
            }
            if unit == dollar {
                if index + 1 < end, units[index + 1] == dollar {
                    var search = index + 2
                    var close: Int?
                    while search + 1 < end {
                        if units[search] == backslash {
                            search += 2
                            continue
                        }
                        if units[search] == dollar, units[search + 1] == dollar {
                            close = search
                            break
                        }
                        search += 1
                    }
                    if let close {
                        add(index, body: index + 2, bodyEnd: close, stop: close + 2, inline: false)
                        index = close + 2
                    } else {
                        // Still streaming: the opening pair stays text.
                        index += 2
                    }
                    continue
                }
                var search = index + 1
                var close: Int?
                while search < end, units[search] != newline {
                    if units[search] == backslash {
                        search += search + 1 < end && units[search + 1] != newline ? 2 : 1
                        continue
                    }
                    if units[search] == dollar {
                        close = search
                        break
                    }
                    search += 1
                }
                if let close,
                   acceptsInline(source.substring(with: NSRange(location: index + 1, length: close - index - 1)),
                                 next: close + 1 < end ? units[close + 1] : nil) {
                    add(index, body: index + 1, bodyEnd: close, stop: close + 1, inline: true)
                    index = close + 1
                    continue
                }
                // No partner, or a pair that is not a formula: a literal dollar.
                index += 1
                continue
            }
            index += 1
        }
        return spans
    }

    /// The website's acceptInline, less the line rules a one-line body cannot
    /// break: a price pair, Arabic prose or plain Latin prose is not a formula.
    private static func acceptsInline(_ body: String, next: UInt16?) -> Bool {
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // "$5 for tea and $3": digit-led on both sides of the pair.
        if let first = body.unicodeScalars.first, isAnyDigit(first.value),
           let next, isAnyDigit(UInt32(next)) {
            return false
        }
        // Arabic reaches real math only inside \text{…}; two Arabic letters
        // in a row anywhere else are a sentence adopted as an equation.
        var run = 0
        for scalar in withoutTextGroups(body) {
            switch scalar.value {
            case 0x0620...0x065F, 0x066E...0x06D3, 0x06FA...0x06FC:
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                    run += 1
                    if run > 1 { return false }
                default:
                    break
                }
            default:
                run = 0
            }
        }
        // Four or more Latin words and not one TeX construct among them.
        let words = body.split(whereSeparator: { $0.isWhitespace })
        if words.count >= 4, !body.contains(where: { "\\^_{}=".contains($0) }) { return false }
        return true
    }

    private static func isAnyDigit(_ value: UInt32) -> Bool {
        (0x30...0x39).contains(value) || (0x0660...0x0669).contains(value) || (0x06F0...0x06F9).contains(value)
    }

    /// A formula with its \text{…}-style groups blanked out, as the
    /// website's mathWithoutTextGroups reads it.
    private static func withoutTextGroups(_ body: String) -> [Unicode.Scalar] {
        let scalars = Array(body.unicodeScalars)
        var output: [Unicode.Scalar] = []
        var index = 0
        while index < scalars.count {
            if scalars[index] == "\\" {
                var position = index + 1
                var name = ""
                while position < scalars.count, scalars[position].isASCII, scalars[position].properties.isAlphabetic {
                    name.unicodeScalars.append(scalars[position])
                    position += 1
                }
                if ["text", "textrm", "textbf", "textit", "textsf", "texttt", "textnormal", "mbox", "operatorname", "mathrm"]
                    .contains(name) {
                    if position < scalars.count, scalars[position] == "*" { position += 1 }
                    while position < scalars.count, scalars[position] == " " { position += 1 }
                    if position < scalars.count, scalars[position] == "{" {
                        var level = 1
                        position += 1
                        while position < scalars.count, level > 0 {
                            if scalars[position] == "\\" {
                                position += 2
                                continue
                            }
                            if scalars[position] == "{" {
                                level += 1
                            } else if scalars[position] == "}" {
                                level -= 1
                            }
                            position += 1
                        }
                        if level == 0 {
                            output.append(" ")
                            index = position
                            continue
                        }
                    }
                }
            }
            output.append(scalars[index])
            index += 1
        }
        return output
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

        // Text is trimmed at a block or display edge, but keeps the spaces
        // that part it from an inline formula: both are drawn in one line.
        // Those spaces stay outside the Markdown parse, which may trim them.
        func flush(before next: ChatMathSpan?) {
            var afterInline = false
            if case .math(_, true, _)? = result.last?.kind { afterInline = true }
            var value = buffer
            if !afterInline { value = String(value.drop(while: { $0.isWhitespace })) }
            if next?.inline != true {
                while value.last?.isWhitespace == true { value.removeLast() }
            }
            if let start = bufferStart, !value.isEmpty {
                let leading = String(value.prefix(while: { $0.isWhitespace }))
                let core = value.dropFirst(leading.count)
                let trailing = String(core.reversed().prefix(while: { $0.isWhitespace }).reversed())
                let words = String(core.dropLast(trailing.count))
                var text = AttributedString(leading)
                if !words.isEmpty { text += ChatTextParser.inlineMarkdown(words) }
                text += AttributedString(trailing)
                result.append(ChatTextPiece(id: start, kind: .markdown(value, text)))
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
            if index > 0 {
                if bufferStart != nil {
                    buffer += "\n"
                } else if case .math(_, true, _)? = result.last?.kind {
                    // The break after a formula that ended the line above,
                    // identified by the offset of that line break.
                    bufferStart = line.location - 1
                    buffer = "\n"
                }
            }
            let end = NSMaxRange(line)
            var cursor = line.location
            var spanIndex = firstSpan(spans, atOrAfter: cursor)
            while spanIndex < spans.count, spans[spanIndex].range.location < end {
                let span = spans[spanIndex]
                appendText(cursor, span.range.location)
                flush(before: span)
                result.append(ChatTextPiece(
                    id: span.range.location,
                    kind: .math(span.value, span.inline, ChatMathText.readable(span.value, inline: span.inline))
                ))
                cursor = NSMaxRange(span.range)
                spanIndex += 1
            }
            appendText(cursor, end)
        }
        flush(before: nil)
        return result
    }

    /// Text takes its base direction from its first strong letter, and each
    /// line after a break is a paragraph of its own. The mark, at the start
    /// and after every break, makes each line agree with the block's dominant
    /// script, so an Arabic sentence that opens with a Latin term still reads
    /// right to left.
    fileprivate static func marked(_ pieces: [ChatTextPiece], rightToLeft: Bool?) -> [ChatTextPiece] {
        guard let rightToLeft else { return pieces }
        let mark = AttributedString(rightToLeft ? "\u{200F}" : "\u{200E}")
        return pieces.map { piece -> ChatTextPiece in
            guard case .markdown(let value, let text) = piece.kind else { return piece }
            var result = mark
            var start = text.startIndex
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.characters.index(after: index)
                if text.characters[index].isNewline {
                    result += text[start..<next]
                    result += mark
                    start = next
                }
                index = next
            }
            result += text[start..<text.endIndex]
            return ChatTextPiece(id: piece.id, kind: .markdown(value, result))
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

    /// A table cell is one line of Text, so a formula inside it runs in the
    /// cell's text as an isolated readable run, as it does in a paragraph.
    /// Only the cell's words are counted toward its direction.
    fileprivate static func cellText(
        _ range: NSRange, source: NSString, spans: [ChatMathSpan], letters: inout ChatLetterCount
    ) -> AttributedString {
        var text = AttributedString()
        var cursor = range.location
        let end = NSMaxRange(range)
        var spanIndex = firstSpan(spans, atOrAfter: cursor)
        while spanIndex < spans.count, spans[spanIndex].range.location < end {
            let span = spans[spanIndex]
            if span.range.location > cursor {
                let words = inlineMarkdown(source.substring(with: NSRange(location: cursor, length: span.range.location - cursor)))
                letters.add(words)
                text += words
            }
            text += AttributedString("\u{2066}" + ChatMathText.readable(span.value, inline: true) + "\u{2069}")
            cursor = NSMaxRange(span.range)
            spanIndex += 1
        }
        if cursor < end {
            let words = inlineMarkdown(source.substring(with: NSRange(location: cursor, length: end - cursor)))
            letters.add(words)
            text += words
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
    /// English. Formulas are never added here, in paragraphs or in tables.
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
            var texts: [AttributedString] = []
            for cell in cells {
                texts.append(ChatTextParser.cellText(cell, source: source, spans: spans, letters: &own))
            }
            rows.append(ChatTableRow(id: line.location, cells: texts, isHeader: false))
        }
        letters.rightToLeft += own.rightToLeft
        letters.other += own.other
        return ChatTextSegment(id: block.id, kind: .table(rows), rightToLeft: own.direction)
    }
}

/// LaTeX as readable Unicode, for a screen that does not typeset:
/// x^2 → x², \frac{x+1}{2} → (x+1)/2, \sqrt{x} → √x, \int_0^1 → ∫₀¹.
/// The symbol and script tables follow the website's texToUnicode; it never
/// fails, and an unknown command keeps its name without the backslash.
nonisolated enum ChatMathText {
    static func readable(_ tex: String, inline: Bool) -> String {
        var reader = ChatTexReader(tex, inline: inline)
        return tidy(reader.sequence(until: nil))
    }

    /// One space between words, none at a line's ends or inside a bracket's
    /// edge. A display formula breaks lines only where its source wrote \\.
    static func tidy(_ text: String) -> String {
        text.split(separator: "\n")
            .map { line in
                line.split(separator: " ").joined(separator: " ")
                    .replacingOccurrences(of: "( ", with: "(")
                    .replacingOccurrences(of: " )", with: ")")
                    .replacingOccurrences(of: " ,", with: ",")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// A raised or lowered run. When a character has no small form the run
    /// is written ^(…) or _(…), as the website does.
    static func script(_ value: String, superscript: Bool) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        let table = superscript ? superscripts : subscripts
        var small = ""
        var mapped = 0
        var previous: Character?
        var spaced = false
        for character in trimmed {
            if character.isWhitespace {
                spaced = true
                continue
            }
            // A space between two words is meaningful: "ln x" is not "lnx".
            if spaced, let previous, isWord(previous), isWord(character) {
                mapped = 0
                break
            }
            spaced = false
            previous = character
            if let form = table[character] {
                small += form
                mapped += 1
            } else if !superscript, [",", "→", "∞"].contains(character) {
                // A limit such as x → 0 keeps its arrow on the line.
                small.append(character)
            } else {
                mapped = 0
                break
            }
        }
        if mapped > 0 { return small }
        let mark = superscript ? "^" : "_"
        return trimmed.count == 1 ? mark + trimmed : mark + "(" + trimmed + ")"
    }

    /// A fraction's part keeps brackets only when it is more than one term:
    /// an operator outside brackets, or a space between two words. Under the
    /// bar a coefficient counts too, so 1/(2a) never reads as (1/2)a.
    static func grouped(_ part: String, denominator: Bool = false) -> String {
        let value = part.trimmingCharacters(in: .whitespaces)
        var level = 0
        var previous: Character?
        var spaced = false
        for (offset, character) in value.enumerated() {
            if character.isWhitespace {
                spaced = true
                continue
            }
            defer {
                previous = character
                spaced = false
            }
            switch character {
            case "(", "[", "{", "⟨":
                level += 1
            case ")", "]", "}", "⟩":
                level -= 1
            default:
                guard level == 0 else { continue }
                let parted = spaced && previous.map(isWord) == true && isWord(character)
                let coefficient = denominator && previous?.isNumber == true && character.isLetter
                if parted || coefficient || (offset > 0 && compoundMarks.contains(character)) {
                    return "(" + value + ")"
                }
            }
        }
        return value
    }

    /// √x for a number or a single symbol, √(…) for anything longer.
    static func root(_ radicand: String, degree: String) -> String {
        let value = radicand.trimmingCharacters(in: .whitespaces)
        let index = degree.trimmingCharacters(in: .whitespaces)
        let atom = value.count == 1 || (!value.isEmpty && value.allSatisfy { $0.isNumber || $0 == "." })
        return (index.isEmpty ? "" : script(index, superscript: true)) + "√" + (atom ? value : "(" + value + ")")
    }

    /// Each character carries the mark, so \overline{AB} is one line over both.
    static func overlined(_ value: String) -> String {
        value.map { $0.isWhitespace ? String($0) : String($0) + "\u{0305}" }.joined()
    }

    static func accented(_ value: String, _ mark: String) -> String {
        value.isEmpty ? "" : value + mark
    }

    /// \ce{…}: H2O → H₂O, SO4^{2-} → SO₄²⁻, -> → →.
    static func chemistry(_ formula: String) -> String {
        var text = formula
        for (arrow, symbol) in [("<=>", "⇌"), ("<->", "↔"), ("->", "→"), ("<-", "←")] {
            text = text.replacingOccurrences(of: arrow, with: symbol)
        }
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "^" {
                var charge = ""
                if index < characters.count, characters[index] == "{" {
                    index += 1
                    while index < characters.count, characters[index] != "}" {
                        charge.append(characters[index])
                        index += 1
                    }
                    index += 1
                } else {
                    while index < characters.count, characters[index].isNumber || "+-".contains(characters[index]) {
                        charge.append(characters[index])
                        index += 1
                    }
                }
                output += script(charge, superscript: true)
            } else if character == "\\" {
                var name = ""
                while index < characters.count, characters[index].isASCII, characters[index].isLetter {
                    name.append(characters[index])
                    index += 1
                }
                output += symbols[name] ?? name
            } else if character.isASCII, character.isNumber, let previous = output.last,
                      previous.isLetter || previous == ")" || subscriptDigits.contains(previous) {
                output += subscripts[character] ?? String(character)
            } else if character != "{", character != "}" {
                output.append(character)
            }
        }
        return output
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static let compoundMarks: Set<Character> = [
        "+", "-", "−", "±", "∓", "=", "≠", "<", ">", "≤", "≥", "≈", "≡", "/", "·", "×", "÷", ",", "→",
    ]

    private static let subscriptDigits: Set<Character> = ["₀", "₁", "₂", "₃", "₄", "₅", "₆", "₇", "₈", "₉"]

    static let superscripts: [Character: String] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ",
        "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ",
        "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
        "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ", "H": "ᴴ", "I": "ᴵ", "J": "ᴶ", "K": "ᴷ", "L": "ᴸ",
        "M": "ᴹ", "N": "ᴺ", "O": "ᴼ", "P": "ᴾ", "R": "ᴿ", "T": "ᵀ", "U": "ᵁ", "V": "ⱽ", "W": "ᵂ",
        "α": "ᵅ", "β": "ᵝ", "γ": "ᵞ", "δ": "ᵟ", "θ": "ᶿ", "φ": "ᵠ", "χ": "ᵡ",
        "∘": "°", "°": "°", "′": "′", "'": "′", "*": "*",
    ]

    static let subscripts: [Character: String] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
        "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
        "β": "ᵦ", "γ": "ᵧ", "ρ": "ᵨ", "φ": "ᵩ", "χ": "ᵪ",
    ]

    static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ",
        "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν",
        "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ",
        "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ",
        "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮", "sum": "Σ", "prod": "∏", "coprod": "∐",
        "bigcup": "⋃", "bigcap": "⋂", "infty": "∞", "partial": "∂", "nabla": "∇",
        "times": "×", "cdot": "·", "cdotp": "·", "cdots": "⋯", "ldots": "…", "dots": "…", "vdots": "⋮",
        "ddots": "⋱", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "•",
        "oplus": "⊕", "otimes": "⊗", "odot": "⊙", "setminus": "∖",
        "leq": "≤", "le": "≤", "leqslant": "≤", "geq": "≥", "ge": "≥", "geqslant": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪",
        "gg": "≫", "mid": "|", "parallel": "∥", "perp": "⊥", "lt": "<", "gt": ">",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "leftrightarrow": "↔", "longrightarrow": "⟶", "longleftarrow": "⟵",
        "Longrightarrow": "⟹", "Longleftarrow": "⟸", "longleftrightarrow": "⟷", "Longleftrightarrow": "⟺",
        "implies": "⟹", "impliedby": "⟸", "iff": "⟺", "mapsto": "↦", "uparrow": "↑", "downarrow": "↓",
        "rightleftharpoons": "⇌",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃",
        "nexists": "∄", "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨", "neg": "¬", "lnot": "¬",
        "therefore": "∴", "because": "∵",
        "angle": "∠", "measuredangle": "∡", "triangle": "△", "square": "□", "degree": "°", "prime": "′",
        "aleph": "ℵ", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "checkmark": "✓", "dagger": "†",
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "lbrace": "{", "rbrace": "}", "vert": "|", "lvert": "|", "rvert": "|", "Vert": "‖", "lVert": "‖",
        "rVert": "‖", "colon": ":",
        "quad": " ", "qquad": "  ", "enspace": " ", "thinspace": " ",
    ]

    /// Named functions, drawn upright and set apart from the term they take.
    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth",
        "log", "ln", "lg", "exp", "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "deg", "dim",
        "gcd", "lcm", "arg", "ker", "hom", "Pr",
    ]

    static let doubleStruck: [Character: Character] = [
        "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "R": "ℝ", "C": "ℂ", "P": "ℙ", "H": "ℍ",
    ]

    static let negations: [String: String] = [
        "=": "≠", "∈": "∉", "⊂": "⊄", "⊆": "⊈", "≡": "≢", "<": "≮", ">": "≯", "∃": "∄", "∼": "≁",
        "≤": "≰", "≥": "≱",
    ]
}

/// Reads one formula's TeX once, left to right. Braces group without being
/// drawn; an unmatched closing brace is dropped rather than shown.
private nonisolated struct ChatTexReader {
    private let characters: [Character]
    private let inline: Bool
    private var index = 0
    private var depth = 0
    /// Open cases environments.
    private var cases = 0

    init(_ tex: String, inline: Bool) {
        characters = Array(tex)
        self.inline = inline
    }

    private var current: Character? {
        index < characters.count ? characters[index] : nil
    }

    /// Reads up to the closer, which is consumed, or to the end.
    mutating func sequence(until closer: Character?) -> String {
        depth += 1
        defer { depth -= 1 }
        var output = ""
        while let character = current {
            if character == closer {
                index += 1
                return output
            }
            switch character {
            case "\\":
                output += command(after: output.last)
            case "{":
                if depth > 32 {
                    output += rawArgument()
                } else {
                    index += 1
                    output += sequence(until: "}")
                }
            case "}":
                index += 1
            case "^", "_":
                index += 1
                output += ChatMathText.script(argument(), superscript: character == "^")
            case "&":
                // Inside cases, & parts a value from its condition.
                index += 1
                output += cases > 0 ? ", " : " "
            case "~", "\n", "\r", "\r\n", "\t":
                index += 1
                output += " "
            default:
                index += 1
                output.append(character)
            }
        }
        return output
    }

    /// One argument: a braced group, a command, or a single character.
    private mutating func argument() -> String {
        skipSpaces()
        guard let character = current else { return "" }
        // A pathological nest is kept as written rather than read deeper.
        if depth > 32 { return character == "}" ? "" : rawArgument() }
        depth += 1
        defer { depth -= 1 }
        switch character {
        case "{":
            index += 1
            return sequence(until: "}")
        case "}":
            return ""
        case "\\":
            return command(after: nil)
        default:
            index += 1
            return String(character)
        }
    }

    /// A braced argument as written, unread.
    private mutating func rawArgument() -> String {
        skipSpaces()
        guard let first = current else { return "" }
        index += 1
        guard first == "{" else { return String(first) }
        var level = 1
        var output = ""
        while let character = current {
            index += 1
            if character == "\\", let escaped = current {
                output.append(character)
                output.append(escaped)
                index += 1
                continue
            }
            if character == "{" {
                level += 1
            } else if character == "}" {
                level -= 1
                if level == 0 { return output }
            }
            output.append(character)
        }
        return output
    }

    private mutating func skipSpaces() {
        while let character = current, character.isWhitespace { index += 1 }
    }

    private mutating func command(after previous: Character?) -> String {
        index += 1
        guard let first = current else { return "" }
        guard first.isASCII, first.isLetter else {
            index += 1
            switch first {
            case "\\":
                return inline ? " " : "\n"
            case ",", ";", ":", ">", " ", "\n", "\r\n", "\t":
                return " "
            case "!":
                return ""
            case "|":
                return "‖"
            default:
                // \{ \} \% \$ \& \# \_ are the characters themselves.
                return String(first)
            }
        }
        var name = ""
        while let character = current, character.isASCII, character.isLetter {
            name.append(character)
            index += 1
        }
        if current == "*", ["operatorname", "hspace", "vspace"].contains(name) { index += 1 }

        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            let top = argument()
            let bottom = argument()
            // Set apart from a term it touches: 2\frac{1}{2} is not 21/2.
            let leading = previous.map { $0.isLetter || $0.isNumber || $0 == ")" } == true ? " " : ""
            let trailing = nextStartsTerm(orBracket: true) ? " " : ""
            return leading + ChatMathText.grouped(top) + "/" + ChatMathText.grouped(bottom, denominator: true) + trailing
        case "sqrt":
            skipSpaces()
            var degree = ""
            // Past the cap the "[" is read as one character by argument(),
            // so \sqrt[\sqrt[… cannot recurse without limit.
            if current == "[", depth <= 32 {
                index += 1
                degree = sequence(until: "]")
            }
            return ChatMathText.root(argument(), degree: degree)
        case "left", "right", "middle", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
             "biggl", "biggr", "Biggl", "Biggr":
            skipSpaces()
            // \left. and \right. are invisible delimiters.
            if current == "." { index += 1 }
            return ""
        case "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "limits", "nolimits",
             "nonumber", "notag":
            return ""
        case "begin", "end":
            let environment = argument()
            if name == "begin", environment == "array" || environment == "tabular" { _ = rawArgument() }
            if environment == "cases" { cases = max(0, cases + (name == "begin" ? 1 : -1)) }
            return " "
        case "text", "textrm", "textbf", "textit", "textsf", "texttt", "textnormal", "textup", "emph", "mbox",
             "hbox", "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathcal", "mathscr", "mathfrak",
             "boldsymbol", "bm", "operatorname", "underline", "boxed", "fbox", "underbrace", "overbrace",
             "ensuremath":
            return argument()
        case "mathbb":
            return String(argument().map { ChatMathText.doubleStruck[$0] ?? $0 })
        case "overline", "bar":
            return ChatMathText.overlined(argument())
        case "vec", "overrightarrow":
            return ChatMathText.accented(argument(), "\u{20D7}")
        case "hat", "widehat":
            return ChatMathText.accented(argument(), "\u{0302}")
        case "tilde", "widetilde":
            return ChatMathText.accented(argument(), "\u{0303}")
        case "dot":
            return ChatMathText.accented(argument(), "\u{0307}")
        case "ddot":
            return ChatMathText.accented(argument(), "\u{0308}")
        case "binom", "dbinom", "tbinom":
            let total = argument()
            let chosen = argument()
            return "C(" + total + ", " + chosen + ")"
        case "pmod":
            return " (mod " + argument() + ")"
        case "bmod", "mod":
            return " mod "
        case "tag":
            return "  (" + argument() + ")"
        case "hspace", "phantom", "hphantom":
            _ = rawArgument()
            return " "
        case "vspace", "vphantom", "color", "label":
            _ = rawArgument()
            return ""
        case "textcolor", "colorbox":
            _ = rawArgument()
            return argument()
        case "not":
            let negated = argument()
            return ChatMathText.negations[negated] ?? negated + "\u{0338}"
        case "ce", "pu":
            return ChatMathText.chemistry(rawArgument())
        default:
            if let symbol = ChatMathText.symbols[name] {
                // ∂ and ∇ belong to the variable after them: ∂f/∂x.
                if name == "partial" || name == "nabla" { skipSpaces() }
                return symbol
            }
            // A function, or a command this reader does not know, keeps its
            // name, set apart from the term it takes: \sin\theta → sin θ.
            return nextStartsTerm(orBracket: false) ? name + " " : name
        }
    }

    /// Whether what follows starts a term that would run into a name or a
    /// fraction: a letter, a digit, a Greek letter or a function.
    private func nextStartsTerm(orBracket bracket: Bool) -> Bool {
        guard let next = current else { return false }
        if next.isLetter || next.isNumber || (bracket && next == "(") { return true }
        guard next == "\\" else { return false }
        var name = ""
        var position = index + 1
        while position < characters.count, characters[position].isASCII, characters[position].isLetter {
            name.append(characters[position])
            position += 1
        }
        if bracket, name == "left" { return true }
        if ChatMathText.functions.contains(name) || ["frac", "dfrac", "tfrac", "sqrt"].contains(name) { return true }
        return ChatMathText.symbols[name]?.first?.isLetter == true
    }
}

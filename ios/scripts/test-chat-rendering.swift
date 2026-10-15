import Foundation

// Compile with the production ChatTextRenderer.swift on Xcode 26.
@main
enum ChatRenderingTests {
    static func main() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
        }
        func pieces(_ segment: ChatTextSegment) -> [ChatTextPiece] {
            switch segment.kind {
            case .paragraph(let pieces), .heading(_, let pieces), .listItem(_, _, let pieces), .quote(let pieces):
                return pieces
            default:
                return []
            }
        }
        // What Text draws, without the invisible direction mark.
        func visible(_ piece: ChatTextPiece) -> String? {
            guard case .markdown(_, let text) = piece.kind else { return nil }
            return String(text.characters)
                .replacingOccurrences(of: "\u{200F}", with: "")
                .replacingOccurrences(of: "\u{200E}", with: "")
        }
        func strong(_ piece: ChatTextPiece) -> [String] {
            guard case .markdown(_, let text) = piece.kind else { return [] }
            return text.runs.compactMap { run -> String? in
                guard run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true else { return nil }
                return String(text[run.range].characters)
            }
        }

        let empty = try ChatTextParser.segments(from: "")
        expect(empty.count == 1 && empty.first?.id == 0, "empty text retains a stable row")
        let base = "شرح **واضح** $x^2$ ثم $$\\int_0^1 x dx$$ خاتمة"
        let initial = try ChatTextParser.segments(from: base)
        let extended = try ChatTextParser.segments(from: base + " إضافية")
        let initialPieces = initial.flatMap(pieces)
        let extendedPieces = extended.flatMap(pieces)
        expect(initial.count == 1 && initialPieces.count == 5, "existing inline/display scanner splits multilingual content inside its paragraph")
        expect(initial.map(\.id) == extended.map(\.id) && initialPieces.map(\.id) == extendedPieces.map(\.id),
               "appending text does not replace existing block identities")
        expect(Set(initialPieces.map(\.id)).count == initialPieces.count, "segment identifiers are unique")

        let math = initialPieces.compactMap { piece -> (String, Bool)? in
            if case .math(let value, let inline) = piece.kind { return (value, inline) }
            return nil
        }
        expect(math.count == 2, "both math blocks are preserved")
        expect(math[0].0 == "x^2" && math[0].1, "inline formula remains inline")
        expect(math[1].0 == "\\int_0^1 x dx" && !math[1].1, "display formula remains display")

        let multiline = try ChatTextParser.segments(from: "مقدمة 😀 $$a +\nb = c$$ خاتمة")
        let multilinePieces = multiline.flatMap(pieces)
        expect(multiline.count == 1 && multilinePieces.count == 3, "display formula spans line separators without dropping surrounding text")
        if case .math(let expression, let inline) = multilinePieces[1].kind {
            expect(expression == "a +\nb = c" && !inline, "multiline display content and presentation remain intact")
            expect(multilinePieces[1].id == ("مقدمة 😀 " as NSString).length, "multiline formula offset uses UTF16 after an emoji")
        } else {
            preconditionFailure("multiline display text must remain a formula")
        }

        let unfinished = try ChatTextParser.segments(from: "نص $غير مكتمل")
        let unfinishedPieces = unfinished.flatMap(pieces)
        expect(unfinished.count == 1 && unfinishedPieces.count == 1, "unfinished streamed delimiter remains visible text")
        if case .markdown(let text, _) = unfinishedPieces[0].kind {
            expect(text == "نص $غير مكتمل", "unfinished input is never dropped")
        } else {
            preconditionFailure("unfinished text must not be a formula")
        }

        // A numbered Arabic solution: Text draws no presentation intents, so
        // every break, number and heading must be a block of its own.
        let solutionText = "## الحل\n\nنبدأ بالمعطيات.\nثم نرتب الخطوات.\n\n1. نشتق الدالة **أولاً**\n2. نعوض القيمة $x=1$\n\nإذن الجواب ٥"
        let solution = try ChatTextParser.segments(from: solutionText)
        expect(solution.count == 5, "heading, two paragraphs and two steps stay separate blocks")
        if case .heading(let level, let title) = solution[0].kind {
            expect(level == 2 && title.compactMap(visible) == ["الحل"], "heading keeps its level on a line of its own")
        } else {
            preconditionFailure("the solution must open with its heading")
        }
        if case .paragraph(let opening) = solution[1].kind {
            expect(opening.compactMap(visible) == ["نبدأ بالمعطيات.\nثم نرتب الخطوات."], "a single newline inside a paragraph stays a line break")
        } else {
            preconditionFailure("the first paragraph must follow the heading")
        }
        if case .listItem(let marker, let depth, let step) = solution[2].kind {
            expect(marker == "1." && depth == 0, "the first step keeps its number")
            expect(step.compactMap(visible) == ["نشتق الدالة أولاً"] && step.flatMap(strong) == ["أولاً"],
                   "inline bold inside a step renders without its asterisks")
            if case .markdown(_, let text) = step[0].kind {
                expect(String(text.characters).hasPrefix("\u{200F}"), "Arabic step text takes a right-to-left base direction")
            }
        } else {
            preconditionFailure("the first step must be a list item")
        }
        if case .listItem(let marker, _, let step) = solution[3].kind {
            expect(marker == "2." && step.count == 2, "the second step keeps its number and its formula")
            if case .math(let value, let inline) = step[1].kind {
                expect(value == "x=1" && inline, "a formula inside a step stays a math piece of that step")
            } else {
                preconditionFailure("the formula in the second step must stay a formula")
            }
        } else {
            preconditionFailure("the second step must be a list item")
        }
        if case .paragraph(let closing) = solution[4].kind {
            expect(closing.compactMap(visible) == ["إذن الجواب ٥"], "the closing paragraph survives the blank line after the list")
        } else {
            preconditionFailure("the answer must end with its own paragraph")
        }
        expect(solution.allSatisfy { $0.rightToLeft == true }, "an Arabic answer lays every block out right to left")
        let streamed = try ChatTextParser.segments(from: String(solutionText.prefix(55)))
        expect(streamed.map(\.id) == Array(solution.map(\.id).prefix(streamed.count)) && streamed.count == 3,
               "streamed blocks keep their identities as the answer grows")

        let paragraphs = try ChatTextParser.segments(from: "الفقرة الأولى\n\nالفقرة الثانية")
        expect(paragraphs.count == 2 && paragraphs.flatMap(pieces).compactMap(visible) == ["الفقرة الأولى", "الفقرة الثانية"],
               "a blank line between paragraphs survives as two blocks")
        let lines = try ChatTextParser.segments(from: "السطر الأول\nالسطر الثاني")
        expect(lines.count == 1 && lines.flatMap(pieces).compactMap(visible) == ["السطر الأول\nالسطر الثاني"],
               "a single newline stays inside its paragraph")

        let fenced = try ChatTextParser.segments(from: "قبل\n\n```swift\nlet a = \"$x$\" // $y$\n\n**not bold**\n```\nبعد")
        expect(fenced.count == 3, "a code fence is its own block between two paragraphs")
        if case .code(let language, let body) = fenced[1].kind {
            expect(language == "swift" && body == "let a = \"$x$\" // $y$\n\n**not bold**",
                   "code is verbatim: no formulas, no Markdown, blank lines kept")
        } else {
            preconditionFailure("a fenced block must render as code")
        }

        let streamingCode = "```python\nprint(1)\n"
        let openFence = try ChatTextParser.segments(from: streamingCode + "``")
        let openFenceStart = try ChatTextParser.segments(from: streamingCode)
        let closedFence = try ChatTextParser.segments(from: streamingCode + "```\nبعد")
        if case .code(let language, let body)? = openFence.first?.kind, openFence.count == 1 {
            expect(language == "python" && body == "print(1)", "an unterminated fence is code to the end, without its half-written closer")
        } else {
            preconditionFailure("an unterminated fence must render as code")
        }
        if case .code(_, let body)? = openFenceStart.first?.kind {
            expect(body == "print(1)" && openFenceStart.first?.id == openFence.first?.id, "streamed code keeps its text and identity")
        } else {
            preconditionFailure("an unterminated fence must render as code while it streams")
        }
        expect(closedFence.count == 2 && closedFence.first?.id == openFence.first?.id, "closing the fence keeps the code block and resumes prose")

        let bulletText = "- **أولاً** نقطة مهمة\n- ثم **ثانياً** أخرى\n  1. فرعية\n  1. تالية"
        let bullets = try ChatTextParser.segments(from: bulletText)
        let markers = bullets.compactMap { segment -> String? in
            if case .listItem(let marker, _, _) = segment.kind { return marker }
            return nil
        }
        let depths = bullets.compactMap { segment -> Int? in
            if case .listItem(_, let depth, _) = segment.kind { return depth }
            return nil
        }
        expect(markers == ["•", "•", "1.", "2."] && depths == [0, 0, 1, 1], "bullets and a nested numbered list keep markers and depth")
        expect(bullets[0...1].flatMap(pieces).flatMap(strong) == ["أولاً", "ثانياً"], "inline bold works inside list items")

        let table = try ChatTextParser.segments(from: "| x | $|x|$ |\n|---|:-:|\n| 1 | 2 |")
        if case .table(let rows)? = table.first?.kind, table.count == 1 {
            expect(rows.count == 2 && rows[0].isHeader && !rows[1].isHeader, "a pipe table keeps one row per line under its header")
            expect(rows[0].cells.count == 2 && String(rows[0].cells[1].characters) == "|x|", "a bar inside a formula is not a column")
        } else {
            preconditionFailure("a pipe table must not collapse into a paragraph")
        }

        let english = try ChatTextParser.segments(from: "Step one\n\n1. Do it")
        expect(english.allSatisfy { $0.rightToLeft == false }, "an English answer lays every block out left to right")
        let mixed = try ChatTextParser.segments(from: "HTML هي لغة ترميز النصوص")
        if case .markdown(_, let text)? = mixed.flatMap(pieces).first?.kind {
            expect(mixed.first?.rightToLeft == true && String(text.characters).hasPrefix("\u{200F}"),
                   "an Arabic sentence that opens with a Latin term still reads right to left")
        } else {
            preconditionFailure("mixed text must stay a paragraph")
        }

        // Inline code is not counted, as the website's autoDirOne skips code:
        // an Arabic setup step that names an identifier still reads right to left.
        func opens(_ piece: ChatTextPiece, with mark: String) -> Bool {
            guard case .markdown(_, let text) = piece.kind else { return false }
            return String(text.characters).hasPrefix(mark)
        }
        let setup = try ChatTextParser.segments(from: "1. ثبّت `react-router-dom`\n2. شغّل `npm run dev`")
        let setupPieces = setup.flatMap(pieces)
        expect(setup.count == 2 && setup.allSatisfy { $0.rightToLeft == true }, "Arabic steps that name code stay right to left")
        expect(setupPieces.count == 2 && setupPieces.allSatisfy { opens($0, with: "\u{200F}") },
               "each Arabic step that names code takes a right-to-left base direction")
        let install = try ChatTextParser.segments(from: "Install `react-router-dom` first")
        expect(install.count == 1 && install.first?.rightToLeft == false
                   && install.flatMap(pieces).allSatisfy { opens($0, with: "\u{200E}") },
               "an English sentence that names code stays left to right")
        let stringify = try ChatTextParser.segments(from: "استخدم `JSON.stringify()`")
        expect(stringify.first?.rightToLeft == true && stringify.flatMap(pieces).allSatisfy { opens($0, with: "\u{200F}") },
               "a short Arabic verb before an identifier reads right to left")
        let perBlock = try ChatTextParser.segments(from: "- نقطة عربية أولى في الشرح\n- Install it\n- `npm i`")
        expect(perBlock.map(\.rightToLeft) == [true, false, true],
               "an English bullet keeps its own direction; a block without letters follows the message")

        let streamingTable = try ChatTextParser.segments(from: "| a | b |\n|---|---|\n| 1 | 2")
        if case .table(let rows)? = streamingTable.first?.kind, streamingTable.count == 1 {
            expect(rows.count == 2 && rows[0].isHeader && rows[1].cells.map { String($0.characters) } == ["1", "2"],
                   "a streaming row joins its table before its closing bar arrives")
        } else {
            preconditionFailure("a streaming table row must not fall out of its table")
        }
        let nextRow = try ChatTextParser.segments(from: "| a | b |\n|")
        if case .table(let rows)? = nextRow.first?.kind, nextRow.count == 1 {
            expect(rows.count == 1, "a lone streaming bar adds no empty row")
        } else {
            preconditionFailure("a streaming bar must not end the table")
        }
        let partialDelimiter = try ChatTextParser.segments(from: "| a | b |\n|:")
        if case .table(let rows)? = partialDelimiter.first?.kind, partialDelimiter.count == 1 {
            expect(rows.count == 1 && rows[0].isHeader, "a delimiter row still streaming in is not a row of its own")
        } else {
            preconditionFailure("a streaming delimiter row must keep its table")
        }

        // GFM needs a delimiter row under the header. Without one, bars are
        // absolute values, and dropping them would change the equation.
        for equation in ["|x - 3| = |2x + 1|", "|x - 3| = |2x + 1|\nنربع الطرفين", "|a|"] {
            let segments = try ChatTextParser.segments(from: equation)
            let opening = equation.components(separatedBy: "\n")[0]
            if case .paragraph(let text)? = segments.first?.kind {
                expect(text.compactMap(visible) == [opening], "bars without a delimiter row stay visible text: \(opening)")
            } else {
                preconditionFailure("a line framed by bars must not become a table: \(opening)")
            }
        }
        let absolute = try ChatTextParser.segments(from: "الحل:\n|x - 3| = |2x + 1|\nنربع الطرفين")
        let absoluteText = absolute.compactMap { segment -> String? in
            guard case .paragraph(let text) = segment.kind else { return nil }
            return text.compactMap(visible).joined()
        }
        expect(absoluteText == ["الحل:", "|x - 3| = |2x + 1|", "نربع الطرفين"],
               "an equation with absolute values between two lines keeps its bars and stays out of a table")

        // A fence under a list item is indented by the item; its code keeps
        // only its own indentation.
        let nestedCode = try ChatTextParser.segments(from: "- مثال:\n    ```python\n    def f():\n        return 1\n    ```")
        if nestedCode.count == 2, case .listItem(let marker, _, _) = nestedCode[0].kind,
           case .code(let language, let body) = nestedCode[1].kind {
            expect(marker == "•" && language == "python" && body == "def f():\n    return 1",
                   "an indented fence under a bullet is code, not item text")
        } else {
            preconditionFailure("an indented fence under a list item must render as code")
        }
        let inlineFence = try ChatTextParser.segments(from: "```js const a = 1``` في السطر\n\nفقرة أخرى")
        let inlineFenceCode = inlineFence.filter { segment in
            if case .code = segment.kind { return true }
            return false
        }
        expect(inlineFence.count == 2 && inlineFenceCode.isEmpty,
               "an opener whose info string holds a backtick is inline code, not a fence to the end")
        let nestedFence = try ChatTextParser.segments(from: "```\nأ\n```python\nب\n```\nبعد")
        if case .code(_, let body)? = nestedFence.first?.kind, nestedFence.count == 2 {
            expect(body == "أ\n```python\nب", "a fence line with an info string does not close an open fence")
        } else {
            preconditionFailure("a nested opener must stay inside its code block")
        }

        let dangling = try ChatTextParser.segments(from: "Some text\n-")
        if case .paragraph(let text)? = dangling.first?.kind, dangling.count == 1 {
            expect(text.compactMap(visible) == ["Some text\n-"], "an empty item does not interrupt a paragraph")
        } else {
            preconditionFailure("a streaming dash under a line must not become an empty bullet")
        }
        let sibling = try ChatTextParser.segments(from: "- أ\n-")
        let siblingMarkers = sibling.compactMap { segment -> String? in
            if case .listItem(let marker, _, _) = segment.kind { return marker }
            return nil
        }
        expect(sibling.count == 2 && siblingMarkers == ["•", "•"], "an empty item after an item is still an item")

        let renderer = ChatTextRenderer()
        let first = try await renderer.render(base)
        let cached = try await renderer.render(base)
        expect(first.map(\.id) == cached.map(\.id), "cached rendering preserves stable identities")
        // Fill past both cache limits, then revisit a discarded value. Cache
        // eviction must never change the visible content or block identity.
        for index in 0..<60 {
            _ = try await renderer.render("\(index) " + String(repeating: "ع", count: 20_000))
        }
        let revisited = try await renderer.render(base)
        expect(revisited.map(\.id) == first.map(\.id), "eviction is transparent to a returning row")

        let gate = FormattingCancellationGate()
        let cancelled = Task {
            await gate.wait()
            return try await renderer.render(base)
        }
        await gate.waitUntilReady()
        cancelled.cancel()
        await gate.release()
        do {
            _ = try await cancelled.value
            preconditionFailure("cancelled formatting task completed")
        } catch is CancellationError {
            checks += 1
        }
        print("CLEAN: \(checks) production chat-rendering checks")
    }
}

private actor FormattingCancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilReady() async {
        while continuation == nil { await Task.yield() }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

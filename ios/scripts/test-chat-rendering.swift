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

        let empty = try ChatTextParser.segments(from: "")
        expect(empty.count == 1 && empty.first?.id == 0, "empty text retains a stable row")
        let base = "شرح **واضح** $x^2$ ثم $$\\int_0^1 x dx$$ خاتمة"
        let initial = try ChatTextParser.segments(from: base)
        let extended = try ChatTextParser.segments(from: base + " إضافية")
        expect(initial.count == 5, "existing inline/display scanner splits multilingual content")
        expect(initial.map(\.id) == extended.map(\.id), "appending text does not replace existing block identities")
        expect(Set(initial.map(\.id)).count == initial.count, "segment identifiers are unique")

        let math = initial.compactMap { segment -> (String, Bool)? in
            if case .math(let value, let inline) = segment.kind { return (value, inline) }
            return nil
        }
        expect(math.count == 2, "both math blocks are preserved")
        expect(math[0].0 == "x^2" && math[0].1, "inline formula remains inline")
        expect(math[1].0 == "\\int_0^1 x dx" && !math[1].1, "display formula remains display")

        let unfinished = try ChatTextParser.segments(from: "نص $غير مكتمل")
        expect(unfinished.count == 1, "unfinished streamed delimiter remains visible text")
        if case .markdown(let text, _) = unfinished[0].kind {
            expect(text == "نص $غير مكتمل", "unfinished input is never dropped")
        } else {
            preconditionFailure("unfinished text must not be a formula")
        }

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

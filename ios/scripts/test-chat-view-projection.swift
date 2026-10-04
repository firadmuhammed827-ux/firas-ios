import Foundation

// Compiles the actual production UI policy without SwiftUI/Models fixtures.
@main
enum ChatViewProjectionTests {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label)
            checks += 1
        }
        let padding = String(repeating: " \t\r\n", count: 15_000)
        let textCases = ["", " ", "\t\r\n", "\u{00a0}\u{2003}\u{2028}\u{2029}", "مرحبا", "\u{200b}",
                         "😀", " e\u{301} ", padding, "رد" + padding, padding + "answer"]
        for text in textCases {
            for context in [false, true] {
                let reference = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || context
                expect(ChatComposerContent.canSend(draft: text, hasReadyContext: context) == reference,
                       "composer preserves Foundation whitespace and ready-context semantics")
            }
        }
        // Compare every Foundation whitespace scalar, including less visible
        // Unicode separators, without duplicating a second whitespace table.
        for value in UInt32(0)...UInt32(0x3000) {
            guard let scalar = Unicode.Scalar(value), CharacterSet.whitespacesAndNewlines.contains(scalar) else { continue }
            let whitespace = String(scalar)
            expect(!ChatComposerContent.canSend(draft: whitespace, hasReadyContext: false), "whitespace alone is not Send")
            expect(ChatComposerContent.canSend(draft: whitespace + "ع", hasReadyContext: false), "leading Unicode whitespace retains text")
        }

        let existing = ChatTranscriptProjection(conversationID: "chat-a", messageCount: 4, lastMessageID: "assistant-a")
        let anotherRow = ChatTranscriptProjection(conversationID: "chat-a", messageCount: 5, lastMessageID: "user-next")
        let empty = ChatTranscriptProjection(conversationID: "chat-new", messageCount: 0, lastMessageID: nil)
        let firstTurn = ChatTranscriptProjection(conversationID: "chat-new", messageCount: 2, lastMessageID: "assistant-new")
        let baseline = ChatScrollGeometryProjection(contentHeight: 1800, viewportHeight: 800, nearBottom: true)
        let larger = ChatScrollGeometryProjection(contentHeight: 2000, viewportHeight: 800, nearBottom: false)
        let keyboard = ChatScrollGeometryProjection(contentHeight: 2000, viewportHeight: 440, nearBottom: false)

        var follow = ChatScrollFollowState()
        expect(follow.transcriptChanged(from: existing, to: existing), "first nonempty presentation reaches its last row")
        expect(!follow.transcriptChanged(from: existing, to: existing), "unchanged row identity/count does not repeat a scroll")
        expect(follow.geometryChanged(from: baseline, to: larger), "actual rich-text growth follows even before its offset catches up")
        expect(follow.followsLatestMessage, "layout growth does not imply a user chose earlier history")
        expect(follow.geometryChanged(from: larger, to: keyboard), "keyboard viewport change follows while the reader was following")
        expect(!follow.geometryChanged(from: keyboard, to: keyboard), "unchanged dimensions cannot retrigger layout scrolling")
        let offsetOnly = ChatScrollGeometryProjection(contentHeight: keyboard.contentHeight, viewportHeight: keyboard.viewportHeight, nearBottom: true)
        expect(!follow.geometryChanged(from: keyboard, to: offsetOnly), "programmatic offset recovery cannot create a geometry scroll loop")

        follow.updateInteraction(.user, nearBottom: false)
        expect(!follow.geometryChanged(from: baseline, to: larger), "streaming never overrides an active drag")
        expect(!follow.transcriptChanged(from: existing, to: anotherRow), "a new message does not interrupt reading earlier history")
        follow.updateInteraction(.idle, nearBottom: false)
        expect(!follow.followsLatestMessage && !follow.isUserScrolling, "deceleration ending away from bottom retains reading intent")
        expect(!follow.geometryChanged(from: larger, to: keyboard), "keyboard opening cannot pull an earlier-history reader down")

        follow.updateInteraction(.user, nearBottom: false)
        expect(!follow.transcriptChanged(from: anotherRow, to: empty), "empty chat selection has no missing scroll target")
        expect(follow.followsLatestMessage && !follow.isUserScrolling, "empty chat selection resets the previous reading gesture")
        expect(follow.transcriptChanged(from: empty, to: firstTurn), "the first turn in a previously empty new chat is followed")

        follow.updateInteraction(.user, nearBottom: true)
        expect(!follow.geometryChanged(from: baseline, to: larger), "a near-bottom live gesture is still owned by the reader")
        follow.updateInteraction(.idle, nearBottom: true)
        expect(follow.geometryChanged(from: baseline, to: larger), "normal following resumes after a near-bottom gesture ends")
        follow.updateInteraction(.user, nearBottom: false)
        follow.updateInteraction(.idle, nearBottom: false)
        follow.resumeFollowingLatest()
        follow.updateInteraction(.programmatic, nearBottom: false)
        expect(follow.followsLatestMessage && !follow.isUserScrolling, "explicit latest-button animation keeps following intent")
        expect(follow.geometryChanged(from: larger, to: keyboard), "viewport changes continue following after an intentional jump")

        // An explicit jump during deceleration must not depend on SwiftUI
        // delivering an animating phase. Exercise both idle/layout orderings,
        // including the immediate jump used with Reduce Motion.
        for geometryFirst in [false, true] {
            var jump = ChatScrollFollowState()
            jump.updateInteraction(.user, nearBottom: false)
            jump.resumeFollowingLatest()
            expect(jump.followsLatestMessage && !jump.isUserScrolling, "explicit jump retires the earlier gesture immediately")
            if !geometryFirst { jump.updateInteraction(.idle, nearBottom: false) }
            expect(jump.geometryChanged(from: larger, to: keyboard), "layout before animating preserves explicit jump intent")
            if geometryFirst { jump.updateInteraction(.idle, nearBottom: false) }
            expect(jump.followsLatestMessage && !jump.isUserScrolling, "late idle cannot restore the retired reading gesture")
            expect(!jump.geometryChanged(from: keyboard, to: offsetOnly), "explicit offset recovery does not loop after an immediate jump")
        }
        print("CLEAN: \(checks) production chat view projection checks")
    }
}

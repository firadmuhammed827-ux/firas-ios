import Foundation

/// Only the boolean is needed by the composer. Ready context bypasses the text
/// scan; ordinary text stops at its first non-whitespace scalar without making
/// a trimmed copy or scanning a long trailing run of whitespace.
nonisolated enum ChatComposerContent {
    static func canSend(draft: String, hasReadyContext: Bool) -> Bool {
        hasReadyContext || draft.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}

/// A changed answer or phase does not itself move the scroll target. Rich text
/// layout reports its actual size separately through the geometry projection.
nonisolated struct ChatTranscriptProjection: Equatable, Sendable {
    let conversationID: String?
    let messageCount: Int
    let lastMessageID: String?
}

nonisolated struct ChatScrollGeometryProjection: Equatable, Sendable {
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let nearBottom: Bool
}

nonisolated enum ChatScrollInteraction: Sendable {
    case user
    case idle
    case programmatic
}

/// View-owned scroll intent. Geometry may follow layout/keyboard changes, but
/// content offsets alone cannot cause a new programmatic scroll loop.
nonisolated struct ChatScrollFollowState: Equatable, Sendable {
    private(set) var followsLatestMessage = true
    private(set) var isUserScrolling = false
    private var hasObservedTranscript = false

    mutating func updateInteraction(_ interaction: ChatScrollInteraction, nearBottom: Bool) {
        switch interaction {
        case .user:
            isUserScrolling = true
            followsLatestMessage = nearBottom
        case .idle:
            if isUserScrolling { followsLatestMessage = nearBottom }
            isUserScrolling = false
        case .programmatic:
            isUserScrolling = false
        }
    }

    mutating func transcriptChanged(from previous: ChatTranscriptProjection, to current: ChatTranscriptProjection) -> Bool {
        let firstObservation = !hasObservedTranscript
        hasObservedTranscript = true
        // Reset even for an empty new chat. Its first accepted turn must not
        // inherit the previous conversation's "reading an earlier message".
        if previous.conversationID != current.conversationID {
            followsLatestMessage = true
            isUserScrolling = false
        }
        guard firstObservation || previous != current, current.messageCount > 0 else { return false }
        return followsLatestMessage && !isUserScrolling
    }

    mutating func geometryChanged(from previous: ChatScrollGeometryProjection, to current: ChatScrollGeometryProjection) -> Bool {
        if isUserScrolling {
            followsLatestMessage = current.nearBottom
            return false
        }
        return followsLatestMessage && (previous.contentHeight != current.contentHeight || previous.viewportHeight != current.viewportHeight)
    }

    mutating func resumeFollowingLatest() {
        followsLatestMessage = true
        // An explicit jump supersedes the previous drag/deceleration. Reduced
        // Motion can complete it without ever entering an animating phase.
        isUserScrolling = false
    }
}

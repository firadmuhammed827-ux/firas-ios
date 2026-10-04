import Foundation

/// Keep the original attachment position when an earlier thumbnail cannot decode.
nonisolated struct ChatImageSource: Identifiable, Equatable, Sendable {
    let id: Int
    let thumbnail: String
    let fullSize: String
}

nonisolated enum ChatImageSources {
    static let maximumEncodedBytes = 12 * 1_024 * 1_024

    static func entries(thumbnails: [String]?, images: [String]?) -> [ChatImageSource] {
        let originals = images ?? []
        let visible: [String]
        if let thumbnails, !thumbnails.isEmpty { visible = thumbnails } else { visible = originals }
        return visible.prefix(10).enumerated().map { index, thumbnail in
            let original = originals.indices.contains(index) ? originals[index] : ""
            return ChatImageSource(id: index, thumbnail: thumbnail,
                fullSize: original.isEmpty ? thumbnail : original)
        }
    }

    /// Called only by the background image decoder, never from a view body.
    static func bytes(from source: String) -> Data? {
        guard source.utf8.count <= maximumEncodedBytes else { return nil }
        let encoded = source.split(separator: ",", maxSplits: 1).last.map(String.init) ?? source
        return Data(base64Encoded: encoded)
    }
}

/// Photos may call back before requestImage returns its numeric request ID.
/// Reserve an immutable lease first, then attach/cancel that exact returned ID.
nonisolated struct PhotoThumbnailRequestState: Sendable {
    nonisolated struct Ticket: Equatable, Sendable {
        let assetID: String
        let nonce: UUID
    }

    nonisolated struct Reservation: Sendable {
        let ticket: Ticket
        let retiredRequestID: Int32?
    }

    private var ticket: Ticket?
    private var requestID: Int32?

    var assetID: String? { ticket?.assetID }

    mutating func reserve(assetID: String) -> Reservation {
        let retired = requestID
        let next = Ticket(assetID: assetID, nonce: UUID())
        ticket = next
        requestID = nil
        return Reservation(ticket: next, retiredRequestID: retired)
    }

    func accepts(_ expected: Ticket) -> Bool { ticket == expected }

    mutating func attach(_ id: Int32, to expected: Ticket) -> Bool {
        guard accepts(expected), requestID == nil else { return false }
        requestID = id
        return true
    }

    @discardableResult
    mutating func retire(matching expected: Ticket? = nil) -> Int32? {
        if let expected, !accepts(expected) { return nil }
        let retired = requestID
        ticket = nil
        requestID = nil
        return retired
    }
}

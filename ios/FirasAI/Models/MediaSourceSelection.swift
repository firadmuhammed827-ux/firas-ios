import Foundation

nonisolated enum MediaSourceFileError: Error, Sendable {
    case tooLarge
    case dimensionsTooLarge
}

/// This is a local preparation budget, independent of the server's byte cap.
/// Modern 48 MP photographs fit; extreme raster dimensions do not reach decode.
nonisolated enum MediaSourcePixelPolicy {
    static func accepts(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= 12_000 && height <= 12_000 &&
            width * height <= 50_000_000
    }
}

/// Reads a user-selected transfer file with a hard byte ceiling. The importing
/// representation calls this on its worker actor, not on the presentation actor.
nonisolated enum MediaSourceFileReader {
    static func read(at url: URL, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        guard url.isFileURL, maximumBytes > 0, maximumBytes <= 20_000_000 else { throw CocoaError(.fileReadNoPermission) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadCorruptFile) }
        if let size = values.fileSize, size > maximumBytes { throw MediaSourceFileError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bytes = Data()
        bytes.reserveCapacity(min(maximumBytes, max(0, values.fileSize ?? 0)))
        while true {
            try Task.checkCancellation()
            // The extra byte detects a file that grew after its metadata check.
            let requested = min(65_536, maximumBytes - bytes.count + 1)
            guard let chunk = try handle.read(upToCount: requested), !chunk.isEmpty else { break }
            guard chunk.count <= maximumBytes - bytes.count else { throw MediaSourceFileError.tooLarge }
            bytes.append(chunk)
        }
        guard !bytes.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return bytes
    }
}

nonisolated struct MediaSourceImage: Equatable, Sendable {
    let id: String
    let dataURI: String
    let thumbnailData: Data
}

nonisolated struct MediaSourceImportTicket: Equatable, Sendable {
    let id: UUID
    let ownerID: String
    let identityGeneration: Int
    let revision: Int
    let kind: MediaStudioKind
}

/// An import is admitted at the tap, not after Photos finishes. Revision protects
/// edits and image/video selection changes, including changing away and back.
nonisolated struct MediaSourceDraftState: Equatable, Sendable {
    private(set) var ownerID: String?
    private(set) var identityGeneration = -1
    private(set) var revision = 0
    private(set) var source: MediaSourceImage?
    private(set) var pending: MediaSourceImportTicket?

    func matches(ownerID: String?, identityGeneration: Int) -> Bool {
        self.ownerID == ownerID && self.identityGeneration == identityGeneration
    }
    @discardableResult mutating func bind(ownerID: String?, identityGeneration: Int) -> Bool {
        guard !matches(ownerID: ownerID, identityGeneration: identityGeneration) else { return false }
        self.ownerID = ownerID; self.identityGeneration = identityGeneration
        source = nil; revise(); return true
    }
    mutating func revise() { revision &+= 1; pending = nil }
    mutating func retireImport() { pending = nil }
    mutating func removeSource() { source = nil; revise() }
    mutating func begin(ownerID: String, identityGeneration: Int, kind: MediaStudioKind) {
        guard matches(ownerID: ownerID, identityGeneration: identityGeneration), kind != .music else { return }
        revise()
        pending = MediaSourceImportTicket(id: UUID(), ownerID: ownerID, identityGeneration: identityGeneration, revision: revision, kind: kind)
    }
    func accepts(_ ticket: MediaSourceImportTicket, kind: MediaStudioKind) -> Bool {
        pending == ticket && matches(ownerID: ticket.ownerID, identityGeneration: ticket.identityGeneration) &&
            revision == ticket.revision && ticket.kind == kind && kind != .music
    }
    @discardableResult mutating func accept(_ ticket: MediaSourceImportTicket, kind: MediaStudioKind, asset: MediaSourceImage) -> Bool {
        guard accepts(ticket, kind: kind) else { return false }
        source = asset; revise(); return true
    }

    /// A server receipt may arrive after the person has edited the next brief.
    /// Consume only the unchanged source/draft admitted by that particular tap.
    @discardableResult mutating func consumeAccepted(ownerID: String, identityGeneration: Int,
                                                     revision: Int, sourceID: String?) -> Bool {
        guard matches(ownerID: ownerID, identityGeneration: identityGeneration),
              self.revision == revision, source?.id == sourceID, pending == nil else { return false }
        source = nil; revise(); return true
    }
}


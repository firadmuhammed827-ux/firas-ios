import Foundation

/// Exercises the production owner/revision controller; no picker or policy copy.
@main
struct MediaSourceSelectionTests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            guard condition() else { fatalError("Media source selection failed: \(label)") }
        }
        let image = MediaSourceImage(id: "image-a", dataURI: "data:image/jpeg;base64,AA==", thumbnailData: Data([1]))
        let replacement = MediaSourceImage(id: "image-b", dataURI: "data:image/jpeg;base64,AQ==", thumbnailData: Data([2]))
        var draft = MediaSourceDraftState()
        expect(draft.bind(ownerID: "owner-a", identityGeneration: 1), "first owner bind")
        expect(!draft.bind(ownerID: "owner-a", identityGeneration: 1), "identical bind retains state")
        expect(draft.matches(ownerID: "owner-a", identityGeneration: 1), "owned generation")

        draft.begin(ownerID: "owner-a", identityGeneration: 1, kind: .image)
        guard let first = draft.pending else { fatalError("image ticket missing") }
        expect(draft.accepts(first, kind: .image), "current image ticket accepted")
        expect(!draft.accepts(first, kind: .video), "image/video selection mismatch rejected")
        expect(!draft.accepts(first, kind: .music), "music cannot receive source")
        expect(draft.accept(first, kind: .image, asset: image), "source import committed")
        expect(draft.pending == nil && draft.source == image, "accepted ticket retired and source kept")
        expect(!draft.accept(first, kind: .image, asset: replacement), "duplicate callback cannot replace source")

        let beforeNewPicker = draft.revision
        draft.begin(ownerID: "owner-a", identityGeneration: 1, kind: .image)
        expect(!draft.consumeAccepted(ownerID: "owner-a", identityGeneration: 1,
            revision: beforeNewPicker, sourceID: image.id), "new source selection protects next draft during server acceptance")
        draft.retireImport()
        expect(draft.source == image, "cancelled new picker retains original selected image")

        let acceptedRevision = draft.revision
        draft.revise() // A typed edit, including editing away and back.
        expect(!draft.consumeAccepted(ownerID: "owner-a", identityGeneration: 1,
            revision: acceptedRevision, sourceID: image.id), "late server acceptance preserves edited next draft")
        expect(draft.source == image, "failed consumption keeps source")
        expect(!draft.consumeAccepted(ownerID: "owner-a", identityGeneration: 1,
            revision: draft.revision, sourceID: replacement.id), "changed source identity cannot be consumed")

        draft.begin(ownerID: "owner-a", identityGeneration: 1, kind: .video)
        guard let beforeEdit = draft.pending else { fatalError("video ticket missing") }
        draft.revise()
        expect(!draft.accept(beforeEdit, kind: .video, asset: replacement), "typing while import awaits retires callback")
        expect(draft.source == image, "editing preserves previous selected source")

        draft.begin(ownerID: "owner-a", identityGeneration: 1, kind: .image)
        guard let retired = draft.pending else { fatalError("old picker ticket missing") }
        draft.begin(ownerID: "owner-a", identityGeneration: 1, kind: .image)
        guard let newest = draft.pending else { fatalError("new picker ticket missing") }
        expect(retired.id != newest.id, "distinct picker presentation identity")
        expect(!draft.accept(retired, kind: .image, asset: replacement), "retired picker cannot attach to newest ticket")
        expect(draft.accepts(newest, kind: .image), "old callback leaves new import intact")
        draft.retireImport()
        expect(!draft.accept(newest, kind: .image, asset: replacement), "cancelled import cannot commit")
        expect(draft.source == image, "cancel preserves existing source")

        draft.begin(ownerID: "owner-a", identityGeneration: 1, kind: .image)
        guard let beforeAccount = draft.pending else { fatalError("owner ticket missing") }
        expect(draft.bind(ownerID: "owner-b", identityGeneration: 2), "account switch adopted")
        expect(draft.source == nil && draft.pending == nil, "account switch erases private source and ticket")
        expect(!draft.accept(beforeAccount, kind: .image, asset: image), "old owner's callback rejected")
        draft.bind(ownerID: "owner-a", identityGeneration: 3)
        expect(!draft.accept(beforeAccount, kind: .image, asset: image), "same-ID sign-out/sign-in ABA rejected")
        expect(!draft.consumeAccepted(ownerID: "owner-a", identityGeneration: 1,
            revision: draft.revision, sourceID: nil), "old identity epoch cannot clear a new brief")

        draft.begin(ownerID: "owner-a", identityGeneration: 3, kind: .video)
        guard let current = draft.pending else { fatalError("current video ticket missing") }
        expect(draft.accept(current, kind: .video, asset: replacement), "current video source accepted")
        let videoRevision = draft.revision
        expect(!draft.consumeAccepted(ownerID: "owner-b", identityGeneration: 3,
            revision: videoRevision, sourceID: replacement.id), "another owner cannot consume acceptance")
        expect(draft.consumeAccepted(ownerID: "owner-a", identityGeneration: 3,
            revision: videoRevision, sourceID: replacement.id), "unchanged accepted draft consumed once")
        expect(draft.source == nil && draft.pending == nil && draft.revision != videoRevision,
            "accepted draft retired after consumption")
        expect(!draft.consumeAccepted(ownerID: "owner-a", identityGeneration: 3,
            revision: videoRevision, sourceID: nil), "duplicate acceptance cannot clear following draft")

        draft.begin(ownerID: "owner-a", identityGeneration: 3, kind: .music)
        expect(draft.pending == nil, "music never issues source ticket")
        draft.begin(ownerID: "wrong-owner", identityGeneration: 3, kind: .image)
        expect(draft.pending == nil, "foreign owner cannot issue ticket")
        draft.begin(ownerID: "owner-a", identityGeneration: 2, kind: .image)
        expect(draft.pending == nil, "stale epoch cannot issue ticket")
        draft.begin(ownerID: "owner-a", identityGeneration: 3, kind: .image)
        guard let beforeRemove = draft.pending else { fatalError("remove ticket missing") }
        draft.removeSource()
        expect(!draft.accept(beforeRemove, kind: .image, asset: image), "removal fences in-flight replacement")
        let plainRevision = draft.revision
        expect(draft.consumeAccepted(ownerID: "owner-a", identityGeneration: 3,
            revision: plainRevision, sourceID: nil), "plain text creation consumes unchanged draft")
        draft.bind(ownerID: nil, identityGeneration: 4)
        expect(draft.source == nil && draft.pending == nil, "signed-out source erased")

        // Actual filesystem reads exercise the production byte-cap implementation.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("media-source-selection-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chosen-photo.bytes")
        let original = Data(repeating: 27, count: 130_123)
        try original.write(to: file)
        let read = try MediaSourceFileReader.read(at: file, maximumBytes: original.count)
        expect(read.count == original.count, "exact cap accepts an entire multichunk file")
        expect(read == original, "bounded file read preserves bytes without cutting")
        let short = try MediaSourceFileReader.read(at: file, maximumBytes: original.count + 1)
        expect(short == original, "EOF below cap is preserved")
        func rejected(_ url: URL, limit: Int) -> Bool {
            do { _ = try MediaSourceFileReader.read(at: url, maximumBytes: limit); return false }
            catch { return true }
        }
        func rejectedAsTooLarge(_ url: URL, limit: Int) -> Bool {
            do { _ = try MediaSourceFileReader.read(at: url, maximumBytes: limit); return false }
            catch MediaSourceFileError.tooLarge { return true }
            catch { return false }
        }
        expect(rejectedAsTooLarge(file, limit: original.count - 1), "over-cap original rejected before materialization")
        expect(rejected(folder.appendingPathComponent("missing.bytes"), limit: 10), "missing transfer file rejected")
        let empty = folder.appendingPathComponent("empty.bytes")
        try Data().write(to: empty)
        expect(rejected(empty, limit: 10), "empty photo rejected")
        expect(rejected(URL(string: "https://example.invalid/photo.png")!, limit: 10), "remote URL never opened")
        expect(rejected(file, limit: 20_000_001), "caller cannot exceed the source memory ceiling")
        expect(rejected(folder, limit: 10), "directory is not a transferable photo")
        expect(MediaSourcePixelPolicy.accepts(width: 4_000, height: 3_000), "ordinary photo fits local raster budget")
        expect(MediaSourcePixelPolicy.accepts(width: 8_064, height: 6_048), "genuine 48 MP photo fits local raster budget")
        expect(MediaSourcePixelPolicy.accepts(width: 5_000, height: 10_000), "exact pixel ceiling accepted")
        expect(!MediaSourcePixelPolicy.accepts(width: 5_001, height: 10_000), "over-ceiling image rejected before decode")
        expect(!MediaSourcePixelPolicy.accepts(width: 0, height: 10), "zero pixel dimension rejected")
        expect(!MediaSourcePixelPolicy.accepts(width: -1, height: 10), "negative metadata rejected")
        expect(!MediaSourcePixelPolicy.accepts(width: 12_001, height: 1), "extreme edge rejected")
        expect(!MediaSourcePixelPolicy.accepts(width: Int.max, height: Int.max), "overflowing raster dimensions rejected before multiply")
        print("Media source selection: \(checks) checks passed")
    }
}

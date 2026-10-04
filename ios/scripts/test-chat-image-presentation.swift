import Foundation

@main
struct ChatImagePresentationChecks {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            guard condition else { fatalError(message) }
        }

        var requests = PhotoThumbnailRequestState()
        let first = requests.reserve(assetID: "photo-a")
        expect(first.retiredRequestID == nil, "First request has nothing to cancel")
        expect(requests.accepts(first.ticket), "Inline callback is owned before the request ID returns")
        expect(requests.assetID == "photo-a", "Presentation belongs to the reserved asset")
        expect(requests.attach(17, to: first.ticket), "Attach the actual returned Photos request ID")
        expect(!requests.attach(99, to: first.ticket), "Duplicate attachment cannot replace the cancellable request")

        let replacement = requests.reserve(assetID: "photo-b")
        expect(replacement.retiredRequestID == 17, "Replacement returns the exact old ID for cancellation")
        expect(!requests.accepts(first.ticket), "Late previous-asset callback is rejected")
        expect(requests.accepts(replacement.ticket), "Replacement callback is accepted before numeric-ID assignment")
        expect(!requests.attach(18, to: first.ticket), "Late returned previous ID must be cancelled rather than attached")
        expect(requests.attach(27, to: replacement.ticket), "Replacement retains its own returned ID")
        expect(requests.retire(matching: first.ticket) == nil, "Old cleanup cannot cancel a newer request")
        expect(requests.accepts(replacement.ticket), "New ownership survives old cleanup")
        expect(requests.retire() == 27, "Disappear cancels the exact current ID")
        expect(!requests.accepts(replacement.ticket), "Disappear rejects subsequent callbacks")
        expect(requests.assetID == nil, "Disappear clears the display owner")
        expect(requests.retire() == nil, "Repeated cleanup cannot cancel another ID")

        let pending = requests.reserve(assetID: "photo-c")
        expect(requests.retire() == nil, "Disappear can precede numeric-ID return")
        expect(!requests.attach(37, to: pending.ticket), "An ID returned after disappearance must be cancelled")
        expect(!requests.accepts(pending.ticket), "Callback after early retirement is rejected")
        let retry = requests.reserve(assetID: "photo-c")
        expect(retry.ticket != pending.ticket, "Same-asset retry gets a distinct immutable lease")
        expect(!requests.accepts(pending.ticket), "Same-asset late callback cannot restore an earlier lease")
        expect(requests.attach(47, to: retry.ticket), "Same-asset new request can attach")
        expect(requests.retire(matching: retry.ticket) == 47, "Matching cancellation retires only its own request")

        let originals = ["full-a", "full-b"]
        let noThumbs = ChatImageSources.entries(thumbnails: nil, images: originals)
        expect(noThumbs.map(\.thumbnail) == originals, "Images-only source rows remain visible")
        expect(noThumbs.map(\.fullSize) == originals, "Images-only previews use their original sources")
        expect(ChatImageSources.entries(thumbnails: [], images: originals) == noThumbs, "Empty thumbnails also fall back")
        expect(ChatImageSources.entries(thumbnails: nil, images: nil).isEmpty, "No images produces no fake rows")
        let supplied = ChatImageSources.entries(thumbnails: ["bad-thumb", "thumb-b"], images: originals)
        expect(supplied.map(\.thumbnail) == ["bad-thumb", "thumb-b"], "Nonempty thumbnails remain the display sources")
        let decoded = supplied.filter { $0.thumbnail != "bad-thumb" }
        expect(decoded.first?.id == 1 && decoded.first?.fullSize == "full-b", "Skipping a failed decode never shifts the full-source mapping")
        let short = ChatImageSources.entries(thumbnails: ["thumb-a", "thumb-b"], images: ["full-a"])
        expect(short[1].fullSize == "thumb-b", "Missing full source uses its own thumbnail")
        expect(ChatImageSources.entries(thumbnails: ["thumb"], images: [""])[0].fullSize == "thumb", "Empty full source does not replace a valid thumbnail")
        let many = (0..<15).map { "image-\($0)" }
        let bounded = ChatImageSources.entries(thumbnails: nil, images: many)
        expect(bounded.count == 10 && bounded.last?.id == 9, "Decode admission stays bounded to ten original positions")
        let bytes = Data([0, 1, 2, 3, 254, 255])
        expect(ChatImageSources.bytes(from: bytes.base64EncodedString()) == bytes, "Legacy raw base64 still decodes")
        expect(ChatImageSources.bytes(from: "data:image/png;base64," + bytes.base64EncodedString()) == bytes, "Data URI preserves the actual encoded bytes")
        expect(ChatImageSources.bytes(from: "not valid base64") == nil, "Malformed sources do not produce fake image bytes")
        expect(ChatImageSources.bytes(from: String(repeating: "A", count: ChatImageSources.maximumEncodedBytes + 1)) == nil, "Oversized encoded source is rejected before Data decode")
        print("Chat image presentation: \(checks) checks passed")
    }
}

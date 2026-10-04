import Foundation

@main enum MediaWireTests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); checks += 1
        }
        func object<T: Encodable>(_ value: T) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        }
        let image = try object(MediaImageJobRequest(prompt: "صورة", w: 1024, h: 1280,
            cid: "media-turn-a", chatId: "chat-a", tier: "max", lang: "ar"))
        expect(Set(image.keys) == ["prompt", "w", "h", "cid", "chatId", "tier", "lang"], "image emits the shipping binding schema")
        let video = try object(MediaVideoJobRequest(prompt: "video", seconds: 10,
            cid: "media-turn-v", chatId: "chat-a", tier: "mini", lang: "en"))
        expect(Set(video.keys) == ["prompt", "seconds", "cid", "chatId", "tier", "lang"], "video emits the shipping binding schema")
        let music = try object(MediaMusicJobRequest(prompt: "music", lyrics: "lyrics", seconds: 90,
            cid: "media-turn-m", chatId: "chat-a", tier: "pro", lang: "en"))
        expect(Set(music.keys) == ["prompt", "lyrics", "seconds", "cid", "chatId", "tier", "lang"], "music emits the shipping binding schema")
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("fixtures/native-media-wire.json")
        let shared = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: [String: Any]]
        for (kind, request) in [("image", image), ("video", video), ("music", music)] {
            expect(NSDictionary(dictionary: request).isEqual(to: shared[kind]!), "real Swift encoding equals the body executed against the durable server module")
        }
        for request in [image, video, music] {
            expect(request["chatId"] as? String == "chat-a", "all media kinds share the chosen Chat")
            expect(request["cid"] as? String != nil, "every render carries its persisted assistant CID")
            expect(request["mgen"] == nil, "media engines do not inherit an invented text-model generation")
        }
        let unknown = try JSONDecoder().decode(MediaJobStatusResponse.self,
            from: Data(#"{"ok":true,"jobId":"","cid":"media-turn-a","phase":"unknown"}"#.utf8))
        expect(unknown.phase == "unknown" && unknown.jobId == "", "unknown receipts decode without an asset or replay instruction")
        let done = try JSONDecoder().decode(MediaJobStatusResponse.self,
            from: Data(#"{"ok":true,"jobId":"key","cid":"media-turn-a","chatId":"chat-a","phase":"done","key":"key"}"#.utf8))
        expect(done.cid == "media-turn-a" && done.chatId == "chat-a" && done.key == "key", "terminal receipt preserves its binding")
        expect(MediaRequestPolicy.validationProblem(kind: .image, prompt: "صورة") == nil, "Arabic brief remains supported")
        expect(MediaRequestPolicy.validationProblem(kind: .image, prompt: String(repeating: "🧑🏽‍🔬", count: 200)) == "media_brief_too_large",
               "oversized graphemes are rejected as a complete brief rather than split or removed")
        let old = MediaCreation(ownerID: "owner-a", kind: .image, prompt: "old")
        var oldJSON = try object(old)
        for key in ["cid", "chatID", "tier", "languageCode", "startAttempted"] { oldJSON.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(MediaCreation.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        expect(restored.prompt == "old" && restored.startAttempted == nil && restored.cid == nil, "pre-binding history remains readable without dispatch permission")
        for kind in MediaStudioKind.allCases {
            let uncertain = MediaCreation(ownerID: "owner-a", kind: kind, prompt: "unconfirmed",
                phase: .failed, errorCode: "\(kind.rawValue)_submission_uncertain")
            expect(!uncertain.canRetry, "uncertain provider result does not advertise a fresh paid Retry")
        }
        expect(!MediaCreation(ownerID: "owner-a", kind: .image, prompt: "mismatch", phase: .failed,
            errorCode: "media_receipt_mismatch").canRetry, "contradictory receipt provenance cannot authorize Retry")
        expect(!MediaCreation(ownerID: "owner-a", kind: .image, prompt: "rejected", phase: .failed,
            errorCode: "daily_limit").canRetry, "a history receipt never substitutes for a fresh explicit brief")
        let source = "data:image/jpeg;base64," + Data([255, 216, 255] + Array(repeating: UInt8(0), count: 16)).base64EncodedString()
        let edited = try object(MediaImageJobRequest(prompt: "edit", w: 1024, h: 1024,
            cid: "media-turn-a", chatId: "chat-a", tier: "max", lang: "ar", image: source))
        let animated = try object(MediaVideoJobRequest(prompt: "animate", seconds: 10,
            cid: "media-turn-v", chatId: "chat-a", tier: "mini", lang: "en", image: source))
        expect(edited["image"] as? String == source && animated["image"] as? String == source,
               "image edit and image-to-video encode the actual optional source field")
        expect(MediaRequestPolicy.validationProblem(kind: .image, prompt: String(repeating: "😀", count: 501)) == "media_brief_too_large",
               "UTF16 server budget rejects an oversized complete brief rather than truncating it")
        expect(MediaRequestPolicy.validationProblem(kind: .video, prompt: "animate", seconds: 31) == "media_duration_invalid",
               "unsupported duration is rejected rather than silently changed")
        expect(MediaRequestPolicy.validationProblem(kind: .image, prompt: "edit", sourceImage: source) == nil,
               "canonical bounded JPEG source is supported")
        expect(MediaRequestPolicy.validationProblem(kind: .image, prompt: "edit", sourceImage: source.replacingOccurrences(of: "jpeg", with: "png")) == "media_source_invalid",
               "a source declaration must match its actual bytes")
        expect(MediaRequestPolicy.validationProblem(kind: .music, prompt: "music", seconds: 90, sourceImage: source) == "media_source_invalid",
               "music never drops an unsupported source silently")
        expect(MediaJobPhase.stopping.isActive && MediaJobPhase.stopped.isTerminal, "Stop remains pending until confirmed terminal state")
        let key = String(repeating: "a", count: 64)
        let receiptURL = fixtureURL.deletingLastPathComponent().appendingPathComponent("media-receipt-keys.json")
        let samples = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as! [[String: String]]
        for sample in samples {
            expect(MediaRequestPolicy.receiptKey(kind: MediaStudioKind(rawValue: sample["kind"]!)!,
                ownerID: sample["ownerID"]!, cid: sample["cid"]!) == sample["key"],
                "Swift receipt provenance must equal the actual shared server helper")
        }
        for kind in MediaStudioKind.allCases {
            expect(MediaRequestPolicy.cancellationID(kind: kind, key: key) == kind.rawValue + "_" + key,
                   "Stop uses the actual server control prefix")
            expect(MediaRequestPolicy.cancellationID(kind: kind, key: String(repeating: "a", count: 40)) == nil,
                   "legacy assets cannot invent a modern cancellation identifier")
        }
        expect(!MediaRequestPolicy.validKey("../asset") && !MediaRequestPolicy.validKey(String(repeating: "A", count: 64)),
               "cache routes accept only real lowercase receipt keys")
        let png = Data([137,80,78,71,13,10,26,10] + Array(repeating: UInt8(0), count: 16))
        expect(MediaAssetPolicy.inspect(kind: .image, key: key, mimeType: "image/png", prefix: png, totalBytes: Int64(png.count))?.fileExtension == "png",
               "bounded actual image container prefix is recognized")
        expect(MediaAssetPolicy.inspect(kind: .video, key: key, mimeType: "video/mp4", prefix: png, totalBytes: Int64(png.count)) == nil,
               "an image cannot masquerade as a video")
        expect(MediaAssetPolicy.inspect(kind: .image, key: key, mimeType: "text/html", prefix: png, totalBytes: Int64(png.count)) == nil,
               "HTML or error content cannot become a media preview")
        expect(MediaAssetPolicy.inspect(kind: .image, key: key, mimeType: "image/png", prefix: png, totalBytes: 25_000_001) == nil,
               "file ceiling is independent of the prefix")
        print("PASS: \(checks) production media wire/history checks")
    }
}

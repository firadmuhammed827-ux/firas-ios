import Foundation
import CryptoKit

nonisolated enum MediaStudioKind: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case image
    case video
    case music

    var id: String { rawValue }
}

nonisolated struct MediaPresentationRequest: Equatable, Sendable {
    let kind: MediaStudioKind
    let focusedJobID: String?

    init(kind: MediaStudioKind, focusedJobID: String? = nil) {
        self.kind = kind
        self.focusedJobID = focusedJobID
    }
}

nonisolated enum MediaJobPhase: String, Codable, Equatable, Sendable {
    case preparing
    case queued
    case running
    case stopping
    case stopped
    case completed
    case failed

    var isActive: Bool {
        self == .preparing || self == .queued || self == .running || self == .stopping
    }

    var isTerminal: Bool { self == .completed || self == .failed || self == .stopped }
}

nonisolated enum ImageAspectPreset: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case square
    case portrait
    case landscape
    case story
    case banner
    case cover

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .square: 1_024
        case .portrait: 1_024
        case .landscape: 1_280
        case .story: 720
        case .banner: 1_280
        case .cover: 1_280
        }
    }

    var height: Int {
        switch self {
        case .square: 1_024
        case .portrait: 1_280
        case .landscape: 720
        case .story: 1_280
        case .banner: 640
        case .cover: 853
        }
    }

    var ratio: Double { Double(width) / Double(height) }
}

nonisolated struct MediaImageJobRequest: Encodable, Equatable, Sendable {
    let prompt: String
    let w: Int
    let h: Int
    let cid: String
    let chatId: String
    let tier: String
    let lang: String
    var image: String? = nil
}

nonisolated struct MediaVideoJobRequest: Encodable, Equatable, Sendable {
    let prompt: String
    let seconds: Int
    let cid: String
    let chatId: String
    let tier: String
    let lang: String
    var image: String? = nil
}

nonisolated struct MediaMusicJobRequest: Encodable, Equatable, Sendable {
    let prompt: String
    let lyrics: String
    let seconds: Int
    let cid: String
    let chatId: String
    let tier: String
    let lang: String
}

/// The server accepts a media job only after this assistant CID is persisted
/// in an ordinary Chat owned by the same account.
nonisolated struct MediaTurnBinding: Equatable, Sendable {
    let ownerID: String
    let chatID: String
    let cid: String
}

nonisolated struct MediaJobStartResponse: Decodable, Equatable, Sendable {
    let ok: Bool?
    let jobId: String
    let phase: String?
    let key: String?
    var cid: String? = nil
    var chatId: String? = nil
    var error: String? = nil
}

nonisolated struct MediaJobStatusResponse: Decodable, Equatable, Sendable {
    let phase: String
    let key: String?
    let error: String?
    let reason: String?
    let jobId: String?
    let cid: String?
    let chatId: String?
    var ok: Bool? = nil

    var resolvedError: String? { error ?? reason }
}

nonisolated struct MediaCreation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let ownerID: String
    let kind: MediaStudioKind
    let prompt: String
    let lyrics: String?
    let aspect: ImageAspectPreset?
    let seconds: Int?
    let createdAt: Date
    var updatedAt: Date
    var phase: MediaJobPhase
    var jobID: String?
    var resultKey: String?
    var localFileURL: URL?
    var errorCode: String?
    // Optional fields keep older local history readable. Missing dispatch
    // metadata never grants permission to submit a render again.
    var cid: String?
    var chatID: String?
    var tier: String?
    var languageCode: String?
    var startAttempted: Bool?
    var stopRequested: Bool?
    var sourceWasProvided: Bool?

    var canRetry: Bool {
        // A receipt is not a replayable draft. A fresh render requires an
        // explicit new brief in the composer, including any source image.
        false
    }

    init(
        id: UUID = UUID(),
        ownerID: String,
        kind: MediaStudioKind,
        prompt: String,
        lyrics: String? = nil,
        aspect: ImageAspectPreset? = nil,
        seconds: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        phase: MediaJobPhase = .preparing,
        jobID: String? = nil,
        resultKey: String? = nil,
        localFileURL: URL? = nil,
        errorCode: String? = nil,
        cid: String? = nil,
        chatID: String? = nil,
        tier: String? = nil,
        languageCode: String? = nil,
        startAttempted: Bool? = nil,
        stopRequested: Bool? = nil,
        sourceWasProvided: Bool? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.kind = kind
        self.prompt = prompt
        self.lyrics = lyrics
        self.aspect = aspect
        self.seconds = seconds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.phase = phase
        self.jobID = jobID
        self.resultKey = resultKey
        self.localFileURL = localFileURL
        self.errorCode = errorCode
        self.cid = cid
        self.chatID = chatID
        self.tier = tier
        self.languageCode = languageCode
        self.startAttempted = startAttempted
        self.stopRequested = stopRequested
        self.sourceWasProvided = sourceWasProvided
    }
}

nonisolated struct MediaAssetFileDownload: Equatable, Sendable {
    let fileURL: URL
    let mimeType: String
    let suggestedFilename: String
}

nonisolated struct MediaAssetMetadata: Equatable, Sendable {
    let mimeType: String
    let fileExtension: String
}

nonisolated enum MediaRequestPolicy {
    static func promptLimit(_ kind: MediaStudioKind) -> Int { kind == .image ? 1_000 : 2_000 }

    static func validKey(_ value: String) -> Bool {
        (value.utf8.count == 40 || value.utf8.count == 64) &&
            value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func cancellationID(kind: MediaStudioKind, key: String) -> String? {
        guard key.utf8.count == 64, validKey(key) else { return nil }
        return kind.rawValue + "_" + key
    }

    static func receiptKey(kind: MediaStudioKind, ownerID: String, cid: String) -> String? {
        guard !ownerID.isEmpty, (1...64).contains(cid.utf8.count), cid.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        let parts = kind == .image ? ["firas-image-v1", ownerID, cid]
            : ["firas-av-v1", kind.rawValue, ownerID, cid]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(parts) else { return nil }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Reports the actual server budget; never silently removes a person's brief.
    static func validationProblem(kind: MediaStudioKind, prompt: String, lyrics: String = "",
                                  seconds: Int? = nil, sourceImage: String? = nil) -> String? {
        if prompt.utf16.count > promptLimit(kind) || lyrics.utf16.count > 6_000 { return "media_brief_too_large" }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (kind != .music || lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { return "media_brief_empty" }
        if kind == .video && !(2...30).contains(seconds ?? 0) ||
            kind == .music && !(10...600).contains(seconds ?? 0) { return "media_duration_invalid" }
        guard let sourceImage else { return nil }
        if kind == .music { return "media_source_invalid" }
        let maximum = kind == .image ? 20_000_000 : 10_000_000
        if sourceImage.utf8.count > ((maximum + 2) / 3) * 4 + 100 { return "media_source_too_large" }
        guard let comma = sourceImage.firstIndex(of: ",") else { return "media_source_invalid" }
        let header = String(sourceImage[..<comma])
        let allowed = ["data:image/png;base64": "image/png", "data:image/jpeg;base64": "image/jpeg",
                       "data:image/webp;base64": "image/webp"]
        guard let mime = allowed[header] else { return "media_source_invalid" }
        let encoded = String(sourceImage[sourceImage.index(after: comma)...])
        guard let bytes = Data(base64Encoded: encoded), bytes.count > 12 else { return "media_source_invalid" }
        if bytes.count > maximum { return "media_source_too_large" }
        guard bytes.base64EncodedString() == encoded,
              MediaAssetPolicy.inspect(kind: .image, key: String(repeating: "a", count: 64),
                  mimeType: mime, prefix: bytes.prefix(512), totalBytes: Int64(bytes.count)) != nil
        else { return "media_source_invalid" }
        return nil
    }
}

/// Container/length screening, not a claim that a provider's codec is playable.
/// Reads at most 512 prefix bytes; transport enforces these ceilings while writing.
nonisolated enum MediaAssetPolicy {
    static func route(_ kind: MediaStudioKind) -> (path: String, queryName: String) {
        switch kind {
        case .image: ("/api/image", "key")
        case .video: ("/api/video/file", "id")
        case .music: ("/api/music/file", "id")
        }
    }

    static func maximumBytes(_ kind: MediaStudioKind) -> Int64 {
        switch kind { case .image: 25_000_000; case .video: 200_000_000; case .music: 30_000_000 }
    }

    static func inspect(kind: MediaStudioKind, key: String, mimeType: String?, prefix: Data,
                        totalBytes: Int64) -> MediaAssetMetadata? {
        guard MediaRequestPolicy.validKey(key), totalBytes > 0, totalBytes <= maximumBytes(kind),
              !prefix.isEmpty, prefix.count <= 512, Int64(prefix.count) <= totalBytes else { return nil }
        let bytes = [UInt8](prefix)
        func matches(_ offset: Int, _ signature: [UInt8]) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<(offset + signature.count)]) == signature
        }
        func ascii(_ offset: Int, _ text: String) -> Bool { matches(offset, Array(text.utf8)) }
        func u32(_ offset: Int) -> Int64 { (0..<4).reduce(0) { ($0 << 8) | Int64(bytes[offset + $1]) } }
        let png = matches(0, [137, 80, 78, 71, 13, 10, 26, 10])
        let jpeg = matches(0, [255, 216, 255])
        let webp = ascii(0, "RIFF") && ascii(8, "WEBP")
        let gif = ascii(0, "GIF87a") || ascii(0, "GIF89a")
        let wav = ascii(0, "RIFF") && ascii(8, "WAVE")
        let webm = matches(0, [26, 69, 223, 163])
        let ogg = ascii(0, "OggS"), flac = ascii(0, "fLaC")
        var mp4 = false
        if bytes.count >= 16, ascii(4, "ftyp") {
            let size = u32(0)
            mp4 = size == 1 ? bytes.count >= 24 && u32(8) == 0 && (24...totalBytes).contains(u32(12))
                : (16...totalBytes).contains(size)
        }
        let id3 = bytes.count >= 10 && ascii(0, "ID3") && (2...4).contains(bytes[3]) &&
            bytes[6...9].allSatisfy { $0 & 128 == 0 }
        var mpeg = id3, aac = false
        if bytes.count >= 4, bytes[0] == 255 {
            let second = bytes[1], third = bytes[2]
            aac = second & 0xf6 == 0xf0 && (third >> 2) & 15 <= 12
            mpeg = mpeg || second & 0xe0 == 0xe0 && (second >> 3) & 3 != 1 &&
                (second >> 1) & 3 != 0 && (1...14).contains(third >> 4) && (third >> 2) & 3 != 3
        }
        let metadata: MediaAssetMetadata
        switch kind {
        case .image:
            if png { metadata = .init(mimeType: "image/png", fileExtension: "png") }
            else if jpeg { metadata = .init(mimeType: "image/jpeg", fileExtension: "jpg") }
            else if webp { metadata = .init(mimeType: "image/webp", fileExtension: "webp") }
            else if gif { metadata = .init(mimeType: "image/gif", fileExtension: "gif") }
            else { return nil }
        case .video:
            if mp4 { metadata = .init(mimeType: "video/mp4", fileExtension: "mp4") }
            else if webm { metadata = .init(mimeType: "video/webm", fileExtension: "webm") }
            else { return nil }
        case .music:
            if mpeg { metadata = .init(mimeType: "audio/mpeg", fileExtension: "mp3") }
            else if wav { metadata = .init(mimeType: "audio/wav", fileExtension: "wav") }
            else if ogg { metadata = .init(mimeType: "audio/ogg", fileExtension: "ogg") }
            else if flac { metadata = .init(mimeType: "audio/flac", fileExtension: "flac") }
            else if mp4 { metadata = .init(mimeType: "audio/mp4", fileExtension: "m4a") }
            else if aac { metadata = .init(mimeType: "audio/aac", fileExtension: "aac") }
            else { return nil }
        }
        var declared = mimeType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if declared == "image/jpg" { declared = "image/jpeg" }
        if declared == "audio/mp3" { declared = "audio/mpeg" }
        if ["audio/x-wav", "audio/wave"].contains(declared) { declared = "audio/wav" }
        guard declared.isEmpty || declared == "application/octet-stream" || declared == metadata.mimeType else { return nil }
        return metadata
    }
}

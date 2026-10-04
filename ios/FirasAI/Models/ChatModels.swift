import Foundation

nonisolated struct DraftImageAsset: Identifiable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let jpegData: Data
}

nonisolated struct DraftFileAsset: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: String
    let text: String
    let wasTruncated: Bool
}

nonisolated struct PreparedChatContext: Equatable, Sendable {
    let fullImages: [String]
    let imageThumbnails: [String]
    let files: [ChatAttachment]
    let fileText: String?

    var isEmpty: Bool {
        fullImages.isEmpty && files.isEmpty
    }
}

nonisolated struct DraftContextSelection: Equatable, Sendable {
    var recentPhotoIDs: Set<String> = []
    var pickerPhotoIDs: [String] = []
    var cameraPhotoCount = 0
    var fileNames: [String] = []
    var images: [DraftImageAsset] = []
    var files: [DraftFileAsset] = []
    var processingItemIDs: Set<String> = []

    var itemCount: Int {
        recentPhotoIDs.count + pickerPhotoIDs.count + cameraPhotoCount + fileNames.count
    }

    var isEmpty: Bool { itemCount == 0 }
    var isProcessing: Bool { !processingItemIDs.isEmpty }
    var hasReadyContent: Bool { !images.isEmpty || !files.isEmpty }

    mutating func clear() {
        recentPhotoIDs.removeAll()
        pickerPhotoIDs.removeAll()
        cameraPhotoCount = 0
        fileNames.removeAll()
        images.removeAll()
        files.removeAll()
        processingItemIDs.removeAll()
    }

    mutating func toggleRecentPhoto(_ identifier: String) {
        if recentPhotoIDs.contains(identifier) {
            recentPhotoIDs.remove(identifier)
        } else {
            recentPhotoIDs.insert(identifier)
        }
    }
}


nonisolated enum ChatRole: String, Codable, Equatable, Sendable {
    case system
    case user
    case assistant
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = ChatRole(rawValue: value) ?? .unknown
    }
}

nonisolated enum ChatMessageState: String, Codable, Equatable, Sendable {
    case sending
    case delivered
    case failed
    case stopped
}

nonisolated struct ChatAttachment: Codable, Equatable, Sendable {
    let name: String
    let kind: String?

    init(name: String, kind: String? = nil) {
        self.name = name
        self.kind = kind
    }
}

nonisolated struct RetryReference: Codable, Equatable, Sendable {
    let cid: String
    let tier: String
    private(set) var mgen: String?

    var modelGeneration: ModelGeneration { .historyValue(mgen) }

    init(cid: String, tier: String, generation: ModelGeneration = .legacy) {
        self.cid = cid
        self.tier = tier
        mgen = generation.wireValue
    }

    private enum CodingKeys: String, CodingKey { case cid, tier, mgen }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cid = try container.decode(String.self, forKey: .cid)
        tier = try container.decode(String.self, forKey: .tier)
        mgen = ModelGeneration.historyValue(
            try container.decodeIfPresent(String.self, forKey: .mgen)
        ).wireValue
    }
}

nonisolated struct AnswerVersion: Codable, Equatable, Sendable {
    let content: String
    let reasoning: String?
    let tier: String?
    let lang: String?
    private(set) var mgen: String?

    var modelGeneration: ModelGeneration { .historyValue(mgen) }

    init(
        content: String,
        reasoning: String?,
        tier: String?,
        lang: String?,
        generation: ModelGeneration = .legacy
    ) {
        self.content = content
        self.reasoning = reasoning
        self.tier = tier
        self.lang = lang
        mgen = generation.wireValue
    }

    private enum CodingKeys: String, CodingKey { case content, reasoning, tier, lang, mgen }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(String.self, forKey: .content)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        tier = try container.decodeIfPresent(String.self, forKey: .tier)
        lang = try container.decodeIfPresent(String.self, forKey: .lang)
        mgen = ModelGeneration.historyValue(
            try container.decodeIfPresent(String.self, forKey: .mgen)
        ).wireValue
    }
}

/// Bounded forward-compatible server metadata. Known message fields retain
/// their typed representation; local SwiftUI identity/state never enter wire.
nonisolated enum ChatJSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([ChatJSONValue]), object([String: ChatJSONValue])

    init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 16 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Metadata nesting limit"))
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self), value.utf8.count <= 131_072 { self = .string(value) }
        else if let value = try? container.decode([ChatJSONValue].self), value.count <= 512 { self = .array(value) }
        else if let value = try? container.decode([String: ChatJSONValue].self), value.count <= 128 { self = .object(value) }
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported or oversized metadata")) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    func boundedWeight(upTo limit: Int) -> Int? {
        var total: Int
        switch self {
        case .null, .bool: total = 1
        case .integer, .number: total = 8
        case .string(let value): total = value.utf8.count + 1
        case .array(let values):
            total = 1
            for value in values {
                guard let weight = value.boundedWeight(upTo: limit - total) else { return nil }
                total += weight
                if total > limit { return nil }
            }
        case .object(let values):
            total = 1
            for (key, value) in values {
                total += key.utf8.count + 1
                guard total <= limit, let weight = value.boundedWeight(upTo: limit - total) else { return nil }
                total += weight
            }
        }
        return total <= limit ? total : nil
    }
}

private nonisolated struct ChatRawCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

nonisolated struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var role: ChatRole
    var content: String
    var tier: String?
    private(set) var mgen: String?
    var modelGeneration: ModelGeneration {
        get { .historyValue(mgen) }
        set { mgen = newValue.wireValue }
    }
    var lang: String?
    var files: [ChatAttachment]?
    var askAnswered: Bool?
    var cid: String?
    var retryOf: RetryReference?
    var retried: Bool?
    var mode: String?
    var mergedFrom: String?
    var reasoning: String?
    var images: [String]?
    var imageThumbs: [String]?
    var fileText: String?
    var alts: [AnswerVersion]?
    var altAt: Int?
    var state: ChatMessageState
    private(set) var unknownFields: [String: ChatJSONValue]

    init(
        id: String = UUID().uuidString,
        role: ChatRole,
        content: String,
        tier: String? = nil,
        generation: ModelGeneration = .legacy,
        lang: String? = nil,
        files: [ChatAttachment]? = nil,
        askAnswered: Bool? = nil,
        cid: String? = nil,
        retryOf: RetryReference? = nil,
        retried: Bool? = nil,
        mode: String? = nil,
        mergedFrom: String? = nil,
        reasoning: String? = nil,
        images: [String]? = nil,
        imageThumbs: [String]? = nil,
        fileText: String? = nil,
        alts: [AnswerVersion]? = nil,
        altAt: Int? = nil,
        state: ChatMessageState = .delivered,
        unknownFields: [String: ChatJSONValue] = [:]
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.tier = tier
        mgen = generation.wireValue
        self.lang = lang
        self.files = files
        self.askAnswered = askAnswered
        self.cid = cid
        self.retryOf = retryOf
        self.retried = retried
        self.mode = mode
        self.mergedFrom = mergedFrom
        self.reasoning = reasoning
        self.images = images
        self.imageThumbs = imageThumbs
        self.fileText = fileText
        self.alts = alts
        self.altAt = altAt
        self.state = state
        self.unknownFields = unknownFields
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case role
        case content
        case tier
        case mgen
        case lang
        case files
        case askAnswered
        case cid
        case retryOf
        case retried
        case mode
        case mergedFrom
        case reasoning
        case images
        case imageThumbs
        case fileText
        case alts
        case altAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRole = try container.decodeIfPresent(ChatRole.self, forKey: .role) ?? .user
        role = decodedRole
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        tier = try container.decodeIfPresent(String.self, forKey: .tier)
        mgen = ModelGeneration.historyValue(
            try container.decodeIfPresent(String.self, forKey: .mgen)
        ).wireValue
        lang = try container.decodeIfPresent(String.self, forKey: .lang)
        files = try container.decodeIfPresent([ChatAttachment].self, forKey: .files)
        askAnswered = try container.decodeIfPresent(Bool.self, forKey: .askAnswered)
        let decodedCID = try container.decodeIfPresent(String.self, forKey: .cid)
        cid = decodedCID
        retryOf = try container.decodeIfPresent(RetryReference.self, forKey: .retryOf)
        retried = try container.decodeIfPresent(Bool.self, forKey: .retried)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        mergedFrom = try container.decodeIfPresent(String.self, forKey: .mergedFrom)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        images = try container.decodeIfPresent([String].self, forKey: .images)
        imageThumbs = try container.decodeIfPresent([String].self, forKey: .imageThumbs)
        fileText = try container.decodeIfPresent(String.self, forKey: .fileText)
        alts = try container.decodeIfPresent([AnswerVersion].self, forKey: .alts)
        altAt = try container.decodeIfPresent(Int.self, forKey: .altAt)
        // A persisted turn may use the same cid for its user and assistant
        // halves. Include the role so SwiftUI never receives duplicate row
        // identities after a conversation is decoded again.
        id = decodedCID.map { "message-\(decodedRole.rawValue)-\($0)" } ?? UUID().uuidString
        state = .delivered
        let raw = try decoder.container(keyedBy: ChatRawCodingKey.self)
        let excluded = Set(CodingKeys.allCases.map(\.rawValue)).union(["id", "state"])
        var extra: [String: ChatJSONValue] = [:]
        var remaining = 131_072
        for key in raw.allKeys where !excluded.contains(key.stringValue) {
            guard extra.count < 64,
                  let value = try? raw.decode(ChatJSONValue.self, forKey: key),
                  let weight = value.boundedWeight(upTo: remaining - key.stringValue.utf8.count) else { continue }
            remaining -= weight + key.stringValue.utf8.count
            extra[key.stringValue] = value
        }
        unknownFields = extra
    }

    func encode(to encoder: Encoder) throws {
        var raw = encoder.container(keyedBy: ChatRawCodingKey.self)
        let excluded = Set(CodingKeys.allCases.map(\.rawValue)).union(["id", "state"])
        var remaining = 131_072
        var count = 0
        for (name, value) in unknownFields where !excluded.contains(name) {
            guard count < 64, let key = ChatRawCodingKey(stringValue: name),
                  let weight = value.boundedWeight(upTo: remaining - name.utf8.count) else { continue }
            try raw.encode(value, forKey: key)
            remaining -= weight + name.utf8.count
            count += 1
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(tier, forKey: .tier)
        try container.encodeIfPresent(mgen, forKey: .mgen)
        try container.encodeIfPresent(lang, forKey: .lang)
        try container.encodeIfPresent(files, forKey: .files)
        try container.encodeIfPresent(askAnswered, forKey: .askAnswered)
        try container.encodeIfPresent(cid, forKey: .cid)
        try container.encodeIfPresent(retryOf, forKey: .retryOf)
        try container.encodeIfPresent(retried, forKey: .retried)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encodeIfPresent(mergedFrom, forKey: .mergedFrom)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(images, forKey: .images)
        try container.encodeIfPresent(imageThumbs, forKey: .imageThumbs)
        try container.encodeIfPresent(fileText, forKey: .fileText)
        try container.encodeIfPresent(alts, forKey: .alts)
        try container.encodeIfPresent(altAt, forKey: .altAt)
    }
}

nonisolated struct ChatSummary: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    let updatedAt: String
    let pinned: Bool
    let agent: Bool
    let codeProj: Bool
    let brainNb: Bool
}

nonisolated struct ChatConversation: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var messages: [ChatMessage]
    var agent: Bool? = nil
    var codeProj: Bool? = nil
    var brainNb: Bool? = nil
}

nonisolated struct CreateChatRequest: Encodable, Equatable, Sendable {
    let clientId: String
    let title: String
    let messages: [ChatMessage]
    let pinned: Bool
    let agent: Bool
    let codeProj: Bool
    let brainNb: Bool
}

nonisolated struct CreateChatResponse: Decodable, Equatable, Sendable {
    let id: String
    let title: String
    let createdAt: String
    let updatedAt: String
}

nonisolated struct UpdateChatRequest: Encodable, Equatable, Sendable {
    let title: String?
    let messages: [ChatMessage]?
    let pinned: Bool?
}

nonisolated enum ChatJobKind: String, Codable, Equatable, Sendable {
    case chat
    case longDocument = "longdoc"
    case longFile = "longfile"
    case codeBuild = "codebuild"
    case brainAsk = "brainask"
}

nonisolated enum ChatJobPhase: String, Codable, Equatable, Sendable {
    case queued
    case processing
    case completed
    case done
    case failed
    case fail
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = ChatJobPhase(rawValue: value) ?? .unknown
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .done, .failed, .fail:
            true
        case .queued, .processing, .unknown:
            false
        }
    }

    var succeeded: Bool { self == .completed || self == .done }
}

nonisolated struct ChatSendReceipt: Equatable, Sendable {
    let ownerID: String
    let cid: String
    let skillIDs: [String]
}

nonisolated struct ChatJobRequest: Encodable, Equatable, Sendable {
    let messages: [ChatMessage]
    let tier: String
    let mgen: String?
    let skillIds: [String]?
    let think: Bool
    let cid: String
    let product: ProductKind
    let chatId: String
    let kind: ChatJobKind?
    let lang: String?
    let nokb: Bool?
    let task: String?
    let title: String?
    let name: String?
    let attach: String?
    let format: String?
    let pages: Int?
    let targetPages: Int?
    let prompt: String?
    let sections: Int?

    init(
        messages: [ChatMessage],
        tier: ModelTier,
        generation: ModelGeneration = .legacy,
        thinking: Bool,
        cid: String,
        product: ProductKind,
        chatId: String = "",
        kind: ChatJobKind? = nil,
        languageCode: String? = nil,
        nokb: Bool? = nil,
        task: String? = nil,
        title: String? = nil,
        name: String? = nil,
        attach: String? = nil,
        format: String? = nil,
        pages: Int? = nil,
        targetPages: Int? = nil,
        prompt: String? = nil,
        sections: Int? = nil,
        skillIDs: [String] = []
    ) {
        self.messages = messages
        self.tier = tier.rawValue
        mgen = generation.wireValue
        think = thinking
        self.cid = cid
        self.product = product
        self.chatId = chatId
        self.kind = kind
        lang = languageCode
        self.nokb = nokb
        self.task = task
        self.title = title
        self.name = name
        self.attach = attach
        self.format = format
        self.pages = pages
        self.targetPages = targetPages
        self.prompt = prompt
        self.sections = sections
        skillIds = skillIDs.isEmpty ? nil : Array(skillIDs.prefix(3))
    }
}

nonisolated struct ChatJobProgress: Decodable, Equatable, Sendable {
    let stage: String?
    let pagesDone: Int?
    let pagesTotal: Int?
    let targetPages: Int?
    let bodyPagesDone: Int?
    let bodyPagesTotal: Int?
    let coverPages: Int?
    let currentPage: Int?
    let currentTitle: String?
    let partsDone: Int?
    let partsTotal: Int?
    let percent: Double?
    let resumeAvailable: Bool?
    let complete: Bool?
    let cancelled: Bool?
}

nonisolated struct ChatJobStartResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let jobId: String
    let phase: ChatJobPhase
    let text: String?
    let reasoning: String?
    let surface: AppAPIValue?
    let progress: ChatJobProgress?
    let error: String?
    let retryRequiresNewCid: Bool?
}

nonisolated struct ChatJobStatus: Decodable, Equatable, Sendable {
    let phase: ChatJobPhase
    let text: String?
    let reasoning: String?
    let error: String?
    let status: Int?
    let surface: AppAPIValue?
    let progress: ChatJobProgress?
}

/// Read-only admission lookup for the original CID; an empty job ID is unknown, never permission to replay POST.
nonisolated struct ChatJobReceipt: Decodable, Equatable, Sendable {
    let jobId: String
    let phase: ChatJobPhase
    let cid: String?
    let chatId: String?
}

nonisolated struct CancelChatJobRequest: Encodable, Equatable, Sendable {
    let id: String
}

nonisolated struct CancelChatJobResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let stopped: Bool
}

nonisolated struct UsageChargeRequest: Encodable, Equatable, Sendable {
    let product: ProductKind
    let cid: String
}

nonisolated struct UsageChargeResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let sub: Subscription
}

nonisolated struct WebSearchResult: Decodable, Equatable, Sendable {
    let title: String
    let url: String
    let snippet: String
}

nonisolated struct WebSearchResponse: Decodable, Equatable, Sendable {
    let q: String
    let results: [WebSearchResult]
    let via: String
}

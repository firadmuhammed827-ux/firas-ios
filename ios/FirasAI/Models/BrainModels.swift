import Foundation

nonisolated enum BrainDocumentKind: String, CaseIterable, Codable, Equatable, Sendable {
    case pdf
    case docx
    case pptx
    case xlsx
    case text
    case image
}

nonisolated enum BrainDocumentUnit: String, CaseIterable, Codable, Equatable, Sendable {
    case page
    case slide
    case sheet
    case section
}

nonisolated struct BrainDocument: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let kind: BrainDocumentKind
    let unit: BrainDocumentUnit
    let pages: Int
    let indexed: Int
    let ocr: Int
    let chunks: Int
    let chars: Int
    let ts: Int64
}

nonisolated struct BrainLibraryLimits: Codable, Equatable, Sendable {
    let docs: Int
    let pagesPerDay: Int
    let visionLeft: Int
}

nonisolated struct BrainLibraryUsage: Codable, Equatable, Sendable {
    let docs: Int
    let pagesToday: Int
}

nonisolated struct BrainLibraryResponse: Decodable, Equatable, Sendable {
    let docs: [BrainDocument]
    let guest: Bool
    let limits: BrainLibraryLimits
    let used: BrainLibraryUsage
}

nonisolated struct BrainPage: Codable, Equatable, Sendable {
    let p: Int
    let l: String?
    let text: String

    init(page: Int, label: String? = nil, text: String) {
        p = page
        l = label
        self.text = text
    }
}

nonisolated struct BrainUploadRequest: Encodable, Equatable, Sendable {
    let title: String
    let kind: BrainDocumentKind
    let unit: BrainDocumentUnit
    let pages: [BrainPage]
    let docId: String?
    let ocr: Int?
}

nonisolated struct BrainUploadResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let id: String
    let title: String
    let chunks: Int
    let total: Int
    let doc: BrainDocument
}

nonisolated enum BrainSearchMode: String, Codable, Equatable, Sendable {
    case search
    case all
    case overview
}

nonisolated struct BrainSearchRequest: Encodable, Equatable, Sendable {
    let q: String
    let k: Int?
    let docIds: [String]?
    let cid: String
    let mode: BrainSearchMode?
    let fromPage: Int?
    let toPage: Int?
    let offset: Int?
    let limit: Int?

    init(
        query: String,
        resultCount: Int? = nil,
        documentIDs: [String]? = nil,
        cid: String,
        mode: BrainSearchMode? = nil,
        fromPage: Int? = nil,
        toPage: Int? = nil,
        offset: Int? = nil,
        limit: Int? = nil
    ) {
        q = query
        k = resultCount
        docIds = documentIDs
        self.cid = cid
        self.mode = mode
        self.fromPage = fromPage
        self.toPage = toPage
        self.offset = offset
        self.limit = limit
    }
}

nonisolated struct BrainSearchRange: Decodable, Equatable, Sendable {
    let from: Int
    let to: Int
}

nonisolated struct BrainHit: Decodable, Equatable, Identifiable, Sendable {
    let matched: Int?
    let score: Double
    let text: String
    let docId: String
    let title: String
    let kind: String
    let unit: String
    let page: Int
    let label: String?
    let ci: Int

    var id: String { "\(docId)-\(ci)" }
}

nonisolated struct BrainSearchResponse: Decodable, Equatable, Sendable {
    let hits: [BrainHit]
    let docs: Int?
    let mode: String
    let total: Int?
    let offset: Int?
    let range: BrainSearchRange?
}

nonisolated struct BrainPassageNeighbour: Decodable, Equatable, Sendable {
    let ci: Int
    let t: String
}

nonisolated struct BrainPassage: Decodable, Equatable, Sendable {
    let docId: String
    let title: String
    let kind: BrainDocumentKind
    let unit: BrainDocumentUnit
    let page: Int
    let label: String
    let ci: Int
    let text: String
    let before: [BrainPassageNeighbour]
    let after: [BrainPassageNeighbour]
}

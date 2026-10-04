import Foundation

// Code attachment extraction is not under test; transport/session fixtures are
// shared with ChatStore. The tests use the real store and on-disk repository.
nonisolated enum FixtureOfficeKind: String, Sendable { case document = "docx" }
nonisolated enum BrainExtractionError: Error, Sendable {
    case officeNeedsExport(FixtureOfficeKind), emptyDocument, unreadableDocument, unsupportedType(String)
}
nonisolated struct ExtractedBrainDocument: Sendable {
    let contextText: String
}
nonisolated enum BrainDocumentExtractor {
    static func extract(url: URL) async throws -> ExtractedBrainDocument {
        throw BrainExtractionError.unreadableDocument
    }
}

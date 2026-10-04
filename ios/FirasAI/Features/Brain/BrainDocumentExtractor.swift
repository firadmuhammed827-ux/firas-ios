import Foundation
import ImageIO
@preconcurrency import PDFKit
@preconcurrency import UIKit
@preconcurrency import Vision

nonisolated struct ExtractedBrainDocument: Equatable, Sendable {
    let title: String
    let kind: BrainDocumentKind
    let unit: BrainDocumentUnit
    let pages: [BrainPage]
    let ocrPages: Int

    var contextText: String {
        pages.map { page in
            let label = page.l ?? String(page.p)
            return "[\(label)]\n\(page.text)"
        }.joined(separator: "\n\n")
    }
}

nonisolated enum BrainExtractionError: Error, Equatable, Sendable {
    case emptyDocument
    case unreadableDocument
    case unsupportedType(String)
    case officeNeedsExport(BrainDocumentKind)
}

nonisolated enum BrainDocumentExtractor {
    static func extract(url: URL) async throws -> ExtractedBrainDocument {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return try extract(data: data, filename: url.lastPathComponent)
        }.value
    }

    static func extract(data: Data, filename: String) throws -> ExtractedBrainDocument {
        let ext = (filename as NSString).pathExtension.lowercased()
        let title = cleanTitle(filename)

        switch ext {
        case "pdf":
            return try extractPDF(data: data, title: title)
        case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp":
            return try extractImage(data: data, title: title)
        case "txt", "md", "markdown", "csv", "json", "xml", "html", "htm", "css", "js", "mjs", "ts", "swift", "py", "java", "c", "h", "cpp", "hpp", "rtf":
            return try extractText(data: data, title: title)
        case "docx":
            return try extractOffice(data: data, filename: filename, kind: .docx)
        case "pptx":
            return try extractOffice(data: data, filename: filename, kind: .pptx)
        case "xlsx", "xlsm":
            return try extractOffice(data: data, filename: filename, kind: .xlsx)
        default:
            throw BrainExtractionError.unsupportedType(ext)
        }
    }

    private static func extractOffice(
        data: Data,
        filename: String,
        kind: BrainDocumentKind
    ) throws -> ExtractedBrainDocument {
        do {
            return try OfficeDocumentExtractor.extract(
                data: data,
                filename: filename,
                kind: kind
            )
        } catch let error as BrainExtractionError {
            throw error
        } catch {
            throw BrainExtractionError.unreadableDocument
        }
    }

    private static func extractPDF(data: Data, title: String) throws -> ExtractedBrainDocument {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw BrainExtractionError.unreadableDocument
        }

        var pages: [BrainPage] = []
        var ocrCount = 0
        pages.reserveCapacity(document.pageCount)

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count < 12 {
                let thumbnail = page.thumbnail(
                    of: CGSize(width: 1_600, height: 2_200),
                    for: .mediaBox
                )
                if let cgImage = thumbnail.cgImage,
                   let recognized = try? recognizedText(in: cgImage),
                   !recognized.isEmpty {
                    text = recognized
                    ocrCount += 1
                }
            }

            guard !text.isEmpty else { continue }
            pages.append(
                BrainPage(
                    page: index + 1,
                    label: nil,
                    text: String(text.prefix(60_000))
                )
            )
        }

        guard !pages.isEmpty else { throw BrainExtractionError.emptyDocument }
        return ExtractedBrainDocument(
            title: title,
            kind: .pdf,
            unit: .page,
            pages: pages,
            ocrPages: ocrCount
        )
    }

    private static func extractImage(data: Data, title: String) throws -> ExtractedBrainDocument {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw BrainExtractionError.unreadableDocument
        }
        let text = try recognizedText(in: image)
        guard !text.isEmpty else { throw BrainExtractionError.emptyDocument }
        return ExtractedBrainDocument(
            title: title,
            kind: .image,
            unit: .page,
            pages: [BrainPage(page: 1, text: String(text.prefix(60_000)))],
            ocrPages: 1
        )
    }

    private static func extractText(data: Data, title: String) throws -> ExtractedBrainDocument {
        let decoded = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .windowsCP1252)
        guard let decoded else { throw BrainExtractionError.unreadableDocument }
        let clean = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw BrainExtractionError.emptyDocument }

        let chunks = chunkText(clean, limit: 12_000)
        let pages = chunks.enumerated().map { index, chunk in
            BrainPage(page: index + 1, label: nil, text: chunk)
        }
        return ExtractedBrainDocument(
            title: title,
            kind: .text,
            unit: .section,
            pages: pages,
            ocrPages: 0
        )
    }

    private static func recognizedText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ar", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func chunkText(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var chunks: [String] = []
        var remaining = text[...]

        while !remaining.isEmpty {
            if remaining.count <= limit {
                chunks.append(String(remaining))
                break
            }
            let hardEnd = remaining.index(remaining.startIndex, offsetBy: limit)
            let window = remaining[..<hardEnd]
            let split = window.lastIndex(of: "\n")
                ?? window.lastIndex(of: ".")
                ?? hardEnd
            let piece = String(remaining[..<split])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            remaining = remaining[split...].drop(while: { $0.isWhitespace || $0 == "." })
        }
        return chunks
    }

    private static func cleanTitle(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "Firas Brain document" : String(base.prefix(160))
    }
}

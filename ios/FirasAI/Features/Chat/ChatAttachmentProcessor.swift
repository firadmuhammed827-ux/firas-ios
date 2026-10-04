@preconcurrency import PDFKit
@preconcurrency import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

nonisolated enum ChatAttachmentError: Error, Equatable, LocalizedError, Sendable {
    case unreadableImage
    case unreadableFile
    case unsupportedFile
    case emptyFile
    case tooManyFiles

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "attachment_image_unreadable"
        case .unreadableFile: "attachment_file_unreadable"
        case .unsupportedFile: "attachment_file_unsupported"
        case .emptyFile: "attachment_file_empty"
        case .tooManyFiles: "attachment_files_too_many"
        }
    }
}

nonisolated enum ChatAttachmentProcessor {
    private static let maximumDraftEdge: CGFloat = 1_568
    private static let maximumFileCharacters = 120_000
    private static let maximumTotalFileCharacters = 220_000
    // `/api/chat/job` accepts at most 600K characters. Full images, thumbnails,
    // extracted files, prior short turns, and JSON framing must all fit together.
    private static let maximumJobContextCharacters = 380_000

    static func draftImage(data: Data, sourceID: String) async throws -> DraftImageAsset {
        try await performOffMain {
            try Task.checkCancellation()
            guard let normalized = downsampledImage(data: data, maximumEdge: maximumDraftEdge) else {
                throw ChatAttachmentError.unreadableImage
            }
            try Task.checkCancellation()
            guard let jpeg = normalized.jpegData(compressionQuality: 0.82), !jpeg.isEmpty else {
                throw ChatAttachmentError.unreadableImage
            }
            return DraftImageAsset(
                id: UUID().uuidString,
                sourceID: sourceID,
                jpegData: jpeg
            )
        }
    }

    static func draftFile(url: URL) async throws -> DraftFileAsset {
        try await performOffMain {
            try Task.checkCancellation()
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            let name = String(url.lastPathComponent.prefix(120))
            let ext = url.pathExtension.lowercased()
            let rawText: String
            let kind: String

            switch ext {
            case "pdf":
                kind = "pdf"
                rawText = try extractPDF(url: url)
            case "txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "xml",
                 "yml", "yaml", "html", "htm", "css", "scss", "less", "js", "jsx",
                 "mjs", "cjs", "ts", "tsx", "py", "java", "c", "h", "cpp", "cc",
                 "hpp", "cs", "go", "rs", "rb", "php", "swift", "kt", "kts", "sql",
                 "sh", "bash", "zsh", "ini", "toml", "cfg", "conf", "log", "tex",
                 "srt", "vtt", "rtf", "svg":
                kind = "text"
                rawText = try extractText(url: url)
            case "docx", "pptx", "xlsx", "xlsm":
                // Office archives are routed to Firas Brain, whose source flow
                // preserves section/slide/sheet citations instead of silently
                // flattening a partial file in chat.
                throw ChatAttachmentError.unsupportedFile
            default:
                throw ChatAttachmentError.unsupportedFile
            }

            let clean = rawText
                .replacingOccurrences(of: "\u{0000}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { throw ChatAttachmentError.emptyFile }
            try Task.checkCancellation()

            let truncated = clean.count > maximumFileCharacters
            return DraftFileAsset(
                id: UUID().uuidString,
                name: name.isEmpty ? "attachment.\(ext)" : name,
                kind: kind,
                text: String(clean.prefix(maximumFileCharacters)),
                wasTruncated: truncated
            )
        }
    }

    static func prepare(
        images: [DraftImageAsset],
        files: [DraftFileAsset],
        sharpenImages: Bool = false
    ) async throws -> PreparedChatContext {
        let safeImages = Array(images.prefix(10))
        let safeFiles = Array(files.prefix(5))

        return try await performOffMain {
            try Task.checkCancellation()
            let fileText = makeFileText(safeFiles)
            let fileCharacters = fileText?.count ?? 0
            let imageCharacterBudget = max(
                82_000,
                maximumJobContextCharacters - fileCharacters
            )

            var fullImages: [String] = []
            var thumbnails: [String] = []
            let sharpeningContext = sharpenImages ? CIContext() : nil
            let eachBase64Budget = safeImages.isEmpty
                ? 0
                : max(24_000, imageCharacterBudget / safeImages.count)

            for image in safeImages {
                try Task.checkCancellation()
                guard let uiImage = UIImage(data: image.jpegData) else { continue }
                let preparedImage = sharpeningContext.map {
                    sharpened(uiImage, using: $0)
                } ?? uiImage
                let full = try compressedJPEG(
                    preparedImage,
                    maximumBase64Characters: eachBase64Budget,
                    imageCount: safeImages.count
                )
                guard !full.isEmpty else { continue }
                fullImages.append(full.base64EncodedString())

                let thumbImage = resized(preparedImage, maximumEdge: 128)
                if let thumb = thumbImage.jpegData(compressionQuality: 0.55) {
                    thumbnails.append(
                        "data:image/jpeg;base64," + thumb.base64EncodedString()
                    )
                }
            }

            return PreparedChatContext(
                fullImages: fullImages,
                imageThumbnails: thumbnails,
                files: safeFiles.map { ChatAttachment(name: $0.name, kind: $0.kind) },
                fileText: fileText
            )
        }
    }

    private static func performOffMain<Output: Sendable>(
        _ operation: @escaping @Sendable () throws -> Output
    ) async throws -> Output {
        let worker = Task.detached(priority: .userInitiated) {
            try operation()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func makeFileText(_ files: [DraftFileAsset]) -> String? {
        guard !files.isEmpty else { return nil }
        var remaining = maximumTotalFileCharacters
        var blocks: [String] = []

        for file in files where remaining > 0 {
            let body = String(file.text.prefix(remaining))
            guard !body.isEmpty else { continue }
            remaining -= body.count
            blocks.append(
                "===== FILE: \(file.name) =====\n\(body)\n===== END FILE: \(file.name) ====="
            )
        }

        guard !blocks.isEmpty else { return nil }
        return """
        The user attached the following file(s). Read their contents carefully and use them to answer.

        \(blocks.joined(separator: "\n\n"))
        """
    }

    private static func compressedJPEG(
        _ image: UIImage,
        maximumBase64Characters: Int,
        imageCount: Int
    ) throws -> Data {
        let targetBytes = max(18_000, maximumBase64Characters * 3 / 4)
        var edge: CGFloat = imageCount <= 1 ? 1_280 : imageCount <= 3 ? 960 : 720
        var quality: CGFloat = 0.74
        var workingImage = resized(image, maximumEdge: edge)
        var result = workingImage.jpegData(compressionQuality: quality) ?? Data()

        while result.count > targetBytes, edge > 360 {
            try Task.checkCancellation()
            if quality > 0.48 {
                quality -= 0.08
            } else {
                edge *= 0.78
                quality = 0.62
                workingImage = resized(image, maximumEdge: edge)
            }
            result = workingImage.jpegData(compressionQuality: quality) ?? Data()
        }
        return result
    }

    /// Applies a deliberately restrained local contrast pass before the final
    /// downsample. The filter and CIContext stay inside the detached image task,
    /// so no UIKit/Core Image reference crosses an actor boundary.
    private static func sharpened(_ image: UIImage, using context: CIContext) -> UIImage {
        guard let input = CIImage(
            image: image,
            options: [.applyOrientationProperty: true]
        ) else { return image }

        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = input
        filter.sharpness = 0.32
        filter.radius = 1.0

        guard let output = filter.outputImage else { return image }
        let extent = output.extent.integral
        guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
              let rendered = context.createCGImage(output, from: extent)
        else { return image }

        return UIImage(cgImage: rendered, scale: 1, orientation: .up)
    }

    private static func resized(_ image: UIImage, maximumEdge: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maximumEdge, longest > 0 else { return image }

        let scale = maximumEdge / longest
        let target = CGSize(
            width: max(1, floor(size.width * scale)),
            height: max(1, floor(size.height * scale))
        )
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Decode only the pixels the UI needs. Decoding a full camera image before
    /// resizing can transiently retain tens of megabytes per attachment.
    static func downsampledImage(data: Data, maximumEdge: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maximumEdge)),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }

    private static func extractPDF(url: URL) throws -> String {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw ChatAttachmentError.unreadableFile
        }

        var output = ""
        for index in 0 ..< min(document.pageCount, 80) {
            try Task.checkCancellation()
            guard let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { continue }
            output += "[Page \(index + 1)]\n\(text)\n\n"
            if output.count >= maximumFileCharacters { break }
        }
        return output
    }

    private static func extractText(url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= 8_000_000 else { throw ChatAttachmentError.unreadableFile }

        for encoding in [
            String.Encoding.utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .windowsCP1252,
            .isoLatin1,
        ] {
            if let value = String(data: data, encoding: encoding), !value.isEmpty {
                return value
            }
        }
        throw ChatAttachmentError.unreadableFile
    }
}

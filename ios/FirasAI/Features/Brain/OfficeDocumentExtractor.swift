import Foundation
import ZIPFoundation

/// Reads the same OOXML families supported by the web app without uploading the
/// original Office archive to a third party. ZIPFoundation is pinned in the
/// Xcode project; every archive is CRC-checked, traversal-protected, bounded,
/// expanded into an isolated temporary directory, then removed immediately.
nonisolated enum OfficeDocumentExtractor {
    private static let maximumArchiveBytes = 64_000_000
    private static let maximumExpandedBytes: UInt64 = 160_000_000
    private static let maximumEntryBytes: UInt64 = 64_000_000
    private static let maximumEntries = 12_000
    private static let maximumDocumentCharacters = 8_000_000
    private static let maximumRecords = 1_200

    static func extract(
        data: Data,
        filename: String,
        kind: BrainDocumentKind
    ) throws -> ExtractedBrainDocument {
        guard !data.isEmpty, data.count <= maximumArchiveBytes else {
            throw BrainExtractionError.unreadableDocument
        }

        let manager = FileManager.default
        let workspace = manager.temporaryDirectory
            .appendingPathComponent("FirasOffice", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = workspace.appendingPathComponent("document.zip")
        let expandedURL = workspace.appendingPathComponent("expanded", isDirectory: true)
        try manager.createDirectory(at: expandedURL, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: workspace) }

        try data.write(to: archiveURL, options: [.atomic])
        try preflightArchive(at: archiveURL)
        try manager.unzipItem(
            at: archiveURL,
            to: expandedURL,
            skipCRC32: false,
            allowUncontainedSymlinks: false
        )

        let title = cleanTitle(filename)
        switch kind {
        case .docx:
            return try extractDOCX(root: expandedURL, title: title)
        case .pptx:
            return try extractPPTX(root: expandedURL, title: title)
        case .xlsx:
            return try extractXLSX(root: expandedURL, title: title)
        case .pdf, .text, .image:
            throw BrainExtractionError.unsupportedType(kind.rawValue)
        }
    }

    private static func preflightArchive(at url: URL) throws {
        let archive = try Archive(url: url, accessMode: .read)
        var entryCount = 0
        var expandedBytes: UInt64 = 0

        for entry in archive {
            entryCount += 1
            let path = entry.path.replacingOccurrences(of: "\\", with: "/")
            let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
            guard entryCount <= maximumEntries,
                  !path.hasPrefix("/"),
                  !pieces.contains(".."),
                  entry.type != .symlink,
                  entry.uncompressedSize <= maximumEntryBytes
            else {
                throw BrainExtractionError.unreadableDocument
            }
            let (next, overflow) = expandedBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, next <= maximumExpandedBytes else {
                throw BrainExtractionError.unreadableDocument
            }
            expandedBytes = next
        }
        guard entryCount > 0 else { throw BrainExtractionError.emptyDocument }
    }

    private static func extractDOCX(
        root: URL,
        title: String
    ) throws -> ExtractedBrainDocument {
        let documentURL = root.appendingPathComponent("word/document.xml")
        let collector = ParagraphXMLCollector(limit: maximumDocumentCharacters)
        try parseXML(at: documentURL, delegate: collector)
        let text = collector.paragraphs.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BrainExtractionError.emptyDocument }

        let pages = chunkText(text, limit: 12_000)
            .prefix(maximumRecords)
            .enumerated()
            .map { BrainPage(page: $0.offset + 1, text: $0.element) }
        return ExtractedBrainDocument(
            title: title,
            kind: .docx,
            unit: .section,
            pages: pages,
            ocrPages: 0
        )
    }

    private static func extractPPTX(
        root: URL,
        title: String
    ) throws -> ExtractedBrainDocument {
        let slidesFolder = root.appendingPathComponent("ppt/slides", isDirectory: true)
        let slideURLs = try FileManager.default.contentsOfDirectory(
            at: slidesFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("slide") && $0.pathExtension.lowercased() == "xml" }
        .sorted { officePartIndex($0) < officePartIndex($1) }
        .prefix(maximumRecords)

        var pages: [BrainPage] = []
        var remaining = maximumDocumentCharacters
        for (position, url) in slideURLs.enumerated() where remaining > 0 {
            let collector = ParagraphXMLCollector(limit: min(remaining, 120_000))
            try parseXML(at: url, delegate: collector)
            let text = collector.paragraphs.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            remaining -= text.count
            let label = collector.paragraphs.first.map { String($0.prefix(120)) }
            pages.append(BrainPage(page: position + 1, label: label, text: text))
        }
        guard !pages.isEmpty else { throw BrainExtractionError.emptyDocument }
        return ExtractedBrainDocument(
            title: title,
            kind: .pptx,
            unit: .slide,
            pages: pages,
            ocrPages: 0
        )
    }

    private static func extractXLSX(
        root: URL,
        title: String
    ) throws -> ExtractedBrainDocument {
        let xlRoot = root.appendingPathComponent("xl", isDirectory: true)
        let sharedStringsURL = xlRoot.appendingPathComponent("sharedStrings.xml")
        var sharedStrings: [String] = []
        if FileManager.default.fileExists(atPath: sharedStringsURL.path) {
            let collector = SharedStringXMLCollector(
                itemLimit: 300_000,
                characterLimit: 4_000_000
            )
            try parseXML(at: sharedStringsURL, delegate: collector)
            sharedStrings = collector.items
        }

        let sheetNames = workbookSheetNames(at: xlRoot.appendingPathComponent("workbook.xml"))
        let sheetsFolder = xlRoot.appendingPathComponent("worksheets", isDirectory: true)
        let sheetURLs = try FileManager.default.contentsOfDirectory(
            at: sheetsFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("sheet") && $0.pathExtension.lowercased() == "xml" }
        .sorted { officePartIndex($0) < officePartIndex($1) }
        .prefix(maximumRecords)

        var pages: [BrainPage] = []
        var remaining = maximumDocumentCharacters
        for (position, url) in sheetURLs.enumerated() where remaining > 0 {
            let collector = WorksheetXMLCollector(
                sharedStrings: sharedStrings,
                rowLimit: 20_000,
                cellLimit: 200_000,
                characterLimit: min(remaining, 450_000)
            )
            try parseXML(at: url, delegate: collector)
            let text = collector.rows.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            remaining -= text.count
            let label = sheetNames.indices.contains(position)
                ? sheetNames[position] : "Sheet \(position + 1)"
            pages.append(BrainPage(page: position + 1, label: label, text: text))
        }
        guard !pages.isEmpty else { throw BrainExtractionError.emptyDocument }
        return ExtractedBrainDocument(
            title: title,
            kind: .xlsx,
            unit: .sheet,
            pages: pages,
            ocrPages: 0
        )
    }

    private static func workbookSheetNames(at url: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let collector = WorkbookXMLCollector()
        try? parseXML(at: url, delegate: collector)
        return collector.names
    }

    private static func parseXML(
        at url: URL,
        delegate: XMLParserDelegate
    ) throws {
        guard let parser = XMLParser(contentsOf: url) else {
            throw BrainExtractionError.unreadableDocument
        }
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw BrainExtractionError.unreadableDocument }
    }

    private static func officePartIndex(_ url: URL) -> Int {
        let digits = url.deletingPathExtension().lastPathComponent.filter(\.isNumber)
        return Int(digits) ?? .max
    }

    private static func cleanTitle(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "Firas Brain document" : String(base.prefix(160))
    }

    private static func chunkText(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var output: [String] = []
        var remaining = text[...]
        while !remaining.isEmpty, output.count < maximumRecords {
            if remaining.count <= limit {
                output.append(String(remaining))
                break
            }
            let hardEnd = remaining.index(remaining.startIndex, offsetBy: limit)
            let window = remaining[..<hardEnd]
            let split = window.lastIndex(of: "\n") ?? window.lastIndex(of: ".") ?? hardEnd
            let value = remaining[..<split]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { output.append(value) }
            remaining = remaining[split...]
                .drop(while: { $0.isWhitespace || $0 == "." })
        }
        return output
    }
}

private nonisolated final class ParagraphXMLCollector: NSObject, XMLParserDelegate {
    private let limit: Int
    private var isText = false
    private var current = ""
    private var characterCount = 0
    private(set) var paragraphs: [String] = []

    init(limit: Int) {
        self.limit = limit
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch Self.local(elementName) {
        case "p":
            flush()
        case "t":
            isText = true
        case "tab":
            append("\t")
        case "br":
            append("\n")
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch Self.local(elementName) {
        case "t": isText = false
        case "p": flush()
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isText { append(string) }
    }

    private func append(_ value: String) {
        guard characterCount < limit else { return }
        let accepted = String(value.prefix(limit - characterCount))
        current += accepted
        characterCount += accepted.count
    }

    private func flush() {
        let clean = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { paragraphs.append(clean) }
        current = ""
    }

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

private nonisolated final class SharedStringXMLCollector: NSObject, XMLParserDelegate {
    private let itemLimit: Int
    private let characterLimit: Int
    private var insideItem = false
    private var insideText = false
    private var current = ""
    private var characterCount = 0
    private(set) var items: [String] = []

    init(itemLimit: Int, characterLimit: Int) {
        self.itemLimit = itemLimit
        self.characterLimit = characterLimit
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.local(elementName)
        if name == "si" {
            insideItem = true
            current = ""
        } else if name == "t", insideItem {
            insideText = true
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = Self.local(elementName)
        if name == "t" {
            insideText = false
        } else if name == "si" {
            if items.count < itemLimit { items.append(current) }
            insideItem = false
            current = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideText, characterCount < characterLimit else { return }
        let accepted = String(string.prefix(characterLimit - characterCount))
        current += accepted
        characterCount += accepted.count
    }

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

private nonisolated final class WorkbookXMLCollector: NSObject, XMLParserDelegate {
    private(set) var names: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        guard local == "sheet", let name = attributeDict["name"], !name.isEmpty else { return }
        names.append(String(name.prefix(120)))
    }
}

private nonisolated final class WorksheetXMLCollector: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private let rowLimit: Int
    private let cellLimit: Int
    private let characterLimit: Int
    private var currentCells: [String] = []
    private var currentType = ""
    private var currentReference = ""
    private var currentValue = ""
    private var capturesValue = false
    private var rowCount = 0
    private var cellCount = 0
    private var characterCount = 0
    private(set) var rows: [String] = []

    init(
        sharedStrings: [String],
        rowLimit: Int,
        cellLimit: Int,
        characterLimit: Int
    ) {
        self.sharedStrings = sharedStrings
        self.rowLimit = rowLimit
        self.cellLimit = cellLimit
        self.characterLimit = characterLimit
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = Self.local(elementName)
        if name == "row" {
            currentCells = []
        } else if name == "c" {
            currentType = attributeDict["t"] ?? ""
            currentReference = attributeDict["r"] ?? ""
            currentValue = ""
        } else if name == "v" || name == "t" {
            capturesValue = true
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = Self.local(elementName)
        if name == "v" || name == "t" {
            capturesValue = false
        } else if name == "c" {
            appendCell(resolvedValue())
        } else if name == "row" {
            flushRow()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturesValue { currentValue += string }
    }

    private func appendCell(_ value: String) {
        guard rowCount < rowLimit, cellCount < cellLimit else { return }
        let column = Self.columnIndex(from: currentReference)
        if let column, column >= 0, column < 256 {
            while currentCells.count < column { currentCells.append("") }
        }
        currentCells.append(String(value.prefix(12_000)))
        cellCount += 1
    }

    private func resolvedValue() -> String {
        let clean = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentType == "s", let index = Int(clean), sharedStrings.indices.contains(index) {
            return sharedStrings[index]
        }
        if currentType == "b" { return clean == "1" ? "TRUE" : "FALSE" }
        return clean
    }

    private func flushRow() {
        guard rowCount < rowLimit, characterCount < characterLimit else {
            currentCells = []
            return
        }
        while currentCells.last?.isEmpty == true { currentCells.removeLast() }
        let line = currentCells.joined(separator: "\t")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        currentCells = []
        rowCount += 1
        guard !line.isEmpty else { return }
        let remaining = characterLimit - characterCount
        let accepted = String(line.prefix(remaining))
        rows.append(accepted)
        characterCount += accepted.count + 1
    }

    private static func columnIndex(from reference: String) -> Int? {
        let letters = reference.prefix(while: { $0.isLetter })
        guard !letters.isEmpty else { return nil }
        var result = 0
        for scalar in letters.uppercased().unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            result = result * 26 + Int(scalar.value - 64)
        }
        return max(0, result - 1)
    }

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

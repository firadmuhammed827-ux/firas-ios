import Foundation
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct FirasChatBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let backup: FirasChatBackup

    init(backup: FirasChatBackup) {
        self.backup = backup
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw ChatBackupValidationError.unsupportedFormat
        }
        backup = try FirasChatBackup.decodeValidated(from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return FileWrapper(regularFileWithContents: try encoder.encode(backup))
    }
}

nonisolated enum ChatBackupFileReader {
    @concurrent
    static func read(from url: URL) async throws -> FirasChatBackup {
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false else {
            throw ChatBackupValidationError.unsupportedFormat
        }
        if let fileSize = values.fileSize,
           fileSize > FirasChatBackup.maximumFileBytes {
            throw ChatBackupValidationError.fileTooLarge
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try FirasChatBackup.decodeValidated(from: data)
    }
}

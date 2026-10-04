import Foundation
import Observation

@MainActor
@Observable
final class BrainStore {
    private(set) var library: BrainLibraryResponse?
    private(set) var hits: [BrainHit] = []
    private(set) var selectedPassage: BrainPassage?
    private(set) var selectedDocumentIDs: Set<String> = []
    private(set) var isLoading = false
    private(set) var isImporting = false
    private(set) var isSearching = false
    private(set) var didSearch = false
    private(set) var importingFilename = ""
    var errorMessage: String?

    @ObservationIgnored private let api: FirasAPI
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var loadedOwnerID: String?
    @ObservationIgnored private var ownerGeneration = 0
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var passageGeneration = 0

    init(session: SessionStore, api: FirasAPI = FirasAPI()) {
        self.session = session
        self.api = api
    }

    var documents: [BrainDocument] { library?.docs ?? [] }
    var limits: BrainLibraryLimits? { library?.limits }
    var usage: BrainLibraryUsage? { library?.used }

    func synchronizeOwner() {
        let ownerID = session.identityID
        guard loadedOwnerID != ownerID else { return }
        ownerGeneration &+= 1
        searchGeneration &+= 1
        passageGeneration &+= 1
        importTask?.cancel()
        searchTask?.cancel()
        importTask = nil
        searchTask = nil
        loadedOwnerID = ownerID
        library = nil
        hits = []
        selectedPassage = nil
        selectedDocumentIDs = []
        isLoading = false
        isImporting = false
        isSearching = false
        didSearch = false
        importingFilename = ""
        errorMessage = nil
    }

    func loadLibrary() async {
        synchronizeOwner()
        let ownerID = session.identityID
        let generation = ownerGeneration
        guard session.isAuthenticated else {
            library = nil
            hits = []
            return
        }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { if generation == ownerGeneration { isLoading = false } }

        do {
            let loaded = try await api.brainDocuments()
            guard isCurrentOwner(ownerID, generation: generation), !Task.isCancelled else { return }
            library = loaded
            let validIDs = Set(documents.map(\.id))
            selectedDocumentIDs.formIntersection(validIDs)
        } catch {
            guard isCurrentOwner(ownerID, generation: generation), !Task.isCancelled else { return }
            errorMessage = message(for: error)
        }
    }

    func importDocuments(_ urls: [URL], language: AppLanguage) {
        synchronizeOwner()
        let ownerID = session.identityID
        let generation = ownerGeneration
        guard session.isAuthenticated else {
            errorMessage = localized(
                ar: "سجّل الدخول لإضافة المصادر إلى فِراس Brain.",
                en: "Sign in to add sources to Firas Brain.",
                language: language
            )
            return
        }
        guard !urls.isEmpty, importTask == nil else { return }
        errorMessage = nil
        isImporting = true

        importTask = Task {
            defer {
                if generation == self.ownerGeneration {
                    self.isImporting = false
                    self.importingFilename = ""
                    self.importTask = nil
                }
            }

            for url in urls {
                guard !Task.isCancelled, self.isCurrentOwner(ownerID, generation: generation) else { return }
                self.importingFilename = url.lastPathComponent
                do {
                    let extracted = try await BrainDocumentExtractor.extract(url: url)
                    guard !Task.isCancelled, self.isCurrentOwner(ownerID, generation: generation) else { return }
                    let parts = try self.uploadParts(extracted.pages)
                    var documentID: String?
                    for (index, pages) in parts.enumerated() {
                        guard !Task.isCancelled, self.isCurrentOwner(ownerID, generation: generation) else { return }
                        let request = BrainUploadRequest(
                            title: extracted.title,
                            kind: extracted.kind,
                            unit: extracted.unit,
                            pages: pages,
                            docId: documentID,
                            // OCR belongs to the document, not every transport
                            // part. Repeating it would overcharge vision usage.
                            ocr: index == 0 ? extracted.ocrPages : nil
                        )
                        let response = try await self.api.uploadBrainDocument(request)
                        guard !Task.isCancelled, self.isCurrentOwner(ownerID, generation: generation) else { return }
                        documentID = response.id
                    }
                } catch {
                    guard !Task.isCancelled, self.isCurrentOwner(ownerID, generation: generation) else { return }
                    self.errorMessage = self.extractionMessage(for: error, language: language)
                }
            }

            guard self.isCurrentOwner(ownerID, generation: generation) else { return }
            await self.loadLibrary()
        }
    }

    func delete(_ document: BrainDocument) async {
        synchronizeOwner()
        let ownerID = session.identityID
        let generation = ownerGeneration
        guard session.isAuthenticated else { return }
        errorMessage = nil
        do {
            try await api.deleteBrainDocument(id: document.id)
            guard isCurrentOwner(ownerID, generation: generation), !Task.isCancelled else { return }
            selectedDocumentIDs.remove(document.id)
            hits.removeAll { $0.docId == document.id }
            passageGeneration &+= 1
            if selectedPassage?.docId == document.id { selectedPassage = nil }
            await loadLibrary()
        } catch {
            guard isCurrentOwner(ownerID, generation: generation), !Task.isCancelled else { return }
            errorMessage = message(for: error)
        }
    }

    func toggleSelection(_ documentID: String) {
        synchronizeOwner()
        guard documents.contains(where: { $0.id == documentID }) else { return }
        if selectedDocumentIDs.contains(documentID) {
            selectedDocumentIDs.remove(documentID)
        } else {
            selectedDocumentIDs.insert(documentID)
        }
    }

    func clearSelection() {
        synchronizeOwner()
        selectedDocumentIDs.removeAll()
    }

    func search(query: String, language: AppLanguage) {
        synchronizeOwner()
        let ownerID = session.identityID
        let generation = ownerGeneration
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard session.isAuthenticated else {
            errorMessage = localized(
                ar: "سجّل الدخول للبحث في مصادر Brain.",
                en: "Sign in to search your Brain sources.",
                language: language
            )
            return
        }
        guard !documents.isEmpty else {
            errorMessage = localized(
                ar: "أضف مصدراً أولاً ثم اطرح سؤالك.",
                en: "Add a source before asking a question.",
                language: language
            )
            return
        }

        searchTask?.cancel()
        searchGeneration &+= 1
        let searchTicket = searchGeneration
        isSearching = true
        didSearch = true
        passageGeneration &+= 1
        selectedPassage = nil
        errorMessage = nil
        let documentIDs = selectedDocumentIDs.isEmpty
            ? nil : Array(selectedDocumentIDs).sorted()
        let request = BrainSearchRequest(
            query: String(clean.prefix(4_000)),
            resultCount: 20,
            documentIDs: documentIDs,
            cid: stableIdentifier(),
            mode: .search
        )

        searchTask = Task {
            defer {
                if generation == self.ownerGeneration, searchTicket == self.searchGeneration {
                    self.isSearching = false
                    self.searchTask = nil
                }
            }
            do {
                let response = try await self.api.searchBrain(request)
                guard !Task.isCancelled, searchTicket == self.searchGeneration,
                      self.isCurrentOwner(ownerID, generation: generation) else { return }
                self.hits = response.hits
            } catch {
                if !Task.isCancelled, searchTicket == self.searchGeneration,
                   self.isCurrentOwner(ownerID, generation: generation) {
                    self.errorMessage = self.message(for: error)
                }
            }
        }
    }

    func loadPassage(for hit: BrainHit) async {
        synchronizeOwner()
        let ownerID = session.identityID
        let generation = ownerGeneration
        guard session.isAuthenticated else { return }
        passageGeneration &+= 1
        let passageTicket = passageGeneration
        errorMessage = nil
        do {
            let passage = try await api.brainPassage(
                documentID: hit.docId,
                chunkIndex: hit.ci,
                window: 2
            )
            guard !Task.isCancelled, passageTicket == passageGeneration,
                  isCurrentOwner(ownerID, generation: generation) else { return }
            selectedPassage = passage
        } catch {
            guard !Task.isCancelled, passageTicket == passageGeneration,
                  isCurrentOwner(ownerID, generation: generation) else { return }
            errorMessage = message(for: error)
        }
    }

    func dismissPassage() {
        passageGeneration &+= 1
        selectedPassage = nil
    }

    private func isCurrentOwner(_ expectedOwnerID: String?, generation: Int) -> Bool {
        synchronizeOwner()
        return ownerGeneration == generation && session.identityID == expectedOwnerID
    }

    private func stableIdentifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Mirrors the website's proven upload envelope while preserving groups
    /// that share the same page/sheet number. Splitting a sheet group between
    /// requests would make the server count one citable unit more than once.
    private func uploadParts(_ pages: [BrainPage]) throws -> [[BrainPage]] {
        let maximumCharacters = 680_000
        let maximumRecords = 950
        var result: [[BrainPage]] = []
        var current: [BrainPage] = []
        var currentCharacters = 0
        var index = 0

        while index < pages.count {
            let pageNumber = pages[index].p
            var group: [BrainPage] = []
            var groupCharacters = 0
            while index < pages.count, pages[index].p == pageNumber {
                group.append(pages[index])
                groupCharacters += pages[index].text.count
                index += 1
            }

            guard groupCharacters < maximumCharacters, group.count < maximumRecords else {
                throw APIError.invalidRequest(
                    "One citable page or sheet is too large to upload safely."
                )
            }

            let wouldExceedCharacters = currentCharacters + groupCharacters > maximumCharacters
            let wouldExceedRecords = current.count + group.count > maximumRecords
            if !current.isEmpty, wouldExceedCharacters || wouldExceedRecords {
                result.append(current)
                current = []
                currentCharacters = 0
            }

            current.append(contentsOf: group)
            currentCharacters += groupCharacters
        }

        if !current.isEmpty { result.append(current) }
        return result
    }

    private func extractionMessage(for error: Error, language: AppLanguage) -> String {
        guard let extraction = error as? BrainExtractionError else {
            return message(for: error)
        }
        switch extraction {
        case .emptyDocument:
            return localized(
                ar: "لم يُعثر على نص قابل للقراءة في هذا الملف.",
                en: "No readable text was found in this file.",
                language: language
            )
        case .unreadableDocument:
            return localized(
                ar: "تعذّرت قراءة الملف المحدد.",
                en: "The selected file could not be read.",
                language: language
            )
        case .officeNeedsExport(let kind):
            let type = kind.rawValue.uppercased()
            return localized(
                ar: "ملف \(type) يحتاج تصديره إلى PDF أو نص قبل إضافته على iPhone.",
                en: "Export this \(type) file as PDF or text before adding it on iPhone.",
                language: language
            )
        case .unsupportedType(let ext):
            return localized(
                ar: "نوع الملف .\(ext) غير مدعوم حالياً.",
                en: ".\(ext) files are not supported yet.",
                language: language
            )
        }
    }

    private func localized(ar: String, en: String, language: AppLanguage) -> String {
        language == .arabic ? ar : en
    }

    private func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.errorDescription ?? "تعذّر الاتصال بالخادم."
        }
        return error.localizedDescription
    }
}

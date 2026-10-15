import Foundation
import Observation
import CryptoKit

nonisolated struct CodeWorkspaceProject: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var files: [CodeFile]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        files: [CodeFile],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.files = files
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

nonisolated struct CodeAttachment: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let context: String
}

private nonisolated struct CodeBuildPointer: Codable, Equatable, Sendable {
    let ownerID: String
    let jobID: String?
    let cid: String
    let projectName: String
    let prompt: String
    let attachmentContext: String
    let language: AppLanguage
    let startedAt: Date
    var replyOnly: Bool? = nil
    var intentInstruction: String? = nil
    var modelGeneration: ModelGeneration? = nil

    func with(jobID: String) -> CodeBuildPointer {
        CodeBuildPointer(
            ownerID: ownerID,
            jobID: jobID,
            cid: cid,
            projectName: projectName,
            prompt: prompt,
            attachmentContext: attachmentContext,
            language: language,
            startedAt: startedAt,
            replyOnly: replyOnly,
            intentInstruction: intentInstruction,
            modelGeneration: modelGeneration
        )
    }
}

@MainActor
@Observable
final class CodeStore {
    private(set) var projects: [CodeWorkspaceProject] = []
    private(set) var workspace: CodeWorkspaceProject?
    private(set) var selectedFilePath: String?
    private(set) var editorText = ""
    private(set) var attachments: [CodeAttachment] = []
    private(set) var isLoadingProjects = false
    private(set) var isReadingAttachments = false
    private(set) var isBuilding = false
    private(set) var activeJobID: String?
    private(set) var buildPhase: ChatJobPhase?
    private(set) var buildProgress: ChatJobProgress?
    private(set) var buildStartedAt: Date?
    private(set) var buildingProjectName = ""
    private(set) var isStoppingBuild = false
    var errorMessage: String?
    /// A build outcome the screen words from Code.xcstrings in the reader's language.
    var buildNotice: CodeBuildNotice?
    private(set) var lastResponse: String?

    @ObservationIgnored private let api: FirasAPI
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let repository: CodeProjectRepository
    @ObservationIgnored private var owningTask: Task<Void, Never>?
    @ObservationIgnored private var attachmentTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loadedOwnerID: String?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var ownerGeneration = 0
    @ObservationIgnored private var intentHistory: [IntentReference] = []
    @ObservationIgnored private var awaitingRecovery = false
    /// The build this device is watching, as last persisted. Stop works from it
    /// even when the defaults copy cannot be read back.
    @ObservationIgnored private var buildPointer: CodeBuildPointer?
    /// The job a Stop was sent for. Its later "cancelled" ending is that Stop
    /// landing, not a failure.
    @ObservationIgnored private var stopRequestedJobID: String?
    /// The cid of a new press still waiting for the classifier. Nothing has
    /// been submitted under it, so a Stop then removes its pointer at once.
    @ObservationIgnored private var classifyingCID: String?

    private static let pointerMapKey = "firas.ios.code-builds.v1"
    private static let maximumRecoveryAttempts = 6
    private static let unknownJobLimit = 3

    init(
        session: SessionStore,
        api: FirasAPI = FirasAPI(),
        defaults: UserDefaults = .standard,
        repository: CodeProjectRepository = CodeProjectRepository()
    ) {
        self.session = session
        self.api = api
        self.defaults = defaults
        self.repository = repository
    }

    var currentFile: CodeFile? {
        guard let selectedFilePath else { return nil }
        return workspace?.files.first { $0.path == selectedFilePath }
    }

    var previewHTML: String? {
        guard let files = workspace?.files else { return nil }
        return CodePreviewBuilder.html(from: files)
    }

    var canBuild: Bool { !isBuilding && !isReadingAttachments && loadedOwnerID == (session.identityID ?? "guest") }

    func synchronizeOwner() {
        let ownerID = session.identityID ?? "guest"
        guard loadedOwnerID != ownerID else { return }
        if let previousOwnerID = loadedOwnerID, let previousWorkspace = workspace {
            // A pending editor debounce must not lose the last typed changes
            // when the account switches. This write stays in the old account.
            Task { [repository] in
                try? await repository.save(previousWorkspace, ownerID: previousOwnerID)
            }
        }
        ownerGeneration &+= 1
        loadGeneration &+= 1
        saveTask?.cancel()
        attachmentTask?.cancel()
        saveTask = nil
        attachmentTask = nil
        isReadingAttachments = false
        isLoadingProjects = false
        workspace = nil
        projects = []
        selectedFilePath = nil
        editorText = ""
        attachments = []
        lastResponse = nil
        intentHistory = []
        buildStartedAt = nil
        buildingProjectName = ""
        loadedOwnerID = ownerID
        // The old generation stops watching after its in-flight request. The
        // new account's library never waits for that request or server build.
        finishLocalOwnership()
    }

    func loadProjects() async {
        synchronizeOwner()
        let ownerID = session.identityID ?? "guest"
        let generation = ownerGeneration
        loadGeneration &+= 1
        let ticket = loadGeneration
        guard ticket == loadGeneration, isCurrentOwner(ownerID, generation: generation) else { return }
        isLoadingProjects = true
        defer { if ticket == loadGeneration { isLoadingProjects = false } }
        do {
            let loaded = try await repository.loadAll(ownerID: ownerID)
            guard ticket == loadGeneration, isCurrentOwner(ownerID, generation: generation), !Task.isCancelled else { return }
            projects = loaded
            // A resumed build can finish while the library is still being read.
            if let workspace, !projects.contains(where: { $0.id == workspace.id }) {
                upsert(workspace)
            }
            if workspace == nil, !isBuilding, let first = projects.first {
                open(first)
            }
        } catch {
            guard ticket == loadGeneration, isCurrentOwner(ownerID, generation: generation), !Task.isCancelled else { return }
            errorMessage = message(for: error)
        }
    }

    func open(_ project: CodeWorkspaceProject) {
        synchronizeOwner()
        guard projects.contains(where: { $0.id == project.id }) else { return }
        commitEditorText()
        // The open file belongs to the project being closed. Forget it before
        // the switch, or selectFile would commit its text into the next
        // project's file with the same path.
        selectedFilePath = nil
        editorText = ""
        workspace = project
        selectFile(path: preferredEntry(in: project.files))
    }

    func showProjectLibrary() {
        synchronizeOwner()
        commitEditorText()
        workspace = nil
        selectedFilePath = nil
        editorText = ""
    }

    func createBlank(name: String, language: AppLanguage) {
        synchronizeOwner()
        let cleanName = normalizedName(name, fallback: language == .arabic ? "مشروع جديد" : "new-project")
        let project = CodeWorkspaceProject(
            name: cleanName,
            files: Self.blankFiles(projectName: cleanName, language: language)
        )
        // Same reason as open(_:): a blank project also has an index.html.
        commitEditorText()
        selectedFilePath = nil
        editorText = ""
        workspace = project
        upsert(project)
        selectFile(path: "index.html")
        save(project)
    }

    func delete(_ project: CodeWorkspaceProject) async {
        synchronizeOwner()
        let ownerID = loadedOwnerID ?? "guest"
        let generation = ownerGeneration
        do {
            try await repository.delete(id: project.id, ownerID: ownerID)
            guard isCurrentOwner(ownerID, generation: generation), !Task.isCancelled else { return }
            projects.removeAll { $0.id == project.id }
            if workspace?.id == project.id {
                workspace = nil
                selectedFilePath = nil
                editorText = ""
                if let first = projects.first { open(first) }
            }
        } catch {
            guard isCurrentOwner(ownerID, generation: generation), !Task.isCancelled else { return }
            errorMessage = message(for: error)
        }
    }

    func selectFile(path: String?) {
        synchronizeOwner()
        commitEditorText()
        selectedFilePath = path
        editorText = workspace?.files.first { $0.path == path }?.content ?? ""
    }

    func updateEditorText(_ text: String) {
        synchronizeOwner()
        editorText = text
        guard var workspace, let selectedFilePath,
              let index = workspace.files.firstIndex(where: { $0.path == selectedFilePath })
        else { return }
        workspace.files[index] = CodeFile(path: selectedFilePath, content: text)
        workspace.updatedAt = Date()
        self.workspace = workspace
        upsert(workspace)
        scheduleSave(workspace)
    }

    func addAttachments(_ urls: [URL], language: AppLanguage) {
        synchronizeOwner()
        guard !urls.isEmpty, attachmentTask == nil else { return }
        isReadingAttachments = true
        errorMessage = nil
        let ownerID = session.identityID ?? "guest"
        let generation = ownerGeneration
        attachmentTask = Task {
            defer {
                if generation == self.ownerGeneration {
                    self.isReadingAttachments = false
                    self.attachmentTask = nil
                }
            }
            for url in urls {
                if Task.isCancelled { return }
                do {
                    let document = try await BrainDocumentExtractor.extract(url: url)
                    guard !Task.isCancelled, self.isCurrentOwner(ownerID, generation: generation) else { return }
                    let context = String(document.contextText.prefix(48_000))
                    let attachment = CodeAttachment(
                        id: UUID().uuidString.lowercased(),
                        name: url.lastPathComponent,
                        context: context
                    )
                    self.attachments.append(attachment)
                } catch {
                    guard !Task.isCancelled, self.isCurrentOwner(ownerID, generation: generation) else { return }
                    self.errorMessage = self.attachmentMessage(for: error, language: language)
                }
            }
        }
    }

    func removeAttachment(_ attachment: CodeAttachment) {
        synchronizeOwner()
        attachments.removeAll { $0.id == attachment.id }
    }

    func startBuild(
        projectName: String,
        prompt: String,
        modelGeneration: ModelGeneration = .shippingDefault,
        language: AppLanguage
    ) {
        synchronizeOwner()
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty, canBuild else { return }
        guard cleanPrompt.utf16.count <= 60_000 else {
            errorMessage = language == .arabic ? "الطلب أطول من الحد المدعوم. قسّمه دون حذف شروطك." : "The request is too long. Split it without dropping your constraints."
            return
        }
        guard session.isAuthenticated, let ownerID = session.identityID else {
            errorMessage = language == .arabic
                ? "سجّل الدخول لبناء مشروع وحفظه في السحابة."
                : "Sign in to build a project and keep it running in the cloud."
            return
        }
        let cleanName = normalizedName(projectName, fallback: suggestedName(cleanPrompt, language: language))
        let attachmentContext = attachments.map {
            "[Attachment: \($0.name)]\n\($0.context)"
        }.joined(separator: "\n\n")
        let pointer = CodeBuildPointer(
            ownerID: ownerID,
            jobID: nil,
            cid: stableIdentifier(),
            projectName: cleanName,
            prompt: cleanPrompt,
            attachmentContext: String(attachmentContext.prefix(80_000)),
            language: language,
            startedAt: Date(),
            modelGeneration: modelGeneration
        )

        isBuilding = true
        activeJobID = nil
        buildPhase = .queued
        buildProgress = nil
        buildStartedAt = pointer.startedAt
        buildingProjectName = pointer.projectName
        isStoppingBuild = false
        awaitingRecovery = false
        errorMessage = nil
        buildNotice = nil
        lastResponse = nil
        // Remembered unclassified before the classifier is asked, so a press
        // survives the app being closed meanwhile: resumeIfNeeded classifies
        // it again at the next launch.
        persist(pointer)
        classifyingCID = pointer.cid

        // Store-owned: leaving the Code screen only removes the viewer. It
        // never cancels the durable server build.
        let generation = ownerGeneration
        owningTask = Task {
            let context = IntentContext(product: "code", history: self.intentHistory, projectFiles: self.workspace?.files.map(\.path) ?? [])
            let decision = (try? await self.api.classifyIntent(text: cleanPrompt, context: context)) ?? .unavailable
            guard self.isCurrentOwner(ownerID, generation: generation), !Task.isCancelled else { return }
            if self.classifyingCID == pointer.cid { self.classifyingCID = nil }
            // Stopped before admission: nothing was submitted, and Stop already
            // removed the pointer.
            if self.isStoppingBuild {
                self.endBuild(ownerID: ownerID, phase: nil)
                return
            }
            var classifiedPointer = pointer
            // The reader pressed Build. Only a validated verdict that this is not
            // a browser project turns the press into a reply. A classifier that
            // could not answer (timeout, 503, 429, an unreadable verdict) proves
            // nothing, so the press stays a build, never a silent chat turn.
            classifiedPointer.replyOnly = decision.isValidated && !decision.permitsBrowserBuild
            classifiedPointer.intentInstruction = decision.conversationInstruction
            self.persist(classifiedPointer)
            await self.enqueueAndPoll(classifiedPointer, generation: generation)
        }
    }

    func resumeIfNeeded() {
        synchronizeOwner()
        // A Stop that is still asking the server owns the build until it ends.
        guard owningTask == nil, activeJobID == nil, !isStoppingBuild else { return }
        guard let ownerID = session.identityID,
              let pointer = persistedPointer(for: ownerID)
        else { return }

        buildPointer = pointer
        isBuilding = true
        activeJobID = pointer.jobID
        buildPhase = .queued
        buildStartedAt = pointer.startedAt
        buildingProjectName = pointer.projectName
        isStoppingBuild = false
        awaitingRecovery = false
        errorMessage = nil
        buildNotice = nil
        let generation = ownerGeneration
        owningTask = Task {
            if pointer.jobID == nil {
                var prepared = pointer
                if prepared.replyOnly == nil {
                    // A press closed before its classifier answered (or an older
                    // app version's pending build). Reclassify before admission.
                    let result = (try? await self.api.classifyIntent(text: pointer.prompt,
                        context: IntentContext(product: "code"))) ?? .unavailable
                    guard self.isCurrentOwner(ownerID, generation: generation), !Task.isCancelled else { return }
                    // A Stop meanwhile is settled by enqueueAndPoll: an older
                    // launch may already have submitted this cid.
                    // Same rule as startBuild: an unavailable verdict stays a build.
                    prepared.replyOnly = result.isValidated && !result.permitsBrowserBuild
                    prepared.intentInstruction = result.conversationInstruction
                    self.persist(prepared)
                }
                await self.enqueueAndPoll(prepared, generation: generation)
            } else {
                await self.poll(pointer, generation: generation)
            }
        }
    }

    func clearBuildState() {
        synchronizeOwner()
        guard !isBuilding else { return }
        activeJobID = nil
        buildPhase = nil
        buildProgress = nil
        buildStartedAt = nil
        buildingProjectName = ""
        errorMessage = nil
        buildNotice = nil
    }

    /// The build card's Stop: the only Code path that cancels a cloud build.
    /// Leaving the screen or switching accounts never reaches it.
    func stopBuild() async {
        synchronizeOwner()
        guard isBuilding, !isStoppingBuild, let ownerID = session.identityID else { return }
        isStoppingBuild = true
        errorMessage = nil
        buildNotice = nil
        guard let jobID = activeJobID else {
            // A new press the classifier has not answered has submitted
            // nothing. Its pointer goes now, so closing the app before that
            // answer cannot bring the stopped build back at the next launch.
            if let cid = classifyingCID, persistedPointer(for: ownerID)?.cid == cid {
                removePersistedPointer(for: ownerID)
            }
            // No job id yet. A watcher still classifying or submitting sees the
            // stop at its next step. One waiting out a failed admission is idle,
            // so Stop takes over here: that admission may still have reached the
            // server, and the cid's receipt says whether a job is running.
            guard awaitingRecovery else { return }
            let watcher = owningTask
            owningTask = nil
            awaitingRecovery = false
            watcher?.cancel()
            guard let pointer = buildPointer else {
                endBuild(ownerID: ownerID, phase: nil)
                return
            }
            let generation = ownerGeneration
            let stopped = await stopUnadmitted(pointer, generation: generation)
            // Unconfirmed: keep recovering the same cid, exactly as before Stop.
            if !stopped, owningTask == nil, isBuilding, isCurrentOwner(ownerID, generation: generation) {
                owningTask = Task { await self.enqueueAndPoll(pointer, generation: generation) }
            }
            return
        }
        // The watcher goes first, so a poll that lands while the cancel is in
        // flight cannot report the stopped build as failed or apply a project.
        let watcher = owningTask
        owningTask = nil
        watcher?.cancel()
        await sendStop(ownerID: ownerID, jobID: jobID, generation: ownerGeneration)
    }

    /// Sends one cancel for an admitted build. Returns false only when the
    /// server could not be reached: the build may still be running, so it
    /// stays watched and the reader can press Stop again.
    @discardableResult
    private func sendStop(ownerID: String, jobID: String, generation: Int) async -> Bool {
        stopRequestedJobID = jobID
        do {
            _ = try await api.cancelChatJob(id: jobID)
        } catch {
            guard isCurrentOwner(ownerID, generation: generation), activeJobID == jobID else { return true }
            // 404, 409 and 410 all mean the server has no running build under
            // this id, so there is nothing left to stop.
            if ![404, 409, 410].contains((error as? APIError)?.statusCode ?? 0) {
                isStoppingBuild = false
                buildNotice = .stopUnconfirmed
                // Restarted from memory, so a pointer the defaults cannot read
                // back still leaves the build watched.
                if owningTask == nil, let pointer = buildPointer, pointer.jobID == jobID {
                    owningTask = Task { await self.poll(pointer, generation: generation) }
                }
                return false
            }
        }
        guard isCurrentOwner(ownerID, generation: generation), activeJobID == jobID else { return true }
        endBuild(ownerID: ownerID, phase: nil)
        return true
    }

    /// Stop before this device has a job id. A submission whose answer was lost
    /// may still have been admitted under the build's cid, so the server's
    /// read-only receipt decides: a job it names is cancelled like any other,
    /// and no receipt means nothing is running. Returns false only when the
    /// server could not answer; the build then goes on as it was.
    private func stopUnadmitted(_ pointer: CodeBuildPointer, generation: Int) async -> Bool {
        let receipt: ChatJobReceipt
        do {
            let credentials = try await api.mediaCredentialSnapshot()
            guard isCurrentOwner(pointer.ownerID, generation: generation) else { return true }
            receipt = try await MediaCredentialScope.$current.withValue(credentials) {
                try await api.chatJobReceipt(cid: pointer.cid)
            }
        } catch {
            guard isCurrentOwner(pointer.ownerID, generation: generation) else { return true }
            isStoppingBuild = false
            buildNotice = .stopUnconfirmed
            return false
        }
        guard isCurrentOwner(pointer.ownerID, generation: generation) else { return true }
        guard !receipt.jobId.isEmpty, receipt.phase != .unknown else {
            endBuild(ownerID: pointer.ownerID, phase: nil)
            return true
        }
        persist(pointer.with(jobID: receipt.jobId))
        activeJobID = receipt.jobId
        return await sendStop(ownerID: pointer.ownerID, jobID: receipt.jobId, generation: generation)
    }

    private func enqueueAndPoll(_ initialPointer: CodeBuildPointer, generation: Int) async {
        guard isCurrentOwner(initialPointer.ownerID, generation: generation) else { return }

        var recoveryAttempt = 0
        var serverRecoveryFailures = 0
        while !Task.isCancelled {
            guard isCurrentOwner(initialPointer.ownerID, generation: generation) else { return }
            awaitingRecovery = false
            // Stop before a job id. An earlier attempt, here or in an earlier
            // launch, may have been admitted under this cid: its receipt decides.
            if isStoppingBuild, await stopUnadmitted(initialPointer, generation: generation) { return }
            do {
                if initialPointer.replyOnly != true {
                    _ = try await api.chargeUsage(product: .code, cid: initialPointer.cid)
                    guard isCurrentOwner(initialPointer.ownerID, generation: generation),
                          !Task.isCancelled else { return }
                    // Nothing is submitted after Stop. Admitting the build only to
                    // cancel it would bill the job as well, and Stop refunds nothing.
                    if isStoppingBuild, await stopUnadmitted(initialPointer, generation: generation) { return }
                }
                let joinedMessage = initialPointer.prompt + (
                    initialPointer.attachmentContext.isEmpty
                        ? "" : "\n\n" + initialPointer.attachmentContext
                )
                let request = ChatJobRequest(
                    messages: (initialPointer.replyOnly == true ? [ChatMessage(role: .system,
                        content: initialPointer.intentInstruction ?? IntentDecision.unavailable.conversationInstruction)] : []) + [
                        ChatMessage(
                            role: .user,
                            content: joinedMessage,
                            generation: initialPointer.modelGeneration ?? .legacy,
                            lang: initialPointer.language.rawValue
                        )
                    ],
                    tier: .pro,
                    generation: initialPointer.modelGeneration ?? .legacy,
                    thinking: true,
                    cid: initialPointer.cid,
                    product: initialPointer.replyOnly == true ? .ai : .code,
                    kind: initialPointer.replyOnly == true ? .chat : .codeBuild,
                    languageCode: initialPointer.language.rawValue,
                    task: initialPointer.prompt,
                    name: initialPointer.projectName,
                    attach: initialPointer.attachmentContext
                )
                let start = try await startJobWithRetry(request, ownerID: initialPointer.ownerID, generation: generation)
                guard isCurrentOwner(initialPointer.ownerID, generation: generation), !Task.isCancelled else { return }
                let pointer = initialPointer.with(jobID: start.jobId)
                persist(pointer)
                activeJobID = start.jobId
                // Stop was pressed while this job was being admitted; its id
                // exists only now. If the cancel did not land, keep watching.
                if isStoppingBuild {
                    let stopped = await sendStop(ownerID: pointer.ownerID, jobID: start.jobId, generation: generation)
                    if stopped { return }
                }
                if !start.phase.isTerminal {
                    buildPhase = start.phase
                }
                buildProgress = start.progress
                requestCompletionNotifications(language: initialPointer.language)
                if start.phase.isTerminal, let text = start.text {
                    await applyProjectIfComplete(text, pointer: pointer, generation: generation)
                }
                if isBuilding, isCurrentOwner(pointer.ownerID, generation: generation) {
                    await poll(pointer, generation: generation)
                }
                return
            } catch {
                guard isCurrentOwner(initialPointer.ownerID, generation: generation), !Task.isCancelled else { return }
                if isStoppingBuild {
                    // A refused submission admitted nothing. One whose answer was
                    // lost may have been admitted, so its receipt decides.
                    guard retryable(error) else {
                        endBuild(ownerID: initialPointer.ownerID, phase: nil)
                        return
                    }
                    if await stopUnadmitted(initialPointer, generation: generation) { return }
                } else {
                    errorMessage = message(for: error)
                }
                guard retryable(error) else {
                    removePersistedPointer(for: initialPointer.ownerID)
                    isBuilding = false
                    activeJobID = nil
                    owningTask = nil
                    return
                }

                // Keep one durable build identity across a lost response or
                // connection. The server and usage ledger deduplicate cid.
                recoveryAttempt += 1
                // Bounded: an admission the server keeps refusing would otherwise
                // hold Build disabled on this launch and every later one. The
                // reader is told in their language, not with the raw last error.
                // A transport error does not count: the lost submission may
                // already be a charged build that this cid recovers once the
                // network returns, and Stop ends the wait.
                if !isTransport(error) { serverRecoveryFailures += 1 }
                guard serverRecoveryFailures <= Self.maximumRecoveryAttempts else {
                    endBuild(ownerID: initialPointer.ownerID, phase: .failed)
                    errorMessage = nil
                    buildNotice = .couldNotQueue
                    return
                }
                isBuilding = true
                buildPhase = .queued
                awaitingRecovery = true
                do {
                    try await Task.sleep(for: recoveryDelay(attempt: recoveryAttempt))
                } catch {
                    return
                }
            }
        }
    }

    private func poll(_ pointer: CodeBuildPointer, generation: Int) async {
        guard isCurrentOwner(pointer.ownerID, generation: generation) else { return }
        guard let jobID = pointer.jobID else { return }
        activeJobID = jobID
        var failures = 0
        var unknowns = 0
        var terminalWithoutProject = 0
        let pollingBegan = Date()

        while !Task.isCancelled {
            guard isCurrentOwner(pointer.ownerID, generation: generation) else { return }

            do {
                let status = try await api.chatJobStatus(id: jobID)
                guard isCurrentOwner(pointer.ownerID, generation: generation), !Task.isCancelled else { return }
                failures = 0
                if !status.phase.isTerminal {
                    buildPhase = status.phase
                    buildProgress = status.progress
                }

                if status.phase == .unknown {
                    unknowns += 1
                    // The server answers "unknown" once a job record has expired
                    // (six hours after the job ends). Asking again cannot bring
                    // the build back, and the pointer would revive it every launch.
                    if unknowns >= Self.unknownJobLimit {
                        finishExpired(pointer)
                        return
                    }
                } else {
                    unknowns = 0
                }

                if status.phase.isTerminal {
                    if status.phase.succeeded {
                        if let text = status.text, !text.isEmpty {
                            await applyProjectIfComplete(text, pointer: pointer, generation: generation)
                            guard isCurrentOwner(pointer.ownerID, generation: generation) else { return }
                            if !isBuilding { return }
                        }
                        terminalWithoutProject += 1
                        if terminalWithoutProject > 15 {
                            await finishFailed(
                                pointer,
                                message: pointer.language == .english
                                    ? "The build finished without a readable Firas project. Try again."
                                    : "انتهى البناء دون مشروع فِراس صالح للقراءة. أعد المحاولة.",
                                generation: generation
                            )
                            return
                        }
                    } else if status.error == "cancelled", stopRequestedJobID == jobID {
                        // A Stop whose answer was lost still landed: the build
                        // ended as the reader asked, not as a failure.
                        endBuild(ownerID: pointer.ownerID, phase: nil)
                        buildNotice = nil
                        return
                    } else {
                        await finishFailed(pointer, message: readableBuildError(status.error, language: pointer.language),
                                           generation: generation)
                        return
                    }
                }
            } catch {
                guard isCurrentOwner(pointer.ownerID, generation: generation), !Task.isCancelled else { return }
                // 404 and 410 name a job the server no longer has. A transport
                // error or a 5xx says nothing about the job: keep watching.
                if [404, 410].contains((error as? APIError)?.statusCode ?? 0) {
                    finishExpired(pointer)
                    return
                }
                failures += 1
                if failures >= 3 { errorMessage = message(for: error) }
            }

            let elapsed = Date().timeIntervalSince(pollingBegan)
            let delay: Duration
            if terminalWithoutProject > 0 {
                delay = .seconds(4)
            } else if elapsed < 25 {
                delay = .milliseconds(850)
            } else if elapsed < 180 {
                delay = .milliseconds(1_500)
            } else {
                delay = .seconds(3)
            }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
        }
    }

    private func applyProjectIfComplete(
        _ text: String,
        pointer: CodeBuildPointer,
        generation: Int
    ) async {
        guard isCurrentOwner(pointer.ownerID, generation: generation), !Task.isCancelled else { return }
        if pointer.replyOnly == true {
            rememberIntentResult(prompt: pointer.prompt, response: text)
            lastResponse = text
            removePersistedPointer(for: pointer.ownerID)
            isBuilding = false; activeJobID = nil; buildPhase = .completed; buildProgress = nil; owningTask = nil
            buildNotice = nil
            return
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            try? CodeProject.decode(fromJobText: text)
        }.value
        guard isCurrentOwner(pointer.ownerID, generation: generation), !Task.isCancelled else { return }
        guard let project = decoded, !project.files.isEmpty else {
            // A server-classified non-build answer is a result, not a missing HTML project.
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !text.contains("```firas-project") {
                rememberIntentResult(prompt: pointer.prompt, response: text)
                lastResponse = text
                removePersistedPointer(for: pointer.ownerID)
                isBuilding = false; activeJobID = nil; buildPhase = .completed; buildProgress = nil; owningTask = nil
                buildNotice = nil
            }
            return
        }
        guard await FirasCompletionCue.prepareForReveal(
            product: .code,
            jobID: pointer.jobID ?? pointer.cid
        ),
        !Task.isCancelled,
        isCurrentOwner(pointer.ownerID, generation: generation)
        else { return }

        let workspace = CodeWorkspaceProject(
            name: normalizedName(project.name, fallback: pointer.projectName),
            files: project.files
        )
        rememberIntentResult(prompt: pointer.prompt, response: "Created project \(workspace.name) with files: \(workspace.files.map(\.path).joined(separator: ", "))")
        // The open file belongs to the project on screen. Commit its edit there
        // while that project is still current, then forget it: selectFile would
        // otherwise write it over the new project's file of the same path
        // (usually index.html) and save the damaged copy.
        commitEditorText()
        selectedFilePath = nil
        editorText = ""
        self.workspace = workspace
        upsert(workspace)
        selectFile(path: preferredEntry(in: workspace.files))
        do {
            try await repository.save(workspace, ownerID: pointer.ownerID)
        } catch {
            guard isCurrentOwner(pointer.ownerID, generation: generation), !Task.isCancelled else { return }
            errorMessage = message(for: error)
        }
        guard isCurrentOwner(pointer.ownerID, generation: generation), !Task.isCancelled else { return }
        await NotificationCoordinator.shared.scheduleLocalFallbackIfNeeded(
            product: .code,
            jobID: pointer.jobID ?? pointer.cid,
            chatID: nil,
            outcome: .completed
        )
        guard isCurrentOwner(pointer.ownerID, generation: generation), !Task.isCancelled else { return }
        removePersistedPointer(for: pointer.ownerID)
        isBuilding = false
        activeJobID = nil
        buildPhase = .completed
        buildProgress = nil
        owningTask = nil
        attachments = []
        // A notice from an unconfirmed Stop described a build that has now ended.
        buildNotice = nil
    }

    private func finishFailed(_ pointer: CodeBuildPointer, message: String, generation: Int) async {
        guard await FirasCompletionCue.prepareForReveal(
            product: .code,
            jobID: pointer.jobID ?? pointer.cid
        ),
        !Task.isCancelled,
        isCurrentOwner(pointer.ownerID, generation: generation)
        else { return }

        await NotificationCoordinator.shared.scheduleLocalFallbackIfNeeded(
            product: .code,
            jobID: pointer.jobID ?? pointer.cid,
            chatID: nil,
            outcome: .failed
        )
        guard isCurrentOwner(pointer.ownerID, generation: generation), !Task.isCancelled else { return }
        removePersistedPointer(for: pointer.ownerID)
        isBuilding = false
        activeJobID = nil
        buildPhase = .failed
        owningTask = nil
        errorMessage = message
        buildNotice = nil
    }

    private func finishExpired(_ pointer: CodeBuildPointer) {
        endBuild(ownerID: pointer.ownerID, phase: .failed)
        errorMessage = nil
        buildNotice = .expired
    }

    /// Ends this device's part in a build that will deliver nothing more. The
    /// pointer goes too, so the next launch does not resume it.
    private func endBuild(ownerID: String, phase: ChatJobPhase?) {
        removePersistedPointer(for: ownerID)
        isBuilding = false
        isStoppingBuild = false
        awaitingRecovery = false
        stopRequestedJobID = nil
        activeJobID = nil
        buildPhase = phase
        buildProgress = nil
        owningTask = nil
    }

    private func rememberIntentResult(prompt: String, response: String) {
        let references = intentHistory + [IntentReference(role: "user", content: prompt),
            IntentReference(role: "assistant", content: response)]
        intentHistory = IntentContext(product: "code", history: references).history
    }

    private func startJobWithRetry(_ request: ChatJobRequest, ownerID: String, generation: Int) async throws -> ChatJobStartResponse {
        let delays: [Duration] = [.milliseconds(350), .milliseconds(800)]
        for attempt in 0...delays.count {
            guard isCurrentOwner(ownerID, generation: generation), !Task.isCancelled else { throw CancellationError() }
            do {
                return try await api.startChatJob(request)
            } catch {
                // After Stop nothing new is submitted: the caller asks the
                // server what the last submission did instead.
                guard attempt < delays.count, retryable(error), !isStoppingBuild else { throw error }
                try await Task.sleep(for: delays[attempt])
                if isStoppingBuild { throw error }
            }
        }
        throw APIError.transport(code: -1, message: "The Code build could not be queued.")
    }

    private func retryable(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        return switch apiError {
        case .transport:
            true
        case .httpStatus(let code, _):
            (500...599).contains(code)
        case .invalidResponse, .decoding:
            true
        case .invalidURL, .invalidRequest, .encoding, .skillValidation:
            false
        }
    }

    private func isTransport(_ error: Error) -> Bool {
        guard let apiError = error as? APIError, case .transport = apiError else { return false }
        return true
    }

    private func recoveryDelay(attempt: Int) -> Duration {
        switch attempt {
        case ...1: .seconds(2)
        case 2: .seconds(4)
        case 3: .seconds(8)
        default: .seconds(15)
        }
    }

    private func requestCompletionNotifications(language: AppLanguage) {
        Task {
            _ = await NotificationCoordinator.shared.requestAuthorizationIfNeeded(
                context: .durableJobStarted,
                preferredLanguageCode: language.rawValue
            )
        }
    }

    private func commitEditorText() {
        guard var workspace, let selectedFilePath,
              let index = workspace.files.firstIndex(where: { $0.path == selectedFilePath }),
              workspace.files[index].content != editorText
        else { return }
        workspace.files[index] = CodeFile(path: selectedFilePath, content: editorText)
        workspace.updatedAt = Date()
        self.workspace = workspace
        upsert(workspace)
        save(workspace)
    }

    private func scheduleSave(_ project: CodeWorkspaceProject) {
        saveTask?.cancel()
        let ownerID = loadedOwnerID ?? "guest"
        let generation = ownerGeneration
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(550))
                try await self.repository.save(project, ownerID: ownerID)
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentOwner(ownerID, generation: generation) else { return }
                self.errorMessage = self.message(for: error)
            }
        }
    }

    private func save(_ project: CodeWorkspaceProject) {
        saveTask?.cancel()
        let ownerID = loadedOwnerID ?? "guest"
        let generation = ownerGeneration
        saveTask = Task {
            do {
                try await self.repository.save(project, ownerID: ownerID)
            } catch {
                guard self.isCurrentOwner(ownerID, generation: generation) else { return }
                self.errorMessage = self.message(for: error)
            }
        }
    }

    private func upsert(_ project: CodeWorkspaceProject) {
        projects.removeAll { $0.id == project.id }
        projects.append(project)
        projects.sort { $0.updatedAt > $1.updatedAt }
    }

    private func preferredEntry(in files: [CodeFile]) -> String? {
        files.first { $0.path.lowercased().hasSuffix("index.html") }?.path
            ?? files.first?.path
    }

    private func normalizedName(_ value: String, fallback: String) -> String {
        let clean = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return String((clean.isEmpty ? fallback : clean).prefix(80))
    }

    private func suggestedName(_ prompt: String, language: AppLanguage) -> String {
        let words = prompt.split(whereSeparator: { $0.isWhitespace }).prefix(5)
        let name = words.joined(separator: " ")
        if !name.isEmpty { return String(name.prefix(56)) }
        return language == .arabic ? "مشروع فِراس" : "Firas project"
    }

    private func stableIdentifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func finishLocalOwnership() {
        isBuilding = false
        isStoppingBuild = false
        awaitingRecovery = false
        buildPointer = nil
        stopRequestedJobID = nil
        classifyingCID = nil
        activeJobID = nil
        buildPhase = nil
        buildProgress = nil
        owningTask = nil
        errorMessage = nil
        buildNotice = nil
    }

    private func isCurrentOwner(_ expectedOwnerID: String, generation: Int) -> Bool {
        synchronizeOwner()
        return ownerGeneration == generation && (session.identityID ?? "guest") == expectedOwnerID
    }

    private func pointerMap() -> [String: CodeBuildPointer] {
        guard let data = defaults.data(forKey: Self.pointerMapKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CodeBuildPointer].self, from: data)) ?? [:]
    }

    private func persistedPointer(for ownerID: String) -> CodeBuildPointer? {
        pointerMap()[ownerID]
    }

    private func persist(_ pointer: CodeBuildPointer) {
        buildPointer = pointer
        var map = pointerMap()
        map[pointer.ownerID] = pointer
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: Self.pointerMapKey)
    }

    private func removePersistedPointer(for ownerID: String) {
        buildPointer = nil
        var map = pointerMap()
        map.removeValue(forKey: ownerID)
        if map.isEmpty {
            defaults.removeObject(forKey: Self.pointerMapKey)
        } else if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: Self.pointerMapKey)
        }
    }

    private func attachmentMessage(for error: Error, language: AppLanguage) -> String {
        guard let extraction = error as? BrainExtractionError else { return message(for: error) }
        switch extraction {
        case .officeNeedsExport(let kind):
            return language == .arabic
                ? "صدّر ملف \(kind.rawValue.uppercased()) إلى PDF أو نص قبل إرفاقه."
                : "Export the \(kind.rawValue.uppercased()) file as PDF or text before attaching it."
        case .emptyDocument:
            return language == .arabic
                ? "لم يُعثر على نص قابل للقراءة في المرفق."
                : "No readable text was found in the attachment."
        case .unreadableDocument:
            return language == .arabic ? "تعذّرت قراءة المرفق." : "The attachment could not be read."
        case .unsupportedType(let ext):
            return language == .arabic
                ? "نوع المرفق .\(ext) غير مدعوم."
                : ".\(ext) attachments are not supported."
        }
    }

    /// Short next-step text in the app language, worded as Chat words it: by
    /// HTTP status, server code or connection problem. Server and system text
    /// is never shown.
    private func message(for error: Error) -> String {
        let english = defaults.string(forKey: "lang") == AppLanguage.english.rawValue
        guard let apiError = error as? APIError else { return FirasErrorText.generic(english: english) }
        switch apiError {
        case .httpStatus(let status, let message):
            let code: String? = message
            return FirasErrorText.text(status: status, code: code, english: english)
                ?? FirasErrorText.generic(english: english)
        case .transport(let code, _):
            return FirasErrorText.connection(code: code, english: english)
        case .invalidRequest(let code):
            return FirasErrorText.text(code: code, english: english) ?? FirasErrorText.generic(english: english)
        case .invalidResponse, .decoding:
            return FirasErrorText.unexpectedResponse(english: english)
        case .invalidURL, .encoding, .skillValidation:
            return FirasErrorText.generic(english: english)
        }
    }

    /// A failed job's record may be `{"error": code, "message": notice}`. Its
    /// notice or its code's text is shown in the build's language, never the
    /// raw record.
    private func readableBuildError(_ value: String?, language: AppLanguage) -> String {
        let english = language == .english
        var code = value
        var notice: String?
        if let value, value.first == "{", let data = value.data(using: .utf8),
           let object = try? JSONDecoder().decode([String: AppAPIValue].self, from: data) {
            code = nil
            if case .string(let saved)? = object["error"] { code = saved }
            if case .string(let saved)? = object["message"] { notice = saved }
        }
        return FirasErrorText.text(code: code, notice: notice, english: english)
            ?? (english ? "The build did not finish. Try again." : "لم يكتمل البناء. أعد المحاولة.")
    }

    private static func blankFiles(projectName: String, language: AppLanguage) -> [CodeFile] {
        let heading = language == .arabic ? "مرحباً من \(projectName)" : "Hello from \(projectName)"
        return [
            CodeFile(
                path: "index.html",
                content: """
                <!doctype html>
                <html lang="\(language.rawValue)" dir="\(language == .arabic ? "rtl" : "ltr")">
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1">
                  <title>\(projectName)</title>
                  <link rel="stylesheet" href="styles.css">
                </head>
                <body>
                  <main><h1>\(heading)</h1></main>
                  <script src="app.js"></script>
                </body>
                </html>
                """
            ),
            CodeFile(
                path: "styles.css",
                content: "body { margin: 0; min-height: 100vh; display: grid; place-items: center; font-family: system-ui, sans-serif; background: #101312; color: #f2f2ee; }"
            ),
            CodeFile(path: "app.js", content: "console.log('Firas Code ready');")
        ]
    }
}

actor CodeProjectRepository {
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("FirasAI/CodeProjects", isDirectory: true)
        }
    }

    func loadAll(ownerID: String) throws -> [CodeWorkspaceProject] {
        let directory = try ownerDirectory(ownerID)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let project = try? decoder.decode(CodeWorkspaceProject.self, from: data)
            else { return nil }
            return project
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ project: CodeWorkspaceProject, ownerID: String) throws {
        let directory = try ownerDirectory(ownerID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        try data.write(to: url(for: project.id, in: directory), options: .atomic)
    }

    func delete(id: String, ownerID: String) throws {
        let directory = try ownerDirectory(ownerID)
        let target = url(for: id, in: directory)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    private func ownerDirectory(_ ownerID: String) throws -> URL {
        let digest = SHA256.hash(data: Data(ownerID.utf8)).map { String(format: "%02x", $0) }.joined()
        let target = directory.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    private func url(for id: String, in directory: URL) -> URL {
        let safeID = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent(safeID + ".json", isDirectory: false)
    }
}

private nonisolated enum CodePreviewBuilder {
    static func html(from files: [CodeFile]) -> String? {
        guard let entry = files.first(where: { $0.path.lowercased().hasSuffix("index.html") })
            ?? files.first(where: { $0.path.lowercased().hasSuffix(".html") })
        else { return nil }
        var html = entry.content
        let lookup = files.reduce(into: [String: String]()) { result, file in
            let key = normalized(file.path)
            if result[key] == nil { result[key] = file.content }
        }

        html = replacingMatches(
            in: html,
            pattern: #"<link\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>"#
        ) { match, source in
            guard let reference = capture(1, from: match, in: source),
                  reference.lowercased().hasSuffix(".css"),
                  let content = resolved(reference, lookup: lookup)
            else { return matchText(match, in: source) }
            return "<style>\n\(content)\n</style>"
        }

        html = replacingMatches(
            in: html,
            pattern: #"<script\b[^>]*src=[\"']([^\"']+)[\"'][^>]*>\s*</script>"#
        ) { match, source in
            guard let reference = capture(1, from: match, in: source),
                  let content = resolved(reference, lookup: lookup)
            else { return matchText(match, in: source) }
            return "<script>\n\(content)\n</script>"
        }
        return html
    }

    private static func resolved(_ reference: String, lookup: [String: String]) -> String? {
        let clean = normalized(reference.split(separator: "?", maxSplits: 1).first.map(String.init) ?? reference)
        if let exact = lookup[clean] { return exact }
        let basename = clean.split(separator: "/").last.map(String.init)
        return lookup.first { key, _ in key.split(separator: "/").last.map(String.init) == basename }?.value
    }

    private static func normalized(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/."))
            .lowercased()
    }

    private static func replacingMatches(
        in value: String,
        pattern: String,
        replacement: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return value
        }
        let source = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: source.length))
        var result = value
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement(match, source))
        }
        return result
    }

    private static func capture(
        _ index: Int,
        from match: NSTextCheckingResult,
        in source: NSString
    ) -> String? {
        guard index < match.numberOfRanges, match.range(at: index).location != NSNotFound else { return nil }
        return source.substring(with: match.range(at: index))
    }

    private static func matchText(_ match: NSTextCheckingResult, in source: NSString) -> String {
        source.substring(with: match.range)
    }
}

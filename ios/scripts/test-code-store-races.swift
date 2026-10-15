import Foundation

@main
@MainActor enum CodeStoreRaceTests {
    static func main() async throws {
        let session = SessionStore()
        let api = FirasAPI()
        let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("firas-code-race-" + UUID().uuidString, isDirectory: true)
        let repository = CodeProjectRepository(directory: testDirectory)
        let defaults = UserDefaults(suiteName: "firas-code-race-test-" + UUID().uuidString)!
        let store = CodeStore(session: session, api: api, defaults: defaults, repository: repository)
        let secondAccountProject = CodeWorkspaceProject(id: "second-account-project", name: "Second account", files: [CodeFile(path: "notes.txt", content: "Owned by account two")])
        try await repository.save(secondAccountProject, ownerID: "owner-two")
        await store.loadProjects()
        store.createBlank(name: "Old account draft", language: .english)
        store.updateEditorText("Latest edit before account switch")
        store.startBuild(projectName: "Old request", prompt: "Explain something", language: .english)
        try await waitUntil { api.pendingStarts.count == 1 }
        precondition(api.starts[0].mgen == "1.1", "Code captures the website's current model generation")

        session.identityID = "owner-two"
        var loadedNewAccount = false
        let loading = Task {
            await store.loadProjects()
            loadedNewAccount = true
        }
        // The old server-start response deliberately stays unresolved here.
        // A new account's library must load independently of that response.
        try await waitUntil { loadedNewAccount }
        await loading.value
        precondition(store.projects.map(\.id) == [secondAccountProject.id], "new account's local library loads without waiting for the old job")
        precondition(store.canBuild && !store.isBuilding, "new account can immediately start its own request")
        store.startBuild(projectName: "New request", prompt: "Explain the new topic", language: .english)
        try await waitUntil { api.pendingStarts.count == 2 }
        api.resolveStart(jobID: "old-job")
        try await Task.sleep(for: .milliseconds(20))
        precondition(store.isBuilding && store.buildingProjectName == "New request", "stale old response cannot clear the new request")
        precondition(api.cancelledJobs.isEmpty, "switching account does not cancel a cloud build")
        api.resolveStart(jobID: "new-job", phase: .completed, text: "The new account's answer")
        try await waitUntil { !store.isBuilding }
        precondition(store.lastResponse == "The new account's answer", "new result reaches only the current account")
        precondition(store.projects.map(\.id) == [secondAccountProject.id], "old request cannot replace the current account's files")
        var preservedOldEdit = false
        for _ in 0..<500 {
            let oldProjects = try await repository.loadAll(ownerID: "owner-one")
            if oldProjects.contains(where: { $0.files.contains(where: { $0.content == "Latest edit before account switch" }) }) {
                preservedOldEdit = true
                break
            }
            try await Task.sleep(for: .milliseconds(4))
        }
        precondition(preservedOldEdit, "switching account preserves the last debounced edit under the old owner")
        // Exact test-created UUID directory only; no application storage is touched.
        try FileManager.default.removeItem(at: testDirectory)

        let scenarioRoot = FileManager.default.temporaryDirectory.appendingPathComponent("firas-code-build-" + UUID().uuidString, isDirectory: true)

        // STORE-1: a build that finishes while another project is open must not
        // receive that project's editor text in its own index.html.
        let (overwriteAPI, overwriteDefaults, overwriteRepository) = scenario("overwrite", under: scenarioRoot)
        let overwriteStore = CodeStore(session: SessionStore(), api: overwriteAPI, defaults: overwriteDefaults, repository: overwriteRepository)
        await overwriteStore.loadProjects()
        overwriteStore.createBlank(name: "Old project", language: .english)
        guard let oldProjectID = overwriteStore.workspace?.id else { preconditionFailure("blank project opens") }
        overwriteStore.updateEditorText("<p>old project edit</p>")
        overwriteStore.startBuild(projectName: "New site", prompt: "Build a landing page", language: .english)
        try await waitUntil { overwriteAPI.pendingStarts.count == 1 }
        overwriteAPI.resolveStart(jobID: "overwrite-job", phase: .completed, text: projectText)
        try await waitUntil { !overwriteStore.isBuilding }
        guard let newProjectID = overwriteStore.workspace?.id, newProjectID != oldProjectID else {
            preconditionFailure("the finished build opens as its own project")
        }
        precondition(indexContent(overwriteStore.workspace) == "<h1>new project</h1>", "the finished project keeps its own index.html")
        precondition(overwriteStore.selectedFilePath == "index.html" && overwriteStore.editorText == "<h1>new project</h1>", "the editor shows the new project's entry file, not the old text")
        precondition(indexContent(overwriteStore.projects.first { $0.id == oldProjectID }) == "<p>old project edit</p>", "the old project's last edit stays in the old project")
        var savedNewProject: CodeWorkspaceProject?
        for _ in 0..<500 {
            savedNewProject = try await overwriteRepository.loadAll(ownerID: "owner-one").first { $0.id == newProjectID }
            if savedNewProject != nil { break }
            try await Task.sleep(for: .milliseconds(4))
        }
        // Give any stray editor save time to land before reading the disk again.
        try await Task.sleep(for: .milliseconds(150))
        savedNewProject = try await overwriteRepository.loadAll(ownerID: "owner-one").first { $0.id == newProjectID }
        precondition(indexContent(savedNewProject) == "<h1>new project</h1>", "the saved project on disk is the build's own, not the old editor text")

        // STORE-2: the persisted build of a previous launch whose server record
        // expired. The screen resumes before it loads the library.
        let (launchAPI, expiryDefaults, expiryRepository) = scenario("expiry", under: scenarioRoot)
        try await expiryRepository.save(CodeWorkspaceProject(id: "existing-project", name: "Existing", files: [CodeFile(path: "index.html", content: "<p>existing</p>")]), ownerID: "owner-one")
        let firstLaunch = CodeStore(session: SessionStore(), api: launchAPI, defaults: expiryDefaults, repository: expiryRepository)
        firstLaunch.startBuild(projectName: "Night build", prompt: "Build a timetable page", language: .english)
        try await waitUntil { launchAPI.pendingStarts.count == 1 }
        launchAPI.delayStatuses = true
        launchAPI.resolveStart(jobID: "expired-job")
        try await waitUntil { launchAPI.pendingStatuses.count == 1 }
        precondition(expiryDefaults.data(forKey: pointerKey) != nil, "the admitted build is remembered for the next launch")

        let relaunchAPI = FirasAPI()
        relaunchAPI.delayStatuses = true
        let relaunched = CodeStore(session: SessionStore(), api: relaunchAPI, defaults: expiryDefaults, repository: expiryRepository)
        relaunched.resumeIfNeeded()
        await relaunched.loadProjects()
        precondition(relaunched.isBuilding && relaunched.workspace == nil && relaunched.projects.map(\.id) == ["existing-project"],
                     "a resumed build keeps the library and its build card on screen instead of auto-opening a project")
        try await answerNextStatus(relaunchAPI, .success(status(.unknown)))
        try await answerNextStatus(relaunchAPI, .success(status(.unknown)))
        try await answerNextStatus(relaunchAPI, .failure(APIError.transport(code: -1009, message: "offline")))
        try await answerNextStatus(relaunchAPI, .failure(APIError.httpStatus(503, nil)))
        try await waitUntil(attempts: 1_000) { relaunchAPI.pendingStatuses.count == 1 }
        precondition(relaunched.isBuilding && relaunched.buildNotice == nil, "network errors and 5xx never count as an unknown job")
        try await answerNextStatus(relaunchAPI, .success(status(.unknown)))
        try await waitUntil { !relaunched.isBuilding }
        precondition(relaunched.buildNotice == .expired && relaunched.errorMessage == nil && relaunched.canBuild,
                     "the third unknown answer ends the build with the expiry notice and Build is available again")
        precondition(expiryDefaults.data(forKey: pointerKey) == nil, "the expired pointer is cleared")
        let thirdLaunch = CodeStore(session: SessionStore(), api: FirasAPI(), defaults: expiryDefaults, repository: expiryRepository)
        thirdLaunch.resumeIfNeeded()
        precondition(!thirdLaunch.isBuilding, "no later launch revives the expired build")

        // A definitive not-found ends the watch on the first answer.
        let (goneAPI, goneDefaults, goneRepository) = scenario("gone", under: scenarioRoot)
        goneAPI.delayStatuses = true
        let goneStore = CodeStore(session: SessionStore(), api: goneAPI, defaults: goneDefaults, repository: goneRepository)
        goneStore.startBuild(projectName: "Gone build", prompt: "Build a quiz page", language: .english)
        try await waitUntil { goneAPI.pendingStarts.count == 1 }
        goneAPI.resolveStart(jobID: "gone-job")
        try await answerNextStatus(goneAPI, .failure(APIError.httpStatus(404, "unknown_job")))
        try await waitUntil { !goneStore.isBuilding }
        precondition(goneStore.buildNotice == .expired && goneDefaults.data(forKey: pointerKey) == nil && goneAPI.statusRequests.count == 1,
                     "404 ends the build at once and clears its pointer")

        // UX-27: Stop on a running build cancels the server job exactly once.
        let (stopAPI, stopDefaults, stopRepository) = scenario("stop", under: scenarioRoot)
        let stopStore = CodeStore(session: SessionStore(), api: stopAPI, defaults: stopDefaults, repository: stopRepository)
        stopStore.startBuild(projectName: "Wrong brief", prompt: "Build the wrong page", language: .english)
        try await waitUntil { stopAPI.pendingStarts.count == 1 }
        stopAPI.resolveStart(jobID: "stop-job")
        try await waitUntil { stopStore.activeJobID == "stop-job" && !stopAPI.statusRequests.isEmpty }
        stopAPI.delayCancellation = true
        let firstTap = Task { await stopStore.stopBuild() }
        try await waitUntil { stopAPI.pendingCancellations.count == 1 }
        await stopStore.stopBuild()
        precondition(stopAPI.cancelledJobs == ["stop-job"] && stopStore.isStoppingBuild && stopStore.isBuilding,
                     "a second tap while the first Stop is in flight sends nothing")
        let pollsAtStop = stopAPI.statusRequests.count
        try await Task.sleep(for: .milliseconds(1_000))
        precondition(stopAPI.statusRequests.count == pollsAtStop, "the watcher is silenced before the cancel, so no poll lands meanwhile")
        stopAPI.pendingCancellations.removeFirst().resume(returning: CancelChatJobResponse(ok: true, stopped: true))
        await firstTap.value
        precondition(!stopStore.isBuilding && !stopStore.isStoppingBuild && stopStore.activeJobID == nil && stopStore.canBuild,
                     "a confirmed Stop ends the local build")
        precondition(stopStore.errorMessage == nil && stopStore.buildNotice == nil && stopDefaults.data(forKey: pointerKey) == nil,
                     "a confirmed Stop clears the pointer and is not reported as a failure")
        await stopStore.stopBuild()
        precondition(stopAPI.cancelledJobs == ["stop-job"], "the job is cancelled exactly once")

        // Stop before admission waits for the job id instead of orphaning it.
        let (earlyAPI, earlyDefaults, earlyRepository) = scenario("early-stop", under: scenarioRoot)
        let earlyStore = CodeStore(session: SessionStore(), api: earlyAPI, defaults: earlyDefaults, repository: earlyRepository)
        earlyStore.startBuild(projectName: "Early stop", prompt: "Build a contact page", language: .english)
        try await waitUntil { earlyAPI.pendingStarts.count == 1 }
        await earlyStore.stopBuild()
        precondition(earlyAPI.cancelledJobs.isEmpty && earlyStore.isStoppingBuild && earlyStore.isBuilding,
                     "a Stop before admission has no job id to send yet")
        earlyAPI.resolveStart(jobID: "early-job")
        try await waitUntil { !earlyStore.isBuilding }
        precondition(earlyAPI.cancelledJobs == ["early-job"] && earlyAPI.statusRequests.isEmpty && earlyDefaults.data(forKey: pointerKey) == nil,
                     "the job admitted after Stop is cancelled once and never watched")

        // A Stop that cannot reach the server leaves the build running and watched.
        let (offlineAPI, offlineDefaults, offlineRepository) = scenario("stop-offline", under: scenarioRoot)
        let offlineStore = CodeStore(session: SessionStore(), api: offlineAPI, defaults: offlineDefaults, repository: offlineRepository)
        offlineStore.startBuild(projectName: "Offline stop", prompt: "Build a gallery page", language: .english)
        try await waitUntil { offlineAPI.pendingStarts.count == 1 }
        offlineAPI.resolveStart(jobID: "offline-job")
        try await waitUntil { offlineStore.activeJobID == "offline-job" }
        offlineAPI.cancelFailure = APIError.transport(code: -1009, message: "offline")
        await offlineStore.stopBuild()
        precondition(offlineStore.isBuilding && !offlineStore.isStoppingBuild && offlineStore.buildNotice == .stopUnconfirmed
                     && offlineDefaults.data(forKey: pointerKey) != nil, "an unconfirmed Stop keeps the build and says so")
        let pollsAfterFailedStop = offlineAPI.statusRequests.count
        try await waitUntil(attempts: 1_000) { offlineAPI.statusRequests.count > pollsAfterFailedStop }
        offlineAPI.cancelFailure = nil
        await offlineStore.stopBuild()
        precondition(!offlineStore.isBuilding && offlineAPI.cancelledJobs == ["offline-job", "offline-job"]
                     && offlineDefaults.data(forKey: pointerKey) == nil, "pressing Stop again lands once the server is reachable")

        // A build that finishes after an unconfirmed Stop takes the stale notice with it.
        let (lateAPI, lateDefaults, lateRepository) = scenario("stop-then-done", under: scenarioRoot)
        let lateStore = CodeStore(session: SessionStore(), api: lateAPI, defaults: lateDefaults, repository: lateRepository)
        lateStore.startBuild(projectName: "Late finish", prompt: "Build a menu page", language: .english)
        try await waitUntil { lateAPI.pendingStarts.count == 1 }
        lateAPI.resolveStart(jobID: "late-job")
        try await waitUntil { lateStore.activeJobID == "late-job" }
        lateAPI.cancelFailure = APIError.transport(code: -1009, message: "offline")
        await lateStore.stopBuild()
        precondition(lateStore.isBuilding && lateStore.buildNotice == .stopUnconfirmed, "the unconfirmed Stop is reported while the build runs")
        lateAPI.statusResults = [ChatJobStatus(phase: .completed, text: projectText, reasoning: nil, error: nil,
                                               status: nil, surface: nil, progress: nil)]
        try await waitUntil(attempts: 1_000) { !lateStore.isBuilding }
        precondition(lateStore.buildNotice == nil && indexContent(lateStore.workspace) == "<h1>new project</h1>"
                     && lateDefaults.data(forKey: pointerKey) == nil, "the finished project lands without the stale Stop notice")

        // A Stop while lost submissions are being recovered asks the server what
        // they did, through the cid's read-only receipt, instead of orphaning them.
        let (lostAPI, lostDefaults, lostRepository) = scenario("stop-lost-admission", under: scenarioRoot)
        let lostStore = CodeStore(session: SessionStore(), api: lostAPI, defaults: lostDefaults, repository: lostRepository)
        lostStore.startBuild(projectName: "Lost answer", prompt: "Build a schedule page", language: .english)
        for attempt in 1...3 {
            try await waitUntil(attempts: 1_000) { lostAPI.pendingStarts.count == 1 && lostAPI.starts.count == attempt }
            lostAPI.failStart(APIError.transport(code: -1005, message: "connection lost"))
        }
        try await waitUntil { lostStore.errorMessage != nil }
        let lostCID = lostAPI.starts[0].cid
        lostAPI.delayReceipts = true
        let recoveringStop = Task { await lostStore.stopBuild() }
        try await waitUntil { lostAPI.pendingReceipts.count == 1 }
        lostAPI.pendingReceipts.removeFirst().resume(throwing: APIError.transport(code: -1009, message: "offline"))
        await recoveringStop.value
        precondition(lostStore.isBuilding && !lostStore.isStoppingBuild && lostStore.buildNotice == .stopUnconfirmed
                     && lostDefaults.data(forKey: pointerKey) != nil && lostAPI.cancelledJobs.isEmpty,
                     "a Stop the receipt cannot confirm keeps the build and says so")
        try await waitUntil(attempts: 1_000) { lostAPI.pendingStarts.count == 1 && lostAPI.starts.count == 4 }
        precondition(lostAPI.starts[3].cid == lostCID, "recovery resumes under the same cid after an unconfirmed Stop")
        await lostStore.stopBuild()
        lostAPI.failStart(APIError.transport(code: -1005, message: "connection lost"))
        try await waitUntil { lostAPI.pendingReceipts.count == 1 }
        lostAPI.pendingReceipts.removeFirst().resume(returning: ChatJobReceipt(jobId: "lost-job", phase: .processing,
                                                                              cid: lostCID, chatId: ""))
        try await waitUntil { !lostStore.isBuilding }
        precondition(lostAPI.cancelledJobs == ["lost-job"] && lostAPI.receiptRequests == [lostCID, lostCID],
                     "the job admitted under a lost answer is found by its cid and cancelled once")
        try await Task.sleep(for: .milliseconds(1_200))
        precondition(lostAPI.starts.count == 4 && lostDefaults.data(forKey: pointerKey) == nil
                     && lostStore.errorMessage == nil && lostStore.buildNotice == nil,
                     "after Stop nothing is resubmitted, the pointer is gone and no failure is shown")

        // A Stop whose answer was lost but which landed ends the build quietly.
        let (landedAPI, landedDefaults, landedRepository) = scenario("stop-landed", under: scenarioRoot)
        let landedStore = CodeStore(session: SessionStore(), api: landedAPI, defaults: landedDefaults, repository: landedRepository)
        landedStore.startBuild(projectName: "Landed stop", prompt: "Build a pricing page", language: .english)
        try await waitUntil { landedAPI.pendingStarts.count == 1 }
        landedAPI.resolveStart(jobID: "landed-job")
        try await waitUntil { landedStore.activeJobID == "landed-job" }
        landedAPI.cancelFailure = APIError.transport(code: -1005, message: "connection lost")
        await landedStore.stopBuild()
        landedAPI.statusResults = [ChatJobStatus(phase: .failed, text: nil, reasoning: nil, error: "cancelled",
                                                 status: 499, surface: nil, progress: nil)]
        try await waitUntil(attempts: 1_000) { !landedStore.isBuilding }
        precondition(landedStore.errorMessage == nil && landedStore.buildNotice == nil && landedStore.buildPhase == nil
                     && landedDefaults.data(forKey: pointerKey) == nil && landedAPI.cancelledJobs == ["landed-job"],
                     "the cancelled ending of this device's Stop is not reported as a failure")

        // Exact test-created UUID directory only.
        if FileManager.default.fileExists(atPath: scenarioRoot.path) {
            try FileManager.default.removeItem(at: scenarioRoot)
        }
        print("CLEAN: 35 production CodeStore ownership/recovery/build-lifecycle checks")
    }

    private static let pointerKey = "firas.ios.code-builds.v1"
    private static let webBuild = IntentDecision(ok: true, kind: "code", requirements: "",
        classified: true, codeTarget: "web", codeLanguage: "html")
    private static let projectText = "```firas-project\n{\"name\":\"New site\",\"files\":[{\"path\":\"index.html\",\"content\":\"<h1>new project</h1>\"}]}\n```"

    /// A fresh transport, pointer suite and on-disk library per scenario, with a
    /// classification that admits a real browser build.
    private static func scenario(_ name: String, under root: URL) -> (FirasAPI, UserDefaults, CodeProjectRepository) {
        let api = FirasAPI()
        api.classificationResult = webBuild
        return (api, UserDefaults(suiteName: "firas-code-build-test-" + name + "-" + UUID().uuidString)!,
                CodeProjectRepository(directory: root.appendingPathComponent(name, isDirectory: true)))
    }

    private static func status(_ phase: ChatJobPhase) -> ChatJobStatus {
        ChatJobStatus(phase: phase, text: nil, reasoning: nil, error: nil, status: nil, surface: nil, progress: nil)
    }

    private static func indexContent(_ project: CodeWorkspaceProject?) -> String? {
        project?.files.first { $0.path == "index.html" }?.content
    }

    /// Answers the store's next status poll once it is parked on the fixture.
    private static func answerNextStatus(_ api: FirasAPI, _ result: Result<ChatJobStatus, Error>) async throws {
        try await waitUntil(attempts: 1_000) { api.pendingStatuses.count == 1 }
        api.pendingStatuses.removeFirst().resume(with: result)
    }

    private static func waitUntil(attempts: Int = 500, _ predicate: () -> Bool) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(4))
        }
        preconditionFailure("test operation did not reach its synchronization point")
    }
}

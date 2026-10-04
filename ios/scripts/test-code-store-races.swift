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
        print("CLEAN: 8 production CodeStore ownership/recovery checks")
    }

    private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(4))
        }
        preconditionFailure("test operation did not reach its synchronization point")
    }
}

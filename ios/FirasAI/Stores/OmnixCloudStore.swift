import Foundation
import Observation

nonisolated enum OmnixCloudFailure: Equatable, Sendable { case refresh, uncertain, rejected, files }

@MainActor
@Observable
final class OmnixCloudStore {
    private(set) var ownerID: String?
    private(set) var product: OmnixCloudProduct = .ai
    private(set) var cloud: OmnixCloudStatus?
    private(set) var job: OmnixCloudJob?
    private(set) var files: [OmnixCloudFile] = []
    private(set) var isWorking = false
    private(set) var isPolling = false
    private(set) var isDownloading = false
    private(set) var approvalFresh = false
    private(set) var uncertain = false
    private(set) var failure: OmnixCloudFailure?
    private(set) var sharedFileURL: URL?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pointer: OmnixCloudPointer?
    @ObservationIgnored private let api: FirasAPI
    @ObservationIgnored private let defaults: UserDefaults

    init(api: FirasAPI = FirasAPI(), defaults: UserDefaults = .standard) { self.api = api; self.defaults = defaults }
    var isReady: Bool { ownerID != nil && cloud?.canRun == true }
    var hasLiveJob: Bool { job.map { !$0.isTerminal } ?? false }

    func invalidate() {
        generation &+= 1
        ownerID = nil; cloud = nil; job = nil; files = []; pointer = nil
        isWorking = false; isPolling = false; isDownloading = false; approvalFresh = false; uncertain = false; failure = nil
        if let sharedFileURL { OmnixCloudTempWriter.remove(sharedFileURL) }
        sharedFileURL = nil
        // Intentionally no server cancel. The account's cloud work continues.
    }

    func bind(owner: String?, product: OmnixCloudProduct) {
        guard ownerID != owner || self.product != product else { return }
        invalidate(); ownerID = owner; self.product = product
        guard let key = pointerKey, let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(OmnixCloudPointer.self, from: data), saved.isValid else { return }
        pointer = saved; uncertain = saved.jobId == nil && saved.requestKey != nil
    }

    private var pointerKey: String? { ownerID.map { "firas.omnix.cloud.pointer.v1.\($0).\(product.rawValue)" } }
    private func savePointer() {
        guard let key = pointerKey, let pointer, pointer.isValid, let data = try? JSONEncoder().encode(pointer) else { return }
        defaults.set(data, forKey: key) // Identifiers only; no prompts, commands, keys or output.
    }

    private func accept(_ value: OmnixCloudJob) throws {
        guard value.isValid, pointer?.jobId == nil || pointer?.jobId == value.jobId else { throw APIError.invalidResponse }
        job = value; uncertain = false; approvalFresh = value.pendingApproval != nil
        pointer = OmnixCloudPointer(jobId: value.jobId, sessionId: value.sessionId, requestKey: pointer?.requestKey)
        savePointer()
    }

    private func recordFailure(_ error: Error, fallback: OmnixCloudFailure) {
        failure = fallback; approvalFresh = false
        guard let status = (error as? APIError)?.statusCode, [401, 403].contains(status) else { return }
        // Invalidate other in-flight results when this account loses access.
        generation &+= 1
        cloud = nil; job = nil; files = []
        isWorking = false; isPolling = false; isDownloading = false
        if let sharedFileURL { OmnixCloudTempWriter.remove(sharedFileURL) }
        sharedFileURL = nil
    }

    func refresh() async {
        guard let owner = ownerID, !isWorking else { return }
        let ticket = generation
        isWorking = true; failure = nil
        defer { if ticket == generation { isWorking = false } }
        do {
            let value = try await api.omnixCloudStatus()
            guard ticket == generation, ownerID == owner else { return }
            cloud = value
            guard value.canRun else { approvalFresh = false; return }
            if let latest = value.latest(for: product) {
                // An older task is not a receipt for an uncertain new submission.
                if uncertain, pointer?.jobId == nil, pointer?.requestKey != latest.requestKey {
                    failure = .uncertain
                } else { pointer = latest.pointer; uncertain = false; savePointer() }
            }
            await poll()
            await refreshFiles()
        } catch {
            guard ticket == generation else { return }
            cloud = nil; recordFailure(error, fallback: .refresh)
        }
    }

    func poll() async {
        guard let owner = ownerID, isReady, !isPolling, let jobID = pointer?.jobId else { return }
        let ticket = generation
        isPolling = true
        defer { if ticket == generation { isPolling = false } }
        do {
            let value = try await api.pollOmnixCloud(jobID: jobID)
            guard ticket == generation, ownerID == owner else { return }
            let justFinished = job?.isTerminal != true && value.isTerminal
            try accept(value); failure = nil
            if justFinished { await refreshFiles() }
        } catch {
            guard ticket == generation else { return }
            recordFailure(error, fallback: .refresh)
        }
    }

    @discardableResult
    func submit(text: String) async -> Bool {
        let request = OmnixCloudRunRequest(requestKey: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                                          text: text, product: product, sessionId: pointer?.sessionId)
        guard let owner = ownerID, isReady, !isWorking, !hasLiveJob, !uncertain, request.isValid else { return false }
        let ticket = generation
        pointer = OmnixCloudPointer(jobId: nil, sessionId: request.sessionId, requestKey: request.requestKey); savePointer()
        uncertain = true; isWorking = true; failure = nil; approvalFresh = false
        defer { if ticket == generation { isWorking = false } }
        do {
            let value = try await api.submitOmnixCloud(request)
            guard ticket == generation, ownerID == owner else { return false }
            try accept(value); await poll(); return true
        } catch {
            guard ticket == generation else { return false }
            if let status = (error as? APIError)?.statusCode, [400, 409, 413, 429].contains(status) {
                uncertain = false; failure = .rejected
                pointer = OmnixCloudPointer(jobId: job?.jobId, sessionId: request.sessionId, requestKey: nil); savePointer()
            } else { recordFailure(error, fallback: .uncertain) }
            return false
        }
    }

    func stop() async {
        guard let owner = ownerID, let job, !job.isTerminal, isReady, !isWorking else { return }
        let ticket = generation; isWorking = true; approvalFresh = false; failure = nil
        defer { if ticket == generation { isWorking = false } }
        do {
            try await api.cancelOmnixCloud(jobID: job.jobId)
            guard ticket == generation, ownerID == owner else { return }
            await poll() // Acknowledged stop is not a completed cancellation.
        } catch { if ticket == generation { recordFailure(error, fallback: .refresh) } }
    }

    func reconcile() async {
        guard let owner = ownerID, let job, ["reserved", "submission_uncertain"].contains(job.state),
              isReady, !isWorking else { return }
        let ticket = generation; isWorking = true; failure = nil
        defer { if ticket == generation { isWorking = false } }
        do {
            let value = try await api.reconcileOmnixCloud(jobID: job.jobId)
            guard ticket == generation, ownerID == owner else { return }
            try accept(value); await poll()
        } catch { if ticket == generation { recordFailure(error, fallback: .uncertain) } }
    }

    func approve(choice: String) async {
        guard let owner = ownerID, let job, let pending = job.pendingApproval,
              isReady, !isWorking, approvalFresh, pending.choices.contains(choice) else { return }
        let request = OmnixCloudApprovalRequest(requestId: pending.requestId, choice: choice)
        guard request.isValid else { return }
        let ticket = generation; isWorking = true; approvalFresh = false; failure = nil
        defer { if ticket == generation { isWorking = false } }
        do {
            try await api.approveOmnixCloud(jobID: job.jobId, request: request)
            guard ticket == generation, ownerID == owner else { return }
            await poll()
        } catch { if ticket == generation { recordFailure(error, fallback: .refresh) } }
    }

    func refreshFiles() async {
        guard let owner = ownerID, isReady else { return }
        let ticket = generation
        do {
            let value = try await api.omnixCloudFiles()
            guard ticket == generation, ownerID == owner else { return }
            guard value.files.count <= 1_000, value.files.allSatisfy(\.isValid), Set(value.files.map(\.id)).count == value.files.count else { throw APIError.invalidResponse }
            files = value.files
        } catch { if ticket == generation { recordFailure(error, fallback: .files) } }
    }

    func download(_ file: OmnixCloudFile) async {
        guard let owner = ownerID, isReady, !isDownloading, files.contains(file), file.isValid else { return }
        let ticket = generation; isDownloading = true
        defer { if ticket == generation { isDownloading = false } }
        do {
            let artifact = try await api.downloadOmnixCloudFile(id: file.id)
            guard ticket == generation, ownerID == owner else { return }
            let url = try await Task.detached(priority: .utility) { try OmnixCloudTempWriter.write(artifact, name: file.name) }.value
            guard ticket == generation, ownerID == owner else { OmnixCloudTempWriter.remove(url); return }
            if let sharedFileURL { OmnixCloudTempWriter.remove(sharedFileURL) }
            sharedFileURL = url
        } catch { if ticket == generation { recordFailure(error, fallback: .files) } }
    }
}

private nonisolated enum OmnixCloudTempWriter {
    static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("OmnixDownloads", isDirectory: true) }
    static func write(_ artifact: ArtifactDownload, name: String) throws -> URL {
        guard artifact.data.count <= 25 * 1024 * 1024 else { throw APIError.invalidResponse }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filename = String((name.split(separator: "/").last.map(String.init) ?? "download").prefix(160))
        guard filename != ".", filename != "..", !filename.contains("\\") else { throw APIError.invalidResponse }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(filename, isDirectory: false)
        try artifact.data.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
        return url
    }
    static func remove(_ url: URL) {
        let folder = url.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent() == root.standardizedFileURL,
              UUID(uuidString: folder.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}

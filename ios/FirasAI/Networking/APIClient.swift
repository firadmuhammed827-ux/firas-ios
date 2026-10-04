import Foundation

nonisolated enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

nonisolated enum APIError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case invalidRequest(String)
    case transport(code: Int, message: String)
    case invalidResponse
    case httpStatus(code: Int, message: String)
    case skillValidation([String])
    case encoding(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The API URL is invalid."
        case .invalidRequest(let message):
            message
        case .transport(_, let message):
            message
        case .invalidResponse:
            "The server returned an invalid response."
        case .httpStatus(_, let message):
            message
        case .skillValidation:
            "The skill needs changes before it can be saved."
        case .encoding(let message):
            message
        case .decoding(let message):
            message
        }
    }

    var statusCode: Int? {
        if case .skillValidation = self { return 400 }
        guard case .httpStatus(let code, _) = self else { return nil }
        return code
    }
}

private nonisolated struct ServerErrorEnvelope: Decodable, Sendable {
    let error: String?
    let problems: [String]?
}

/// Ephemeral credentials captured for one owned media operation. Never persisted
/// or printed; the header cannot migrate to an account that signs in later.
nonisolated struct MediaCredentialSnapshot: Equatable, Sendable {
    let origin: URL
    let cookieHeader: String
}

nonisolated enum MediaCredentialScope {
    @TaskLocal static var current: MediaCredentialSnapshot?
}

private nonisolated final class MediaNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor APIClient {
    private let baseURL: URL
    private let session: URLSession
    private let mediaSession: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseURL: URL) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        session = CloudEndpointPolicy.session(configuration: configuration, origin: baseURL)

        let mediaConfiguration = URLSessionConfiguration.ephemeral
        mediaConfiguration.httpCookieStorage = nil
        mediaConfiguration.httpShouldSetCookies = false
        mediaConfiguration.urlCache = nil
        mediaConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        mediaConfiguration.timeoutIntervalForRequest = 45
        mediaConfiguration.timeoutIntervalForResource = 180
        mediaSession = URLSession(configuration: mediaConfiguration, delegate: MediaNoRedirectDelegate(), delegateQueue: nil)

        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func mediaCredentialSnapshot() throws -> MediaCredentialSnapshot {
        guard let header = currentCookieHeader(), !header.isEmpty else {
            throw APIError.invalidRequest("media_session_required")
        }
        return MediaCredentialSnapshot(origin: baseURL, cookieHeader: header)
    }

    private func currentCookieHeader() -> String? {
        let cookies = (HTTPCookieStorage.shared.cookies(for: baseURL) ?? []).sorted {
            ($0.name, $0.domain, $0.path) < ($1.name, $1.domain, $1.path)
        }
        return cookies.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    func mediaFile(kind: MediaStudioKind, key: String, path: String,
                   query: [URLQueryItem]) async throws -> MediaAssetFileDownload {
        let route = MediaAssetPolicy.route(kind)
        guard MediaCredentialScope.current != nil, MediaRequestPolicy.validKey(key),
              path == route.path, query.count == 1, query[0].name == route.queryName, query[0].value == key else {
            throw APIError.invalidRequest("media_session_required")
        }
        var request = try makeRequest(.get, path: path, query: query, body: nil,
                                      cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let download = try await MediaFileTransfer(origin: baseURL, kind: kind, key: key).start(request: request)
        do {
            try Task.checkCancellation()
            try requireCurrentMediaCredentials()
            return download
        } catch {
            try? FileManager.default.removeItem(at: download.fileURL)
            throw error
        }
    }

    private func requireCurrentMediaCredentials() throws {
        guard let credentials = MediaCredentialScope.current else { return }
        guard credentials.origin == baseURL, currentCookieHeader() == credentials.cookieHeader else {
            throw CancellationError()
        }
    }

    func request<Response: Decodable & Sendable>(
        _ method: HTTPMethod,
        path: String,
        query: [URLQueryItem] = [],
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        maximumResponseBytes: Int? = nil
    ) async throws -> Response {
        let request = try makeRequest(
            method,
            path: path,
            query: query,
            body: nil,
            cachePolicy: cachePolicy
        )
        return try await execute(request, maximumResponseBytes: maximumResponseBytes)
    }

    func request<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        _ method: HTTPMethod,
        path: String,
        query: [URLQueryItem] = [],
        body: Body,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        maximumBodyBytes: Int? = nil,
        maximumResponseBytes: Int? = nil
    ) async throws -> Response {
        let data: Data
        do {
            data = try encoder.encode(body)
        } catch {
            throw APIError.encoding("The request could not be encoded.")
        }
        if let maximumBodyBytes, data.count > maximumBodyBytes {
            throw APIError.invalidRequest("media_history_too_large")
        }

        let request = try makeRequest(
            method,
            path: path,
            query: query,
            body: data,
            cachePolicy: cachePolicy
        )
        return try await execute(request, maximumResponseBytes: maximumResponseBytes)
    }

    func download(
        path: String,
        query: [URLQueryItem]
    ) async throws -> ArtifactDownload {
        let request = try makeRequest(
            .get,
            path: path,
            query: query,
            body: nil,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        let (data, response) = try await perform(request)
        try validate(response: response, data: data)

        let mimeType = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init) ?? "application/octet-stream"
        let filename = suggestedFilename(
            from: response.value(forHTTPHeaderField: "Content-Disposition")
        )

        return ArtifactDownload(
            data: data,
            mimeType: mimeType,
            suggestedFilename: filename
        )
    }

    private func execute<Response: Decodable & Sendable>(
        _ request: URLRequest, maximumResponseBytes: Int? = nil
    ) async throws -> Response {
        let (data, response) = try await perform(request)
        // Helper snapshots have an independent decode/render budget. This
        // bounds decoding; URLSession's Data transfer remains a separate cost.
        if let maximumResponseBytes, data.count > maximumResponseBytes { throw APIError.invalidResponse }
        try validate(response: response, data: data)

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding("The server response did not match the expected format.")
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
            let network = MediaCredentialScope.current == nil ? session : mediaSession
            let (data, response) = try await network.data(for: request)
            try Task.checkCancellation()
            try requireCurrentMediaCredentials()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            return (data, httpResponse)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw APIError.transport(code: error.errorCode, message: error.localizedDescription)
        } catch {
            throw APIError.transport(code: -1, message: error.localizedDescription)
        }
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            let envelope = try? decoder.decode(ServerErrorEnvelope.self, from: data)
            if response.statusCode == 400, envelope?.error == "invalid_skill" {
                throw APIError.skillValidation(envelope?.problems ?? ["invalid"])
            }
            var message = envelope?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            if MediaCredentialScope.current != nil, !message.utf8.allSatisfy({
                (97...122).contains($0) || (48...57).contains($0) || $0 == 95
            }) || message.utf8.count > 80 {
                message = "media_request_failed"
            }
            throw APIError.httpStatus(code: response.statusCode, message: message)
        }
    }

    private func makeRequest(
        _ method: HTTPMethod,
        path: String,
        query: [URLQueryItem],
        body: Data?,
        cachePolicy: URLRequest.CachePolicy
    ) throws -> URLRequest {
        var url = baseURL
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(component))
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let finalURL = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: finalURL, cachePolicy: cachePolicy)
        request.httpMethod = method.rawValue
        request.httpShouldHandleCookies = true
        if let credentials = MediaCredentialScope.current {
            guard CloudEndpointPolicy.isSameOrigin(finalURL, as: credentials.origin),
                  credentials.origin == baseURL, currentCookieHeader() == credentials.cookieHeader else {
                throw CancellationError()
            }
            request.httpShouldHandleCookies = false
            request.setValue(credentials.cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func suggestedFilename(from disposition: String?) -> String {
        guard let disposition else { return "firas-artifact" }

        if let encodedRange = disposition.range(of: "filename*=UTF-8''", options: .caseInsensitive) {
            let encoded = disposition[encodedRange.upperBound...]
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
                return safeFilename(decoded)
            }
        }

        if let filenameRange = disposition.range(of: "filename=", options: .caseInsensitive) {
            let value = disposition[filenameRange.upperBound...]
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"")) ?? ""
            if !value.isEmpty {
                return safeFilename(value)
            }
        }

        return "firas-artifact"
    }

    private func safeFilename(_ value: String) -> String {
        let clean = value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "firas-artifact" : String(clean.prefix(180))
    }
}

/// URLSession chunks are written on a serial delegate queue, never on MainActor.
/// Mutable transfer state is protected by one lock, including cancellation.
/// Completion cleans a failed partial file before returning to the caller.
private nonisolated final class MediaFileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let origin: URL
    private let kind: MediaStudioKind
    private let key: String
    private let temporaryURL: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MediaAssetFileDownload, any Error>?
    private var network: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64 = -1
    private var prefix = Data()
    private var mimeType: String?
    private var cancelled = false

    init(origin: URL, kind: MediaStudioKind, key: String) {
        self.origin = origin; self.kind = kind; self.key = key
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("firas-media-" + UUID().uuidString + ".part")
    }

    func start(request: URLRequest) async throws -> MediaAssetFileDownload {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var failure: (any Error)?
                var started: URLSessionDataTask?
                lock.withLock {
                    self.continuation = continuation
                    guard !cancelled else { failure = CancellationError(); return }
                    do {
                        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil,
                            attributes: [.posixPermissions: 0o600]) else { throw APIError.invalidResponse }
                        file = try FileHandle(forWritingTo: temporaryURL)
                        let configuration = URLSessionConfiguration.ephemeral
                        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
                        configuration.urlCache = nil
                        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                        configuration.timeoutIntervalForRequest = 45
                        configuration.timeoutIntervalForResource = 180
                        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                        queue.name = "org.firasai.media-transfer"
                        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                        network = session; task = session.dataTask(with: request); started = task
                    } catch { failure = error }
                }
                if let failure { finish(.failure(failure)) } else { started?.resume() }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
            self.finish(.failure(CancellationError()))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = http.url,
              CloudEndpointPolicy.isSameOrigin(url, as: origin), url == dataTask.originalRequest?.url else {
            completionHandler(.cancel); finish(.failure(APIError.invalidResponse)); return
        }
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(APIError.httpStatus(code: http.statusCode, message: "media_asset_unavailable"))); return
        }
        guard response.expectedContentLength <= MediaAssetPolicy.maximumBytes(kind),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            completionHandler(.cancel); finish(.failure(APIError.invalidRequest("media_asset_too_large"))); return
        }
        let active = lock.withLock {
            guard continuation != nil, !cancelled else { return false }
            expected = response.expectedContentLength
            mimeType = http.value(forHTTPHeaderField: "Content-Type")
            return true
        }
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var failure: (any Error)?
        lock.withLock {
            guard continuation != nil, !cancelled else { return }
            guard Int64(data.count) <= MediaAssetPolicy.maximumBytes(kind) - received else {
                failure = APIError.invalidRequest("media_asset_too_large"); return
            }
            do {
                guard let file else { throw APIError.invalidResponse }
                try file.write(contentsOf: data)
                received += Int64(data.count)
                if prefix.count < 512 { prefix.append(data.prefix(512 - prefix.count)) }
            } catch { failure = error }
        }
        if let failure { finish(.failure(failure)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            if (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())) }
            else { finish(.failure(APIError.transport(code: (error as NSError).code, message: "media_download_failed"))) }
            return
        }
        let metadata = lock.withLock {
            guard continuation != nil, !cancelled, expected < 0 || expected == received else { return nil as MediaAssetMetadata? }
            return MediaAssetPolicy.inspect(kind: kind, key: key, mimeType: mimeType, prefix: prefix, totalBytes: received)
        }
        guard let metadata else { finish(.failure(APIError.invalidResponse)); return }
        finish(.success(MediaAssetFileDownload(fileURL: temporaryURL, mimeType: metadata.mimeType,
            suggestedFilename: "firas-" + kind.rawValue + "-" + key + "." + metadata.fileExtension)))
    }

    private func finish(_ result: Result<MediaAssetFileDownload, any Error>) {
        let completion = lock.withLock { () -> (CheckedContinuation<MediaAssetFileDownload, any Error>, URLSession?, Result<MediaAssetFileDownload, any Error>)? in
            guard let continuation else { return nil }
            self.continuation = nil
            var outcome = result
            do {
                if let file { try file.close() }
                else if case .success = result { throw APIError.invalidResponse }
            } catch {
                if case .success = result {
                    outcome = .failure(APIError.transport(code: -1, message: "media_download_failed"))
                }
            }
            file = nil
            if case .failure = outcome { try? FileManager.default.removeItem(at: temporaryURL) }
            let network = self.network; self.network = nil; task = nil
            return (continuation, network, outcome)
        }
        guard let completion else { return }
        completion.1?.invalidateAndCancel()
        completion.0.resume(with: completion.2)
    }
}

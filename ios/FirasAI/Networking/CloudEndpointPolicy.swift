import Foundation

nonisolated enum CloudEndpointPolicy {
    static func permitsBaseURL(_ url: URL, development: Bool) -> Bool {
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", let host = url.host?.lowercased() else { return false }
        if url.scheme?.lowercased() == "https", ["firasai.org", "www.firasai.org"].contains(host),
           url.port == nil || url.port == 443 { return true }
        return development && url.scheme?.lowercased() == "http" &&
            ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    static func isSameOrigin(_ candidate: URL, as base: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return candidate.user == nil && candidate.password == nil &&
            candidate.scheme?.lowercased() == base.scheme?.lowercased() &&
            candidate.host?.lowercased() == base.host?.lowercased() && port(candidate) == port(base)
    }
}

// URLSession retains its delegate. The immutable origin is safe to consult from delegate callbacks.
private nonisolated final class CloudRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let origin: URL
    init(origin: URL) { self.origin = origin }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = request.url.map { CloudEndpointPolicy.isSameOrigin($0, as: origin) } ?? false
        completionHandler(allowed ? request : nil)
    }
}

extension CloudEndpointPolicy {
    nonisolated static func session(configuration: URLSessionConfiguration, origin: URL) -> URLSession {
        URLSession(configuration: configuration, delegate: CloudRedirectDelegate(origin: origin), delegateQueue: nil)
    }
}

import CryptoKit
import Foundation

// Compile unchanged production CommonModels.swift, MediaStudioModels.swift,
// CloudEndpointPolicy.swift and APIClient.swift with the existing model fixtures.
// This suite uses a loopback Python server; it never contacts the live product.
// It is Mac-only and authored on Windows: no compilation/runtime PASS is implied.
nonisolated private struct TransportFixtureState: Decodable, Sendable {
    let requests: [String: Int]
    let frozenCookieSeen: [String: Bool]
    let postCount: Int
    let postBytes: [Int]
    let postFrozenCookieSeen: Bool
    let redirectTargetHits: Int
    let imageBytes: Int
    let imageSHA256: String
}
nonisolated private struct TransportFixtureResponse: Decodable, Sendable { let ok: Bool }
nonisolated private struct TransportFixtureBody: Encodable, Sendable { let text: String }

@MainActor
@main enum MediaTransportTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw APIError.invalidRequest("fixture_port_file_required")
        }
        let portText = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(portText), (1...65535).contains(port),
              let origin = URL(string: "http://127.0.0.1:\(port)"),
              CloudEndpointPolicy.permitsBaseURL(origin, development: true) else { throw APIError.invalidURL }
        let client = APIClient(baseURL: origin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 5
        let control = URLSession(configuration: configuration)
        defer { control.invalidateAndCancel() }
        let cookieName = "firas_media_fixture_auth"
        let poisonName = "firas_media_fixture_poison"
        let storage = HTTPCookieStorage.shared
        let originalFixtureCookies = (storage.cookies ?? []).filter {
            $0.domain == "127.0.0.1" && $0.path == "/" && [cookieName, poisonName].contains($0.name)
        }
        guard (storage.cookies(for: origin) ?? []).allSatisfy({
            $0.domain == "127.0.0.1" && $0.path == "/" && [cookieName, poisonName].contains($0.name)
        }) else {
            // Never clear or forward another app's real local-development cookie.
            throw APIError.invalidRequest("fixture_cookie_jar_not_isolated")
        }
        func removeFixtureCookies() {
            for cookie in storage.cookies ?? [] where cookie.domain == "127.0.0.1" && cookie.path == "/" &&
                [cookieName, poisonName].contains(cookie.name) { storage.deleteCookie(cookie) }
        }
        removeFixtureCookies()
        defer {
            removeFixtureCookies()
            for cookie in originalFixtureCookies { storage.setCookie(cookie) }
        }
        func setOwner(_ value: String) {
            let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/",
                .name: cookieName, .value: value, .expires: Date().addingTimeInterval(3600)])!
            storage.setCookie(cookie)
        }
        setOwner("owner-a")
        let credentials = try await client.mediaCredentialSnapshot()
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            precondition(condition, label); checks += 1
        }
        expect(credentials.origin == origin && credentials.cookieHeader.contains(cookieName + "=owner-a"),
               "captures the actual synthetic owner cookie at this loopback origin")
        func controlURL(_ path: String, query: [URLQueryItem] = []) -> URL {
            var value = URLComponents(url: origin.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            value.queryItems = query.isEmpty ? nil : query
            return value.url!
        }
        func state() async throws -> TransportFixtureState {
            let (data, response) = try await control.data(from: controlURL("fixture/state"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.invalidResponse }
            return try JSONDecoder().decode(TransportFixtureState.self, from: data)
        }
        func release(_ name: String) async throws {
            let (data, response) = try await control.data(from: controlURL("fixture/release", query: [.init(name: "case", value: name)]))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  try JSONDecoder().decode(TransportFixtureResponse.self, from: data).ok else { throw APIError.invalidResponse }
        }
        func parts() throws -> Set<URL> {
            Set(try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
                includingPropertiesForKeys: [.fileSizeKey], options: []).filter {
                    $0.lastPathComponent.hasPrefix("firas-media-") && $0.pathExtension == "part"
                })
        }
        func waitForStarted(_ name: String, previous: Set<URL>) async throws {
            for _ in 0..<100 {
                let current = try await state()
                let staged = try parts().subtracting(previous)
                let hasBytes = staged.contains { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
                if (current.requests[name] ?? 0) > 0 && hasBytes { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw APIError.invalidRequest("fixture_stream_did_not_start")
        }
        func asset(_ kind: MediaStudioKind = .image, _ character: String) async throws -> MediaAssetFileDownload {
            let key = String(repeating: character, count: 64)
            let route = MediaAssetPolicy.route(kind)
            return try await MediaCredentialScope.$current.withValue(credentials) {
                try await client.mediaFile(kind: kind, key: key, path: route.path,
                    query: [.init(name: route.queryName, value: key)])
            }
        }
        func remove(_ download: MediaAssetFileDownload) throws {
            let value = download.fileURL.standardizedFileURL
            expect(value.deletingLastPathComponent() == FileManager.default.temporaryDirectory.standardizedFileURL &&
                value.lastPathComponent.hasPrefix("firas-media-") && value.pathExtension == "part",
                "cleanup targets only the exact fixture-owned staging file")
            try FileManager.default.removeItem(at: value)
        }
        func inspect(_ download: MediaAssetFileDownload, mime: String, suffix: String, expectedBytes: Int) throws {
            let key = String(repeating: "a", count: 64)
            expect(download.mimeType == mime && download.suggestedFilename.hasSuffix("-" + key + suffix),
                   "canonical signature/MIME and safe policy filename ignore hostile disposition")
            let attributes = try FileManager.default.attributesOfItem(atPath: download.fileURL.path)
            expect((attributes[.size] as? NSNumber)?.intValue == expectedBytes, "actual streamed file has the expected byte length")
            expect(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600,
                   "private staging file is owner-readable and writable only")
        }
        let initial = try await state()
        let beforeSuccess = try parts()
        let image = try await asset(.image, "a")
        try inspect(image, mime: "image/png", suffix: ".png", expectedBytes: initial.imageBytes)
        let handle = try FileHandle(forReadingFrom: image.fileURL)
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty { hash.update(data: chunk) }
        try handle.close()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        expect(digest == initial.imageSHA256, "real delegate streaming preserves all synthetic bytes across chunks")
        try remove(image)
        expect(try parts() == beforeSuccess, "successful fixture file cleanup preserves existing staging files")
        let afterDownloadCredentials = try await client.mediaCredentialSnapshot()
        expect(afterDownloadCredentials == credentials && !(storage.cookies ?? []).contains { $0.name == poisonName && $0.domain == "127.0.0.1" },
               "asset Set-Cookie cannot mutate the shared jar or frozen operation identity")
        for (kind, mime, suffix, bytes) in [(MediaStudioKind.video, "video/mp4", ".mp4", 32), (.music, "audio/wav", ".wav", 52)] {
            let download = try await asset(kind, "a")
            try inspect(download, mime: mime, suffix: suffix, expectedBytes: bytes)
            try remove(download)
        }
        // The MP4/WAV fixtures prove actual routes/container transfer, not decoding/playback.
        let unknown = try await asset(.image, "b")
        expect(unknown.mimeType == "image/png", "unknown length/octet-stream still requires real container classification")
        expect((try FileManager.default.attributesOfItem(atPath: unknown.fileURL.path)[.size] as? NSNumber)?.intValue == initial.imageBytes,
               "connection-close streaming preserves the whole bounded asset")
        try remove(unknown)
        for (character, name) in [("c", "declared_cap"), ("d", "stream_cap"), ("e", "mime_mismatch"),
                                  ("f", "random_bytes"), ("1", "truncated"), ("2", "same_origin_redirect"),
                                  ("3", "foreign_origin_redirect"), ("4", "encoded_response"), ("5", "unauthorized")] {
            let before = try parts()
            do {
                let unexpected = try await asset(.image, character)
                try remove(unexpected)
                preconditionFailure("rejected fixture unexpectedly returned an asset: " + name)
            } catch let error as APIError {
                switch name {
                case "declared_cap", "stream_cap", "encoded_response":
                    expect(error == .invalidRequest("media_asset_too_large"), "actual delegate rejects declared/received/encoded byte policy")
                case "same_origin_redirect", "foreign_origin_redirect":
                    expect(error == .httpStatus(code: 302, message: "media_asset_unavailable"), "both same and foreign origin redirects are rejected before a hop")
                case "unauthorized":
                    expect(error == .httpStatus(code: 401, message: "media_asset_unavailable"), "HTTP failure exposes a fixed code, not upstream response content")
                case "truncated":
                    if case .transport = error { checks += 1 }
                    else { expect(error == .invalidResponse, "truncated declared body cannot return a successful asset") }
                default:
                    expect(error == .invalidResponse, "declared MIME/random bytes cannot pass actual signature screening")
                }
            }
            expect(try parts() == before, "failed download removes its exact partial file before returning")
        }
        expect(try await state().redirectTargetHits == 0, "redirect targets receive no request or frozen cookie")
        let beforeCancel = try parts()
        let cancelled = Task { try await asset(.image, "6") }
        defer { cancelled.cancel() }
        try await waitForStarted("cancel", previous: beforeCancel)
        cancelled.cancel()
        do {
            let unexpected = try await cancelled.value; try remove(unexpected)
            preconditionFailure("cancelled fixture unexpectedly completed")
        } catch is CancellationError { checks += 1 }
        expect(try parts() == beforeCancel, "midstream cancellation removes the actual partial file before completion")
        try await release("cancel")
        let beforeIdentityChange = try parts()
        let changingOwner = Task { try await asset(.image, "7") }
        defer { changingOwner.cancel() }
        try await waitForStarted("credential_change", previous: beforeIdentityChange)
        setOwner("owner-b")
        try await release("credential_change")
        do {
            let unexpected = try await changingOwner.value; try remove(unexpected)
            preconditionFailure("retired credentials unexpectedly returned a private asset")
        } catch is CancellationError { checks += 1 }
        expect(try parts() == beforeIdentityChange, "post-transfer credential fencing removes the completed private staging file")
        do {
            let unexpected = try await asset(.image, "8"); try remove(unexpected)
            preconditionFailure("stale credentials unexpectedly reached HTTP")
        } catch is CancellationError { checks += 1 }
        let staleState = try await state()
        expect((staleState.requests["stale_before_http"] ?? 0) == 0, "old captured cookie fails before any HTTP request")
        expect(staleState.frozenCookieSeen["credential_change"] == true && staleState.requests["credential_change"] == 1,
               "midstream operation sent the original cookie exactly once and was never reassigned")
        do {
            let _: TransportFixtureResponse = try await MediaCredentialScope.$current.withValue(credentials) {
                try await client.request(.post, path: "/api/chats", body: TransportFixtureBody(text: "synthetic"), maximumBodyBytes: 2_000_000)
            }
            preconditionFailure("stale JSON credentials unexpectedly reached HTTP")
        } catch is CancellationError { checks += 1 }
        expect(try await state().postCount == staleState.postCount, "old captured cookie also rejects a write before HTTP")
        setOwner("owner-a")
        let beforeImmediateCancel = try parts()
        let immediate = Task { try await asset(.image, "9") }
        immediate.cancel()
        do {
            let unexpected = try await immediate.value; try remove(unexpected)
            preconditionFailure("pre-cancelled transfer unexpectedly completed")
        } catch is CancellationError { checks += 1 }
        expect(try parts() == beforeImmediateCancel, "cancellation before continuation creation leaves no staging file")
        expect((try await state().requests["cancel_before_http"] ?? 0) == 0, "pre-cancelled local transfer never starts HTTP")
        let beforeBody = try await state().postCount
        do {
            let _: TransportFixtureResponse = try await MediaCredentialScope.$current.withValue(credentials) {
                try await client.request(.post, path: "/api/chats", body: TransportFixtureBody(text: String(repeating: "x", count: 2_000_000)),
                    maximumBodyBytes: 2_000_000)
            }
            preconditionFailure("oversized history unexpectedly reached HTTP")
        } catch let error as APIError {
            expect(error == .invalidRequest("media_history_too_large"), "actual JSON encoder enforces2MB before constructing/sending the write")
        }
        expect(try await state().postCount == beforeBody, "oversized history performs zero writes")
        let exactBody = TransportFixtureBody(text: String(repeating: "x", count: 2_000_000 - 11))
        expect(try JSONEncoder().encode(exactBody).count == 2_000_000, "fixture reaches the exact serialized history boundary")
        let accepted: TransportFixtureResponse = try await MediaCredentialScope.$current.withValue(credentials) {
            try await client.request(.post, path: "/api/chats", body: exactBody, maximumBodyBytes: 2_000_000)
        }
        expect(accepted.ok, "exact2MB synthetic body is accepted by actual APIClient")
        let final = try await state()
        expect(final.postCount == beforeBody + 1 && final.postBytes.last == 2_000_000,
               "exact serialized boundary sends one and only one actual local HTTP write")
        expect(final.postFrozenCookieSeen, "the JSON write uses its captured credential header")
        expect(!(storage.cookies ?? []).contains { $0.name == poisonName && $0.domain == "127.0.0.1" },
               "scoped JSON Set-Cookie also cannot mutate shared authentication")
        expect(try await client.mediaCredentialSnapshot() == credentials, "all successful scoped responses preserve frozen credentials")
        expect(final.frozenCookieSeen.values.allSatisfy { $0 }, "every synthetic asset request used the captured cookie header")
        expect(try parts() == beforeSuccess, "entire suite leaves no new production staging files")
        print("Media transport: \(checks) assertions passed against production APIClient and synthetic loopback fixtures")
    }
}

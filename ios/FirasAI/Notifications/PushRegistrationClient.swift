import Foundation

nonisolated enum APNsEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production
}

private nonisolated struct PushRegistrationRequest: Encodable, Sendable {
    let token: String
    let environment: APNsEnvironment
    let language: String
}

private nonisolated struct PushUnregistrationRequest: Encodable, Sendable {
    let token: String
}

private nonisolated struct PushOperationResponse: Decodable, Sendable {
    let ok: Bool
}

private nonisolated struct PushServerError: Decodable, Sendable {
    let error: String?
}

/// A deliberately independent client for APNs device registration. It shares
/// the system cookie jar with the website session, but it does not share an
/// `APIClient` instance or mutate `FirasAPI` while a durable job is polling.
actor PushRegistrationClient {
    private let baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    @MainActor
    init(configuration: AppConfiguration = .live) {
        self.init(baseURL: configuration.apiBaseURL)
    }

    func register(
        deviceToken: String,
        environment: APNsEnvironment,
        languageCode: String
    ) async throws {
        let token = try validatedToken(deviceToken)
        let language = languageCode.lowercased().hasPrefix("ar") ? "ar" : "en"
        let response: PushOperationResponse = try await post(
            path: "/api/push/register",
            body: PushRegistrationRequest(
                token: token,
                environment: environment,
                language: language
            )
        )
        guard response.ok else { throw APIError.invalidResponse }
    }

    func unregister(deviceToken: String) async throws {
        let token = try validatedToken(deviceToken)
        let response: PushOperationResponse = try await post(
            path: "/api/push/unregister",
            body: PushUnregistrationRequest(token: token)
        )
        guard response.ok else { throw APIError.invalidResponse }
    }

    private func post<Response: Decodable & Sendable, Body: Encodable & Sendable>(
        path: String,
        body: Body
    ) async throws -> Response {
        let encoded: Data
        do {
            encoded = try encoder.encode(body)
        } catch {
            throw APIError.encoding("The push registration request could not be encoded.")
        }

        var url = baseURL
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(component))
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = HTTPMethod.post.rawValue
        request.httpBody = encoded
        request.httpShouldHandleCookies = true
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(code: error.errorCode, message: error.localizedDescription)
        } catch {
            throw APIError.transport(code: -1, message: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let serverError = try? decoder.decode(PushServerError.self, from: data)
            throw APIError.httpStatus(
                code: httpResponse.statusCode,
                message: serverError?.error
                    ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding("The push registration response was invalid.")
        }
    }

    private func validatedToken(_ value: String) throws -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Apple documents the token as opaque and variable-length. Keep only a
        // defensive request-size ceiling; do not assume today's 32-byte shape.
        guard (32...512).contains(token.count),
              token.count.isMultiple(of: 2),
              token.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              })
        else {
            throw APIError.invalidRequest("The APNs device token is invalid.")
        }
        return token
    }
}

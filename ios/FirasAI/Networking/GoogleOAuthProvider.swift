import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

nonisolated struct GoogleOAuthNativeConfiguration: Equatable, Sendable {
    let clientID: String
    let redirectURI: String
    let callbackScheme: String

    /// Public OAuth identifiers. These must stay byte-for-byte aligned with
    /// GOOGLE_IOS_CLIENT_ID / GOOGLE_IOS_REDIRECT in the backend.
    static let firas = GoogleOAuthNativeConfiguration(
        clientID: "237562309958-p0njbmb5imqcfd6fk728ccr6lhesq03e.apps.googleusercontent.com",
        redirectURI: "com.googleusercontent.apps.237562309958-p0njbmb5imqcfd6fk728ccr6lhesq03e:/oauth2redirect",
        callbackScheme: "com.googleusercontent.apps.237562309958-p0njbmb5imqcfd6fk728ccr6lhesq03e"
    )
}

nonisolated enum GoogleOAuthError: Error, Equatable, LocalizedError, Sendable {
    case alreadyInProgress
    case invalidConfiguration
    case unableToStart
    case invalidCallback
    case stateMismatch
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            "Google sign-in is already in progress."
        case .invalidConfiguration:
            "Google sign-in is not configured correctly."
        case .unableToStart:
            "Google sign-in could not be opened."
        case .invalidCallback:
            "Google returned an invalid sign-in response."
        case .stateMismatch:
            "Google sign-in could not be verified. Please try again."
        case .provider(let code):
            "Google sign-in failed (\(code))."
        }
    }
}

@MainActor
final class GoogleOAuthProvider: NSObject {
    static let shared = GoogleOAuthProvider()

    typealias PresentationAnchorProvider = @MainActor () -> ASPresentationAnchor

    private let configuration: GoogleOAuthNativeConfiguration
    private let presentationAnchorProvider: PresentationAnchorProvider
    private var activeSession: ASWebAuthenticationSession?

    init(
        configuration: GoogleOAuthNativeConfiguration = .firas,
        presentationAnchorProvider: @escaping PresentationAnchorProvider = GoogleOAuthProvider.activePresentationAnchor
    ) {
        self.configuration = configuration
        self.presentationAnchorProvider = presentationAnchorProvider
    }

    func authorize() async throws -> GoogleNativeAuthorization {
        guard activeSession == nil else {
            throw GoogleOAuthError.alreadyInProgress
        }

        let codeVerifier = try Self.secureRandomToken(byteCount: 32)
        let state = try Self.secureRandomToken(byteCount: 32)
        let nonce = try Self.secureRandomToken(byteCount: 32)
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let authorizationURL = try makeAuthorizationURL(
            codeChallenge: codeChallenge,
            state: state,
            nonce: nonce
        )

        let callbackURL = try await openAuthorizationSession(url: authorizationURL)
        try Task.checkCancellation()
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let values = Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )

        // State authenticates every callback, including provider-declared
        // errors. Never let a forged custom-scheme URL dismiss the real flow.
        guard values["state"] == state else {
            throw GoogleOAuthError.stateMismatch
        }
        if let providerError = values["error"], !providerError.isEmpty {
            if providerError == "access_denied" {
                throw CancellationError()
            }
            throw GoogleOAuthError.provider(String(providerError.prefix(80)))
        }
        guard let code = values["code"], !code.isEmpty else {
            throw GoogleOAuthError.invalidCallback
        }

        return GoogleNativeAuthorization(
            code: code,
            codeVerifier: codeVerifier,
            nonce: nonce
        )
    }

    func cancel() {
        activeSession?.cancel()
    }

    private func makeAuthorizationURL(
        codeChallenge: String,
        state: String,
        nonce: String
    ) throws -> URL {
        guard URL(string: configuration.redirectURI)?.scheme == configuration.callbackScheme,
              var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        else {
            throw GoogleOAuthError.invalidConfiguration
        }

        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        guard let url = components.url else {
            throw GoogleOAuthError.invalidConfiguration
        }
        return url
    }

    private func openAuthorizationSession(url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: configuration.callbackScheme
                ) { [weak self] callbackURL, error in
                    Task { @MainActor in
                        self?.activeSession = nil

                        if let authenticationError = error as? ASWebAuthenticationSessionError,
                           authenticationError.code == .canceledLogin {
                            continuation.resume(throwing: CancellationError())
                        } else if let error {
                            continuation.resume(throwing: error)
                        } else if let callbackURL,
                                  callbackURL.scheme == self?.configuration.callbackScheme,
                                  callbackURL.path == "/oauth2redirect" {
                            continuation.resume(returning: callbackURL)
                        } else {
                            continuation.resume(throwing: GoogleOAuthError.invalidCallback)
                        }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                activeSession = session

                guard session.start() else {
                    activeSession = nil
                    continuation.resume(throwing: GoogleOAuthError.unableToStart)
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.activeSession?.cancel()
            }
        }
    }

    private nonisolated static func secureRandomToken(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, baseAddress)
        }
        guard status == errSecSuccess else {
            throw GoogleOAuthError.invalidConfiguration
        }
        return base64URL(Data(bytes))
    }

    private nonisolated static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func activePresentationAnchor() -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }

        if let keyWindow = scenes.lazy.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }
        if let visibleWindow = scenes.lazy.flatMap(\.windows).first(where: { !$0.isHidden }) {
            return visibleWindow
        }
        return ASPresentationAnchor(frame: .zero)
    }
}

extension GoogleOAuthProvider: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationAnchorProvider()
    }
}

import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    nonisolated enum Phase: Equatable, Sendable {
        case restoring
        case guest
        case awaitingVerification
        case authenticated
    }

    nonisolated enum SettingsOperation: Equatable, Sendable {
        case refreshingAccount
        case changingEmail
        case changingPassword
        case deletingAccount
        case exportingChats
        case importingChats
    }

    private(set) var phase: Phase = .restoring
    private(set) var user: User?
    private(set) var pendingSignup: PendingSignup?
    private(set) var isWorking = false
    private(set) var identityGeneration = 0
    private(set) var settingsOperation: SettingsOperation?
    private(set) var guestID: String?
    var errorMessage: String?

    @ObservationIgnored private let api: FirasAPI

    init(api: FirasAPI = FirasAPI()) {
        self.api = api
    }

    var isAuthenticated: Bool { phase == .authenticated && user != nil }
    var isGuest: Bool { phase == .guest && guestID != nil }
    var identityID: String? { user?.id ?? guestID }

    func restore() async {
        guard !isWorking else { return }
        isWorking = true
        identityGeneration &+= 1
        phase = .restoring
        errorMessage = nil
        defer { isWorking = false }

        do {
            let restoredUser = try await api.me()
            applyAuthenticatedUser(restoredUser)
        } catch let error as APIError where error.statusCode == 401 {
            await establishGuestSession()
        } catch {
            user = nil
            guestID = nil
            // A transport failure does not establish a guest identity. Keep
            // restoration retryable instead of exposing a guest-looking state
            // that cannot send because it has no server-issued guest id.
            phase = .restoring
            errorMessage = message(for: error)
        }
    }

    func login(email: String, password: String) async {
        guard !isWorking else { return }
        isWorking = true
        identityGeneration &+= 1
        errorMessage = nil
        defer { isWorking = false }

        do {
            let authenticatedUser = try await api.login(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            applyAuthenticatedUser(authenticatedUser)
        } catch {
            errorMessage = message(for: error)
        }
    }

    /// Completes native Google/Firebase sign-in after the platform auth SDK has
    /// returned a Firebase ID token. This method never accepts a Google access
    /// token or client secret; the backend validates the Firebase token and
    /// issues the same secure session cookie used by email/password login.
    func signInWithFirebaseIDToken(_ idToken: String) async {
        guard !isWorking else { return }
        isWorking = true
        identityGeneration &+= 1
        errorMessage = nil
        defer { isWorking = false }

        do {
            let authenticatedUser = try await api.signInWithFirebaseIDToken(idToken)
            applyAuthenticatedUser(authenticatedUser)
        } catch {
            errorMessage = message(for: error)
        }
    }

    func signInWithGoogle(using provider: GoogleOAuthProvider) async {
        guard !isWorking else { return }
        isWorking = true
        identityGeneration &+= 1
        errorMessage = nil
        defer { isWorking = false }

        do {
            let authorization = try await provider.authorize()
            let authenticatedUser = try await api.signInWithGoogleNative(authorization)
            applyAuthenticatedUser(authenticatedUser)
        } catch is CancellationError {
            // Closing the system account picker is an expected outcome.
        } catch {
            errorMessage = message(for: error)
        }
    }

    func signup(name: String, email: String, password: String) async {
        guard !isWorking else { return }
        isWorking = true
        identityGeneration &+= 1
        errorMessage = nil
        defer { isWorking = false }

        do {
            let response = try await api.signup(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            pendingSignup = PendingSignup(email: response.email, pid: response.pid)
            phase = .awaitingVerification
        } catch {
            errorMessage = message(for: error)
        }
    }

    func checkVerification() async {
        guard !isWorking, let pendingSignup else { return }
        isWorking = true
        identityGeneration &+= 1
        errorMessage = nil
        defer { isWorking = false }

        do {
            let response = try await api.verificationStatus(pid: pendingSignup.pid)
            if response.verified, let verifiedUser = response.user {
                applyAuthenticatedUser(verifiedUser)
            } else if response.expired == true || response.gone == true {
                self.pendingSignup = nil
                phase = guestID == nil ? .restoring : .guest
                errorMessage = response.expired == true
                    ? "انتهت صلاحية رابط التحقق. أعد إنشاء الحساب."
                    : "لم يعد طلب التحقق متاحاً. أعد إنشاء الحساب."
            } else {
                phase = .awaitingVerification
            }
        } catch {
            errorMessage = message(for: error)
        }
    }

    func verifySignup(token: String) async {
        guard !isWorking else { return }
        isWorking = true
        identityGeneration &+= 1
        errorMessage = nil
        defer { isWorking = false }

        do {
            let verifiedUser = try await api.verifySignup(token: token)
            applyAuthenticatedUser(verifiedUser)
        } catch {
            errorMessage = message(for: error)
        }
    }

    func continueAsGuest() async {
        guard !isWorking else { return }
        isWorking = true
        identityGeneration &+= 1
        errorMessage = nil
        defer { isWorking = false }
        await establishGuestSession()
    }

    func logout() async {
        guard !isWorking else { return }
        isWorking = true
        identityGeneration &+= 1
        errorMessage = nil
        defer { isWorking = false }

        do {
            await NotificationCoordinator.shared.unregisterCurrentDevice()
            try await api.logout()
            user = nil
            pendingSignup = nil
            guestID = nil
            NotificationCoordinator.shared.sessionDidEnd()
            await establishGuestSession()
        } catch {
            if let user {
                NotificationCoordinator.shared.sessionDidAuthenticate(userID: user.id)
            }
            errorMessage = message(for: error)
        }
    }

    func refreshAccount() async {
        guard isAuthenticated, beginSettingsOperation(.refreshingAccount) else { return }
        defer { endSettingsOperation() }

        do {
            let refreshedUser = try await api.me()
            applyAuthenticatedUser(refreshedUser)
        } catch {
            errorMessage = message(for: error)
        }
    }

    @discardableResult
    func changeEmail(currentPassword: String, newEmail: String) async -> Bool {
        guard isAuthenticated, beginSettingsOperation(.changingEmail) else { return false }
        defer { endSettingsOperation() }

        do {
            let updatedUser = try await api.changeEmail(
                currentPassword: currentPassword,
                newEmail: newEmail
            )
            applyAuthenticatedUser(updatedUser)
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    @discardableResult
    func changePassword(currentPassword: String, newPassword: String) async -> Bool {
        guard isAuthenticated, beginSettingsOperation(.changingPassword) else { return false }
        defer { endSettingsOperation() }

        do {
            try await api.changePassword(
                currentPassword: currentPassword,
                newPassword: newPassword
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    @discardableResult
    func deleteAccount(currentPassword: String) async -> Bool {
        guard isAuthenticated, beginSettingsOperation(.deletingAccount) else { return false }
        defer { endSettingsOperation() }

        do {
            await NotificationCoordinator.shared.unregisterCurrentDevice()
            try await api.deleteAccount(currentPassword: currentPassword)
            user = nil
            pendingSignup = nil
            guestID = nil
            NotificationCoordinator.shared.sessionDidEnd()
            await establishGuestSession()
            return true
        } catch {
            if let user {
                NotificationCoordinator.shared.sessionDidAuthenticate(userID: user.id)
            }
            errorMessage = message(for: error)
            return false
        }
    }

    func makeChatBackup() async -> FirasChatBackup? {
        guard isAuthenticated, beginSettingsOperation(.exportingChats) else { return nil }
        defer { endSettingsOperation() }

        do {
            return try await api.makeChatBackup()
        } catch {
            errorMessage = message(for: error)
            return nil
        }
    }

    func importChatBackup(_ backup: FirasChatBackup) async -> Int? {
        guard isAuthenticated, beginSettingsOperation(.importingChats) else { return nil }
        defer { endSettingsOperation() }

        do {
            return try await api.importChatBackup(backup)
        } catch {
            errorMessage = message(for: error)
            return nil
        }
    }

    private func establishGuestSession() async {
        do {
            let response = try await api.startGuestSession()
            if response.guest {
                user = nil
                guestID = response.user.id
                pendingSignup = nil
                phase = .guest
                NotificationCoordinator.shared.sessionDidEnd()
            } else {
                applyAuthenticatedUser(response.user)
            }
        } catch {
            user = nil
            guestID = nil
            phase = .restoring
            NotificationCoordinator.shared.sessionDidEnd()
            errorMessage = message(for: error)
        }
    }

    private func applyAuthenticatedUser(_ user: User) {
        self.user = user
        guestID = nil
        pendingSignup = nil
        phase = .authenticated
        errorMessage = nil
        NotificationCoordinator.shared.sessionDidAuthenticate(userID: user.id)
    }

    private func beginSettingsOperation(_ operation: SettingsOperation) -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        identityGeneration &+= 1
        settingsOperation = operation
        errorMessage = nil
        return true
    }

    private func endSettingsOperation() {
        settingsOperation = nil
        isWorking = false
    }

    private func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.errorDescription ?? "تعذّر الاتصال بالخادم."
        }
        return error.localizedDescription
    }
}

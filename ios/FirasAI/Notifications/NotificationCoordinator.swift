import Foundation
import Observation
import UIKit
import UserNotifications

nonisolated enum JobNotificationOutcome: String, Codable, Equatable, Hashable, Sendable {
    case completed
    case failed
}

nonisolated enum NotificationAuthorizationContext: Equatable, Sendable {
    /// Use only after the server has accepted a durable job. This keeps the
    /// system prompt tied to a benefit the person has just asked for.
    case durableJobStarted
    /// Use for a direct, user-initiated "Enable notifications" action.
    case userRequested
}

nonisolated enum FirasNotificationPermission: Equatable, Sendable {
    case unknown
    case denied
    case authorized
}

nonisolated struct NotificationDestination: Equatable, Hashable, Identifiable, Sendable {
    let product: ProductKind
    let jobID: String
    let chatID: String?
    let mediaKind: MediaStudioKind?
    let outcome: JobNotificationOutcome

    var id: String { product.rawValue + ":" + jobID + ":" + outcome.rawValue }

    /// Old registrations may still receive a completed Agent job. Recognize
    /// its raw wire value to suppress it before decoding a supported product.
    static func isRetiredProduct(userInfo: [AnyHashable: Any]) -> Bool {
        let nested = userInfo["firas"] as? [AnyHashable: Any]
        let product = nested?["product"] as? String
            ?? userInfo["firas_product"] as? String
        return product == "agent"
    }

    fileprivate var userInfo: [String: Any] {
        var route: [String: Any] = [
            "type": "job-terminal",
            "product": product.rawValue,
            "jobId": jobID,
            "phase": outcome.rawValue,
        ]
        if let chatID, !chatID.isEmpty { route["chatId"] = chatID }
        if let mediaKind { route["mediaKind"] = mediaKind.rawValue }
        return ["firas": route]
    }

    fileprivate static func decode(userInfo: [AnyHashable: Any]) -> NotificationDestination? {
        guard !isRetiredProduct(userInfo: userInfo) else { return nil }
        let nested = userInfo["firas"] as? [AnyHashable: Any]
        let productValue = nested?["product"] as? String
            ?? userInfo["firas_product"] as? String
        let jobID = nested?["jobId"] as? String
            ?? userInfo["firas_job_id"] as? String
        let chatID = nested?["chatId"] as? String
            ?? userInfo["firas_chat_id"] as? String
        let mediaKindValue = nested?["mediaKind"] as? String
            ?? userInfo["firas_media_kind"] as? String
        let phaseValue = nested?["phase"] as? String
            ?? userInfo["firas_phase"] as? String

        guard let productValue,
              let product = ProductKind(rawValue: productValue),
              let jobID,
              !jobID.isEmpty,
              let phaseValue,
              let outcome = JobNotificationOutcome(rawValue: phaseValue)
        else { return nil }

        return NotificationDestination(
            product: product,
            jobID: jobID,
            chatID: chatID?.isEmpty == false ? chatID : nil,
            mediaKind: mediaKindValue.flatMap(MediaStudioKind.init(rawValue:)),
            outcome: outcome
        )
    }
}

@MainActor
@Observable
final class NotificationCoordinator {
    static let shared = NotificationCoordinator()

    private(set) var permission: FirasNotificationPermission = .unknown
    private(set) var isRegistering = false
    private(set) var registrationError: String?
    private(set) var pendingDestination: NotificationDestination?

    @ObservationIgnored private let center: UNUserNotificationCenter
    @ObservationIgnored private let client: PushRegistrationClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var currentUserID: String?
    @ObservationIgnored private var deviceToken: String?
    @ObservationIgnored private var preferredLanguageCode: String
    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var recentRemoteArrivals: [String: Date] = [:]

    private static let deviceTokenKey = "firas.ios.apns.device-token.v1"
    private static let languageKey = "firas.ios.apns.language.v1"
    private static let registeredTokenPrefix = "firas.ios.apns.registered-token.v1."
    private static let completionCategory = "FIRAS_JOB_COMPLETE"
    private static let completionSoundFilename = "FirasComplete.wav"

    init(
        client: PushRegistrationClient = PushRegistrationClient(),
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.center = center
        self.defaults = defaults
        deviceToken = defaults.string(forKey: Self.deviceTokenKey)
        preferredLanguageCode = defaults.string(forKey: Self.languageKey)
            ?? (Locale.preferredLanguages.first?.lowercased().hasPrefix("ar") == true ? "ar" : "en")
    }

    /// Safe to call at launch: it installs routing metadata only. It never asks
    /// for notification permission and never registers with APNs by itself.
    func prepareForLaunch() {
        let category = UNNotificationCategory(
            identifier: Self.completionCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        refreshPermissionWithoutPrompt()
    }

    func sessionDidAuthenticate(userID: String) {
        currentUserID = userID
        refreshPermissionAndRegisterIfPossible()
    }

    func sessionDidEnd() {
        registrationTask?.cancel()
        registrationTask = nil
        currentUserID = nil
        isRegistering = false
    }

    /// Call before the authenticated logout request removes its cookie. A
    /// network failure never blocks logout; the server's bounded token list and
    /// APNs token rotation remain the final stale-registration safeguards.
    func unregisterCurrentDevice() async {
        registrationTask?.cancel()
        registrationTask = nil
        guard let userID = currentUserID, let token = deviceToken else { return }

        do {
            try await client.unregister(deviceToken: token)
            defaults.removeObject(forKey: registeredTokenKey(userID: userID))
            registrationError = nil
        } catch {
            registrationError = readable(error)
        }
    }

    /// The only API that can display the system permission sheet. No launch or
    /// session-restore path calls it.
    @discardableResult
    func requestAuthorizationIfNeeded(
        context _: NotificationAuthorizationContext,
        preferredLanguageCode: String? = nil
    ) async -> Bool {
        if let preferredLanguageCode {
            updatePreferredLanguage(preferredLanguageCode)
        }

        let settings = await center.notificationSettings()
        updatePermission(from: settings.authorizationStatus)

        let allowed: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            allowed = true
        case .notDetermined:
            do {
                allowed = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                registrationError = readable(error)
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }

        let refreshed = await center.notificationSettings()
        updatePermission(from: refreshed.authorizationStatus)
        guard allowed, permitsNotifications(refreshed.authorizationStatus) else { return false }
        UIApplication.shared.registerForRemoteNotifications()
        registerCurrentTokenIfPossible(force: true)
        return true
    }

    func updatePreferredLanguage(_ languageCode: String) {
        let normalized = languageCode.lowercased().hasPrefix("ar") ? "ar" : "en"
        guard preferredLanguageCode != normalized else { return }
        preferredLanguageCode = normalized
        defaults.set(normalized, forKey: Self.languageKey)
        registerCurrentTokenIfPossible(force: true)
    }

    func didRegisterForRemoteNotifications(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else { return }
        deviceToken = token
        defaults.set(token, forKey: Self.deviceTokenKey)
        registrationError = nil
        registerCurrentTokenIfPossible(force: true)
    }

    func didFailToRegisterForRemoteNotifications(_ error: Error) {
        registrationError = readable(error)
    }

    func noteRemoteNotification(userInfo: [AnyHashable: Any]) {
        guard let destination = NotificationDestination.decode(userInfo: userInfo) else { return }
        recentRemoteArrivals[destination.id] = Date()
        pruneRemoteArrivals()
    }

    func handleNotificationResponse(userInfo: [AnyHashable: Any]) {
        guard let destination = NotificationDestination.decode(userInfo: userInfo) else { return }
        recentRemoteArrivals[destination.id] = Date()
        pendingDestination = destination
        pruneRemoteArrivals()
    }

    func consumePendingDestination(id: String? = nil) {
        guard id == nil || pendingDestination?.id == id else { return }
        pendingDestination = nil
    }

    /// Fallback for the narrow case where a poll observes completion while the
    /// process is still alive in the background but this device has no confirmed
    /// server registration. Server APNs remains the source of truth otherwise.
    func scheduleLocalFallbackIfNeeded(
        product: ProductKind,
        jobID: String,
        chatID: String?,
        mediaKind: MediaStudioKind? = nil,
        outcome: JobNotificationOutcome
    ) async {
        guard UIApplication.shared.applicationState != .active else { return }
        let destination = NotificationDestination(
            product: product,
            jobID: jobID,
            chatID: chatID,
            mediaKind: mediaKind,
            outcome: outcome
        )

        pruneRemoteArrivals()
        guard recentRemoteArrivals[destination.id] == nil,
              !hasConfirmedRemoteRegistration
        else { return }

        let settings = await center.notificationSettings()
        updatePermission(from: settings.authorizationStatus)
        guard permitsNotifications(settings.authorizationStatus) else { return }

        let content = UNMutableNotificationContent()
        let copy = localizedCopy(product: product, mediaKind: mediaKind, outcome: outcome)
        content.title = copy.title
        content.body = copy.body
        content.categoryIdentifier = Self.completionCategory
        content.threadIdentifier = "firas-\(product.rawValue)-\(chatID ?? jobID)"
        content.userInfo = destination.userInfo
        content.sound = completionSound()

        let request = UNNotificationRequest(
            identifier: "firas-job-\(destination.id)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            registrationError = readable(error)
        }
    }

    private var hasConfirmedRemoteRegistration: Bool {
        guard let userID = currentUserID, let deviceToken else { return false }
        return defaults.string(forKey: registeredTokenKey(userID: userID)) == deviceToken
    }

    private func refreshPermissionWithoutPrompt() {
        Task { [weak self] in
            guard let self else { return }
            let settings = await self.center.notificationSettings()
            self.updatePermission(from: settings.authorizationStatus)
        }
    }

    private func refreshPermissionAndRegisterIfPossible() {
        Task { [weak self] in
            guard let self else { return }
            let settings = await self.center.notificationSettings()
            self.updatePermission(from: settings.authorizationStatus)
            guard self.permitsNotifications(settings.authorizationStatus) else { return }
            UIApplication.shared.registerForRemoteNotifications()
            self.registerCurrentTokenIfPossible(force: false)
        }
    }

    private func registerCurrentTokenIfPossible(force: Bool) {
        guard permission == .authorized,
              let userID = currentUserID,
              let token = deviceToken
        else { return }

        let registrationKey = registeredTokenKey(userID: userID)
        let priorToken = defaults.string(forKey: registrationKey)
        guard force || priorToken != token else { return }

        registrationTask?.cancel()
        isRegistering = true
        registrationTask = Task { [weak self, client, defaults] in
            do {
                if let priorToken, priorToken != token {
                    try? await client.unregister(deviceToken: priorToken)
                }
                try await client.register(
                    deviceToken: token,
                    environment: Self.currentEnvironment,
                    languageCode: self?.preferredLanguageCode ?? "en"
                )
                guard !Task.isCancelled, let self, self.currentUserID == userID else { return }
                defaults.set(token, forKey: registrationKey)
                self.registrationError = nil
                self.isRegistering = false
                self.registrationTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.currentUserID == userID else { return }
                self.registrationError = self.readable(error)
                self.isRegistering = false
                self.registrationTask = nil
            }
        }
    }

    private func registeredTokenKey(userID: String) -> String {
        Self.registeredTokenPrefix + userID
    }

    private func updatePermission(from status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            permission = .authorized
        case .denied:
            permission = .denied
        case .notDetermined:
            permission = .unknown
        @unknown default:
            permission = .unknown
        }
    }

    private func permitsNotifications(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        @unknown default:
            false
        }
    }

    private func localizedCopy(
        product: ProductKind,
        mediaKind: MediaStudioKind? = nil,
        outcome: JobNotificationOutcome
    ) -> (title: String, body: String) {
        let arabic = preferredLanguageCode == "ar"
        let productName: String
        if let mediaKind {
            switch (mediaKind, arabic) {
            case (.image, true): productName = "صورة فِراس"
            case (.video, true): productName = "فيديو فِراس"
            case (.music, true): productName = "موسيقى فِراس"
            case (.image, false): productName = "Firas image"
            case (.video, false): productName = "Firas video"
            case (.music, false): productName = "Firas music"
            }
        } else {
            switch (product, arabic) {
            case (.ai, true): productName = "إجابة فِراس"
            case (.code, true): productName = "مشروع فِراس كود"
            case (.brain, true): productName = "بحث فِراس برين"
            case (.ai, false): productName = "Firas answer"
            case (.code, false): productName = "Firas Code project"
            case (.brain, false): productName = "Firas Brain search"
            }
        }

        if arabic {
            return outcome == .completed
                ? (productName + " اكتملت", "اضغط لعرض النتيجة.")
                : (productName + " لم تكتمل", "اضغط لعرض التفاصيل أو المحاولة مجدداً.")
        }
        return outcome == .completed
            ? (productName + " is ready", "Tap to view the result.")
            : (productName + " could not finish", "Tap to view details or try again.")
    }

    private func completionSound() -> UNNotificationSound {
        let rootSound = Bundle.main.url(
            forResource: "FirasComplete",
            withExtension: "wav"
        )
        let nestedSound = Bundle.main.url(
            forResource: "FirasComplete",
            withExtension: "wav",
            subdirectory: "Sounds"
        )
        guard rootSound != nil || nestedSound != nil else { return .default }
        return UNNotificationSound(
            named: UNNotificationSoundName(rawValue: Self.completionSoundFilename)
        )
    }

    private func pruneRemoteArrivals() {
        let cutoff = Date().addingTimeInterval(-120)
        recentRemoteArrivals = recentRemoteArrivals.filter { $0.value >= cutoff }
    }

    private func readable(_ error: Error) -> String {
        if let apiError = error as? APIError {
            return apiError.errorDescription ?? "Notification registration failed."
        }
        return error.localizedDescription
    }

    private static var currentEnvironment: APNsEnvironment {
#if DEBUG
        .sandbox
#else
        .production
#endif
    }
}

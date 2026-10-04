import UIKit
import UserNotifications

@MainActor
final class FirasAppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        NotificationCoordinator.shared.prepareForLaunch()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationCoordinator.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationCoordinator.shared.didFailToRegisterForRemoteNotifications(error)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard !NotificationDestination.isRetiredProduct(
            userInfo: notification.request.content.userInfo
        ) else { return [] }
        NotificationCoordinator.shared.noteRemoteNotification(
            userInfo: notification.request.content.userInfo
        )
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        NotificationCoordinator.shared.handleNotificationResponse(
            userInfo: response.notification.request.content.userInfo
        )
    }
}

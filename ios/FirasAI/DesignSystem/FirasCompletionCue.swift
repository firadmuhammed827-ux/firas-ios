import Foundation
import UIKit

/// A restrained, foreground-only completion cue shared by every durable
/// product. The consumed-key history survives relaunches so reconnecting to an
/// already-terminal job never repeats its haptics.
@MainActor
enum FirasCompletionCue {
    private static let historyKey = "firas.completion-cue.history.v1"
    private static let historyLimit = 256

    /// Runs a brief cue without holding the finished answer. A `false` result means the owning
    /// task was cancelled and must not publish terminal UI for a stale owner.
    @discardableResult
    static func prepareForReveal(product: ProductKind, jobID: String) async -> Bool {
        await prepareForReveal(productID: product.rawValue, jobID: jobID)
    }

    /// String-based overload keeps the cue reusable by products whose server
    /// identifier is not represented by `ProductKind` yet (for example Media).
    @discardableResult
    static func prepareForReveal(productID: String, jobID: String) async -> Bool {
        guard !Task.isCancelled else { return false }

        let product = productID.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !product.isEmpty, !job.isEmpty else { return true }
        guard UIApplication.shared.applicationState == .active else { return true }
        guard consumeIfNeeded(key: "\(product):\(job)") else { return true }

        // UIKit exposes Reduce Motion but no public "Reduce Haptics" flag.
        // Skipping the theatrical cue under Reduce Motion is the closest
        // respectful system-level signal; the OS still owns final haptic
        // delivery according to the person's Sounds & Haptics settings.
        guard !UIAccessibility.isReduceMotionEnabled else { return true }

        guard let feedback = makeFeedbackGenerator() else { return true }
        feedback.prepare()
        feedback.impactOccurred(intensity: 0.32)

        do {
            try await Task.sleep(for: .milliseconds(160))
        } catch {
            return false
        }

        // The app may have moved to the background between pulses. Never fire
        // a haptic there, and do not hold a background completion for flourish.
        guard UIApplication.shared.applicationState == .active else { return true }
        feedback.prepare()
        feedback.impactOccurred(intensity: 0.48)

        // The server has finished; expose that result as soon as the short cue
        // ends instead of adding a multi-second presentation delay.
        return !Task.isCancelled
    }

    private static func consumeIfNeeded(key: String) -> Bool {
        let defaults = UserDefaults.standard
        var history = defaults.stringArray(forKey: historyKey) ?? []
        guard !history.contains(key) else { return false }

        history.append(key)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        defaults.set(history, forKey: historyKey)
        return true
    }

    private static func makeFeedbackGenerator() -> UIImpactFeedbackGenerator? {
        if #available(iOS 26.0, *) {
            let view = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?
                .rootViewController?.view
            guard let view else { return nil }
            return UIImpactFeedbackGenerator(style: .soft, view: view)
        } else {
            return UIImpactFeedbackGenerator(style: .soft)
        }
    }
}

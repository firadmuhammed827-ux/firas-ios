import SwiftUI

enum FirasActivityKind: Sendable {
    case thinking
    case writing
    case searching
    case building

    var title: LocalizedStringResource {
        switch self {
        case .thinking: LocalizedStringResource("activity.thinking", table: "Activity")
        case .writing: LocalizedStringResource("activity.writing", table: "Activity")
        case .searching: LocalizedStringResource("activity.searching", table: "Activity")
        case .building: LocalizedStringResource("activity.building", table: "Activity")
        }
    }

    var systemImage: String {
        switch self {
        case .thinking: "brain"
        case .writing: "pencil.line"
        case .searching: "magnifyingglass"
        case .building: "hammer"
        }
    }
}

struct FirasActivityLabel: View {
    let kind: FirasActivityKind
    var isActive = true
    var showsSurface = true

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        if showsSurface {
            GlassSurface(cornerRadius: 14, tintStrength: 0.025, usesLiquidGlass: false) {
                label
                    .padding(.horizontal, 11)
                    .frame(minHeight: 38)
            }
        } else {
            label
                .frame(minHeight: 32)
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(preferences.palette.accent)
                .accessibilityHidden(true)

            FirasActivityText(title: kind.title, isActive: isActive)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FirasActivityText: View {
    let title: LocalizedStringResource
    let isActive: Bool

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var shouldAnimate: Bool {
        isActive && scenePhase == .active && preferences.motionEnabled && !reduceMotion
    }

    var body: some View {
        if shouldAnimate {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                textWithSweep(progress: sweepProgress(at: context.date))
            }
        } else {
            baseText
        }
    }

    private var baseText: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(preferences.palette.textSecondary)
            .lineLimit(1)
    }

    private func textWithSweep(progress: Double) -> some View {
        baseText
            .overlay {
                GeometryReader { proxy in
                    let sweepWidth = max(42, proxy.size.width * 0.48)

                    LinearGradient(
                        colors: [
                            .clear,
                            preferences.palette.accent.opacity(0.88),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: sweepWidth)
                    .offset(
                        x: -sweepWidth + (proxy.size.width + sweepWidth) * CGFloat(progress)
                    )
                }
                .mask(baseText)
                .accessibilityHidden(true)
            }
    }

    private func sweepProgress(at date: Date) -> Double {
        let duration = 1.65
        return date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration) / duration
    }
}

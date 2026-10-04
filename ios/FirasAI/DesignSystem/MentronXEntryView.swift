import SwiftUI

/// Native recreation of the MentronX lockup shown by the web product when an
/// account is opened. It deliberately plays at meaningful entry moments rather
/// than on every warm launch.
struct MentronXEntryView: View {
    let onFinished: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var primaryProgress: CGFloat = 0
    @State private var crossProgress: CGFloat = 0
    @State private var lockupVisible = false
    @State private var isVisible = true

    var body: some View {
        ZStack {
            preferences.palette.background
                .ignoresSafeArea()

            HStack(spacing: lockupVisible ? 13 : 0) {
                MentronXMark(
                    primaryProgress: primaryProgress,
                    crossProgress: crossProgress
                )
                .frame(
                    width: lockupVisible ? 62 : 198,
                    height: lockupVisible ? 50 : 160
                )

                if lockupVisible {
                    HStack(spacing: 7) {
                        Text(verbatim: "BY")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .tracking(2.8)
                            .foregroundStyle(preferences.palette.textMuted)

                        Text(verbatim: "MentronX")
                            .font(.system(size: 27, weight: .semibold, design: .rounded))
                            .tracking(-0.8)
                            .foregroundStyle(preferences.palette.textPrimary)
                    }
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .leading)),
                            removal: .opacity
                        )
                    )
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "BY MentronX"))
        }
        .opacity(isVisible ? 1 : 0)
        .task { await play() }
    }

    private func play() async {
        if reduceMotion || !preferences.motionEnabled {
            primaryProgress = 1
            crossProgress = 1
            lockupVisible = true
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            onFinished()
            return
        }

        withAnimation(.timingCurve(0.50, 0.05, 0.30, 1, duration: 1.15)) {
            primaryProgress = 1
        }

        try? await Task.sleep(for: .milliseconds(1_120))
        guard !Task.isCancelled else { return }
        withAnimation(.timingCurve(0.40, 0, 0.30, 1, duration: 0.42)) {
            crossProgress = 1
        }

        try? await Task.sleep(for: .milliseconds(560))
        guard !Task.isCancelled else { return }
        withAnimation(.timingCurve(0.22, 0.80, 0.28, 1, duration: 0.56)) {
            lockupVisible = true
        }

        try? await Task.sleep(for: .milliseconds(1_470))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.34)) {
            isVisible = false
        }

        try? await Task.sleep(for: .milliseconds(340))
        guard !Task.isCancelled else { return }
        onFinished()
    }
}

private struct MentronXMark: View {
    let primaryProgress: CGFloat
    let crossProgress: CGFloat

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        ZStack {
            MentronXPrimaryStroke()
                .trim(from: 0, to: primaryProgress)
                .stroke(
                    LinearGradient(
                        colors: [
                            preferences.palette.accent,
                            preferences.palette.accentHover,
                            preferences.palette.textPrimary
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    ),
                    style: StrokeStyle(
                        lineWidth: 5.2,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

            MentronXCrossStroke()
                .trim(from: 0, to: crossProgress)
                .stroke(
                    preferences.palette.accent,
                    style: StrokeStyle(
                        lineWidth: 5.2,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        }
        .padding(5)
    }
}

/// Original MentronX mark path: `M8 52 18 12 30 44 42 12 54 52 78 12`.
private struct MentronXPrimaryStroke: Shape {
    func path(in rect: CGRect) -> Path {
        let points = [
            CGPoint(x: 8, y: 52),
            CGPoint(x: 18, y: 12),
            CGPoint(x: 30, y: 44),
            CGPoint(x: 42, y: 12),
            CGPoint(x: 54, y: 52),
            CGPoint(x: 78, y: 12),
        ]
        return scaledPath(points, in: rect)
    }
}

/// Original MentronX cross stroke: `M54 12 78 52`.
private struct MentronXCrossStroke: Shape {
    func path(in rect: CGRect) -> Path {
        scaledPath(
            [CGPoint(x: 54, y: 12), CGPoint(x: 78, y: 52)],
            in: rect
        )
    }
}

private nonisolated func scaledPath(_ points: [CGPoint], in rect: CGRect) -> Path {
    var path = Path()
    guard let first = points.first else { return path }

    let designBounds = CGRect(x: 5, y: 8, width: 76, height: 48)
    let scale = min(
        rect.width / designBounds.width,
        rect.height / designBounds.height
    )
    let renderedSize = CGSize(
        width: designBounds.width * scale,
        height: designBounds.height * scale
    )
    let origin = CGPoint(
        x: rect.midX - renderedSize.width / 2,
        y: rect.midY - renderedSize.height / 2
    )

    func map(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: origin.x + (point.x - designBounds.minX) * scale,
            y: origin.y + (point.y - designBounds.minY) * scale
        )
    }

    path.move(to: map(first))
    for point in points.dropFirst() {
        path.addLine(to: map(point))
    }
    return path
}

#Preview("MentronX entry") {
    MentronXEntryView(onFinished: {})
        .environment(PreferencesStore())
}

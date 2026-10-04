import SwiftUI

struct FirasBrandMark: View {
    let size: CGFloat
    var showsWordmark = false

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(spacing: max(8, size * 0.22)) {
            Canvas { context, canvasSize in
                let scaleX = canvasSize.width / 32
                let scaleY = canvasSize.height / 44

                var stem = Path()
                stem.addRect(CGRect(x: 0, y: 0, width: 6.5 * scaleX, height: 44 * scaleY))

                var upperBeam = Path()
                upperBeam.move(to: CGPoint(x: 6.5 * scaleX, y: 0))
                upperBeam.addLine(to: CGPoint(x: 32 * scaleX, y: 0))
                upperBeam.addLine(to: CGPoint(x: 27 * scaleX, y: 8.5 * scaleY))
                upperBeam.addLine(to: CGPoint(x: 6.5 * scaleX, y: 8.5 * scaleY))
                upperBeam.closeSubpath()

                var lowerBeam = Path()
                lowerBeam.move(to: CGPoint(x: 6.5 * scaleX, y: 17 * scaleY))
                lowerBeam.addLine(to: CGPoint(x: 24 * scaleX, y: 17 * scaleY))
                lowerBeam.addLine(to: CGPoint(x: 19.5 * scaleX, y: 25.5 * scaleY))
                lowerBeam.addLine(to: CGPoint(x: 6.5 * scaleX, y: 25.5 * scaleY))
                lowerBeam.closeSubpath()

                context.fill(stem, with: .color(preferences.palette.accent))
                context.fill(upperBeam, with: .color(preferences.palette.accent))
                context.fill(lowerBeam, with: .color(preferences.palette.accentDeep))
            }
            .frame(width: size * 32 / 44, height: size)
            .accessibilityHidden(true)

            if showsWordmark {
                HStack(spacing: 4) {
                    Text(verbatim: "Firas")
                        .foregroundStyle(preferences.palette.textPrimary)
                    Text(verbatim: "AI")
                        .foregroundStyle(preferences.palette.accent)
                }
                .font(.system(size: size * 0.60, weight: .semibold, design: .rounded))
                .tracking(-0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("app.name")
    }
}

#Preview("Brand mark") {
    FirasBrandMark(size: 44, showsWordmark: true)
        .padding()
        .environment(PreferencesStore())
}

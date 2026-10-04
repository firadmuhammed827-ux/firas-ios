import SwiftUI

struct GlassSurface<Content: View>: View {
    let cornerRadius: CGFloat
    let tintStrength: Double
    let usesLiquidGlass: Bool
    let content: Content

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        cornerRadius: CGFloat = 22,
        tintStrength: Double = 0.08,
        usesLiquidGlass: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.tintStrength = tintStrength
        self.usesLiquidGlass = usesLiquidGlass
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26, *), usesLiquidGlass, !reduceTransparency {
            content
                .glassEffect(
                    .regular.tint(preferences.palette.accent.opacity(tintStrength)),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content
                .background(
                    reduceTransparency
                        ? AnyShapeStyle(preferences.palette.surface)
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(preferences.palette.border.opacity(0.9), lineWidth: 1)
                }
        }
    }
}

/// A shared sampling region keeps adjacent controls from rendering separate
/// glass layers. Earlier systems and opaque accessibility settings use the
/// exact same layout, with the button style providing its material fallback.
struct FirasGlassControlGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26, *), !reduceTransparency {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

/// Apply this to a Button after sizing its label, so the visible control and
/// the touch target are the same view. Native styles own glass interaction.
struct FirasGlassControlStyle: ViewModifier {
    var prominent = false
    var circular = false

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26, *), !reduceTransparency {
                if prominent {
                    content.buttonStyle(.glassProminent)
                } else {
                    content.buttonStyle(.glass)
                }
            } else {
                content.buttonStyle(FirasFallbackControlStyle(prominent: prominent))
            }
        }
        .buttonBorderShape(circular ? .circle : .capsule)
        .tint(preferences.palette.accent)
        .transaction { transaction in
            if reduceMotion || !preferences.motionEnabled {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

private struct FirasFallbackControlStyle: ButtonStyle {
    let prominent: Bool

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    private var background: AnyShapeStyle {
        if prominent { return AnyShapeStyle(preferences.palette.accent) }
        if reduceTransparency { return AnyShapeStyle(preferences.palette.surface) }
        return AnyShapeStyle(.thinMaterial)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? preferences.palette.onAccent : preferences.palette.textPrimary)
            .background(background, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(prominent ? .clear : preferences.palette.borderStrong, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .scaleEffect(
                configuration.isPressed && isEnabled && preferences.motionEnabled && !reduceMotion
                    ? 0.96 : 1
            )
            .animation(
                preferences.motionEnabled && !reduceMotion ? .easeOut(duration: 0.12) : nil,
                value: configuration.isPressed
            )
    }
}

struct GlassIconButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .modifier(FirasGlassControlStyle(prominent: prominent, circular: true))
        .accessibilityLabel(title)
    }
}

struct FirasBackground: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            preferences.palette.background

            RadialGradient(
                colors: [
                    preferences.palette.accent.opacity(preferences.theme == .black ? 0.08 : 0.16),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 560
            )
            .opacity(reduceMotion ? 0.55 : 1)

            LinearGradient(
                colors: [
                    .clear,
                    preferences.palette.backgroundSubtle.opacity(0.42)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

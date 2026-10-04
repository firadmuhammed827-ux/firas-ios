import AVFoundation
import SwiftUI
import UIKit

enum VoiceCallPhase: Sendable, Equatable {
    case listening
    case thinking
    case speaking

    var title: LocalizedStringResource {
        switch self {
        case .listening: ChatStrings.voiceListening
        case .thinking: ChatStrings.voiceThinking
        case .speaking: ChatStrings.voiceSpeaking
        }
    }
}

struct VoiceCallView: View {
    var onEnd: (() -> Void)? = nil

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("callVoice") private var selectedVoice = "cedar"
    @State private var controller = LiveVoiceController()

    var body: some View {
        ZStack {
            FirasBackground()

            VStack(spacing: 0) {
                callHeader
                Spacer(minLength: 24)
                VoiceReactiveOrb(
                    phase: controller.phase,
                    audioLevel: controller.audioLevel,
                    connectionState: controller.connectionState
                )
                phaseLabel
                    .padding(.top, 28)
                statusMessage
                    .padding(.top, 9)
                Spacer(minLength: 26)
                callControls
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .tint(preferences.palette.accent)
        .environment(\.layoutDirection, preferences.language.layoutDirection)
        .task {
            await controller.start(
                language: preferences.language,
                voice: selectedVoice
            )
        }
        .onDisappear {
            Task { await controller.end() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            Task { await controller.handleInterruption() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began
            else { return }
            Task { await controller.handleInterruption() }
        }
    }

    private var callHeader: some View {
        VStack(spacing: 8) {
            FirasBrandMark(size: 31, showsWordmark: true)

            Text(ChatStrings.voiceTitle)
                .font(.headline)
                .foregroundStyle(preferences.palette.textPrimary)

            TimelineView(.periodic(from: controller.startedAt ?? Date(), by: 1)) { context in
                Text(verbatim: elapsedTime(at: context.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(preferences.palette.textMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var phaseLabel: some View {
        Text(primaryStatus)
            .font(.title3.weight(.semibold))
            .foregroundStyle(preferences.palette.textPrimary)
            .contentTransition(.opacity)
            .animation(phaseAnimation, value: controller.phase)
            .animation(phaseAnimation, value: controller.connectionState)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var statusMessage: some View {
        Text(secondaryStatus)
            .font(.caption)
            .foregroundStyle(
                isFailure ? preferences.palette.error : preferences.palette.textMuted
            )
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 390, minHeight: 34)
            .contentTransition(.opacity)
    }

    private var callControls: some View {
        HStack(spacing: 24) {
            VoiceGlassControl(
                title: controller.isMuted ? ChatStrings.voiceUnmute : ChatStrings.voiceMute,
                systemImage: controller.isMuted ? "mic.slash.fill" : "mic.fill",
                isSelected: controller.isMuted,
                isEnabled: controller.connectionState == .connected
            ) {
                controller.toggleMute()
            }

            VoiceEndCallControl {
                Task {
                    await controller.end()
                    onEnd?()
                    dismiss()
                }
            }

            VoiceGlassControl(
                title: controller.usesSpeaker ? ChatStrings.voiceSpeakerOn : ChatStrings.voiceSpeakerOff,
                systemImage: controller.usesSpeaker ? "speaker.wave.2.fill" : "speaker.fill",
                isSelected: controller.usesSpeaker,
                isEnabled: controller.connectionState == .connected
            ) {
                controller.toggleSpeaker()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var primaryStatus: LocalizedStringResource {
        switch controller.connectionState {
        case .idle, .requestingPermission:
            ChatStrings.voiceRequestingPermission
        case .connecting:
            ChatStrings.voiceConnecting
        case .connected:
            controller.phase.title
        case .ended:
            ChatStrings.voiceEnded
        case .failed:
            ChatStrings.voiceConnectionFailed
        }
    }

    private var secondaryStatus: LocalizedStringResource {
        switch controller.connectionState {
        case .idle, .requestingPermission:
            ChatStrings.voiceRequestingPermission
        case .connecting:
            ChatStrings.voiceConnectionPending
        case .connected:
            ChatStrings.voiceConnected
        case .ended:
            ChatStrings.voiceEnded
        case .failed(let code):
            errorResource(for: code)
        }
    }

    private var isFailure: Bool {
        if case .failed = controller.connectionState { true } else { false }
    }

    private var phaseAnimation: Animation? {
        preferences.motionEnabled && !reduceMotion ? .easeInOut(duration: 0.20) : nil
    }

    private func errorResource(for code: String) -> LocalizedStringResource {
        switch code {
        case "voice_microphone_denied": ChatStrings.voiceMicrophoneDenied
        case "voice_signin_required": ChatStrings.voiceSignInRequired
        case "voice_quota_reached": ChatStrings.voiceQuotaReached
        case "voice_service_unavailable": ChatStrings.voiceServiceUnavailable
        case "voice_connection_lost": ChatStrings.voiceConnectionLost
        case "voice_audio_route_failed": ChatStrings.voiceAudioRouteFailed
        default: ChatStrings.voiceConnectionFailed
        }
    }

    private func elapsedTime(at date: Date) -> String {
        guard let startedAt = controller.startedAt else { return "00:00" }
        let elapsed = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
}

private struct VoiceReactiveOrb: View {
    let phase: VoiceCallPhase
    let audioLevel: Double
    let connectionState: LiveVoiceConnectionState

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var animates: Bool {
        preferences.motionEnabled && !reduceMotion
    }

    var body: some View {
        if animates {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                orb(at: context.date)
            }
        } else {
            orb(at: nil)
        }
    }

    private func orb(at date: Date?) -> some View {
        let motion = motionValues(at: date)

        return ZStack {
            Circle()
                .fill(preferences.palette.accent.opacity(reduceTransparency ? 0.10 : 0.19))
                .frame(width: 238, height: 238)
                .blur(radius: reduceTransparency ? 0 : 31)
                .scaleEffect(motion.glowScale)

            ForEach(0 ..< 3, id: \.self) { ring in
                Circle()
                    .stroke(
                        preferences.palette.accent.opacity(0.16 - Double(ring) * 0.035),
                        lineWidth: 1
                    )
                    .frame(width: 176 + CGFloat(ring * 24), height: 176 + CGFloat(ring * 24))
                    .scaleEffect(motion.ringScale + CGFloat(ring) * 0.012)
            }

            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            preferences.palette.accent.opacity(0.20),
                            preferences.palette.accent.opacity(0.76),
                            preferences.palette.accentDeep.opacity(0.54),
                            preferences.palette.accent.opacity(0.20),
                        ],
                        center: .center
                    )
                )
                .frame(width: 184, height: 184)
                .rotationEffect(.degrees(motion.rotation))
                .scaleEffect(motion.coreScale)

            GlassSurface(cornerRadius: 84, tintStrength: 0.10) {
                ZStack {
                    Circle()
                        .fill(preferences.palette.surface.opacity(reduceTransparency ? 1 : 0.44))

                    FirasBrandMark(size: 62)
                }
                .frame(width: 158, height: 158)
            }
            .scaleEffect(motion.innerScale)
        }
        .frame(width: 250, height: 250)
        .opacity(connectionState == .connected ? 1 : 0.74)
        .animation(animates ? .easeInOut(duration: 0.25) : nil, value: connectionState)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(phase.title))
    }

    private func motionValues(
        at date: Date?
    ) -> (glowScale: CGFloat, ringScale: CGFloat, coreScale: CGFloat, innerScale: CGFloat, rotation: Double) {
        guard let date else { return (1, 1, 1, 1, 0) }

        let seconds = date.timeIntervalSinceReferenceDate
        let reactive = min(1, max(0, audioLevel * 5.2))
        let speed: Double
        let baseAmplitude: Double
        switch phase {
        case .listening:
            speed = 1.65
            baseAmplitude = 0.025
        case .thinking:
            speed = 2.15
            baseAmplitude = 0.018
        case .speaking:
            speed = 0.92
            baseAmplitude = 0.046
        }

        let wave = sin((seconds / speed) * .pi * 2)
        let amplitude = baseAmplitude + reactive * 0.065
        return (
            glowScale: 1 + CGFloat(wave * amplitude + reactive * 0.055),
            ringScale: 1 + CGFloat(max(0, wave) * amplitude * 1.55 + reactive * 0.08),
            coreScale: 1 + CGFloat(wave * amplitude + reactive * 0.038),
            innerScale: 1 - CGFloat(wave * amplitude * 0.30) + CGFloat(reactive * 0.018),
            rotation: phase == .thinking
                ? seconds.truncatingRemainder(dividingBy: 10) * 36
                : wave * (4 + reactive * 8)
        )
    }
}

private struct VoiceGlassControl: View {
    let title: LocalizedStringResource
    let systemImage: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                GlassSurface(cornerRadius: 31, tintStrength: isSelected ? 0.10 : 0.035) {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(
                            isSelected ? preferences.palette.accent : preferences.palette.textPrimary
                        )
                        .frame(width: 62, height: 62)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
            .frame(minWidth: 62, minHeight: 62)
            .accessibilityLabel(Text(title))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            Text(title)
                .font(.caption)
                .foregroundStyle(preferences.palette.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 80)
    }
}

private struct VoiceEndCallControl: View {
    let action: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                GlassSurface(cornerRadius: 34, tintStrength: 0.035) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(preferences.palette.onAccent)
                        .frame(width: 68, height: 68)
                        .background(preferences.palette.error, in: Circle())
                }
            }
            .buttonStyle(.plain)
            .frame(minWidth: 68, minHeight: 68)
            .accessibilityLabel(Text(ChatStrings.voiceEnd))

            Text(ChatStrings.voiceEnd)
                .font(.caption)
                .foregroundStyle(preferences.palette.textSecondary)
        }
        .frame(width: 84)
    }
}

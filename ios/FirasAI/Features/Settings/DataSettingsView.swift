import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DataSettingsView: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(ChatStore.self) private var chatStore
    @Environment(NotificationCoordinator.self) private var notifications

    @State private var exportDocument: FirasChatBackupDocument?
    @State private var presentsExporter = false
    @State private var presentsImporter = false
    @State private var pendingImport: FirasChatBackup?
    @State private var isReadingImport = false
    @State private var confirmsImport = false
    @State private var confirmsPreferenceReset = false
    @State private var presentsWhatsNew = false
    @State private var isRequestingNotifications = false
    @State private var status: DataStatus?

    var body: some View {
        VStack(spacing: 16) {
            SettingsPanel(
                "settings.data.backup",
                systemImage: "arrow.up.arrow.down.doc",
                footer: session.isAuthenticated
                    ? "settings.data.backup.footer"
                    : "settings.data.backup.signIn"
            ) {
                VStack(spacing: 12) {
                    SettingsSubmitButton(
                        title: "settings.data.export",
                        systemImage: "square.and.arrow.up",
                        isWorking: session.settingsOperation == .exportingChats,
                        isDisabled: !session.isAuthenticated || session.isWorking || isReadingImport,
                        action: exportChats
                    )

                    SettingsSubmitButton(
                        title: "settings.data.import",
                        systemImage: "square.and.arrow.down",
                        prominent: false,
                        isWorking: isReadingImport || session.settingsOperation == .importingChats,
                        isDisabled: !session.isAuthenticated || session.isWorking || isReadingImport,
                        action: { presentsImporter = true }
                    )
                }
            }

            SettingsPanel(
                "settings.data.device",
                systemImage: "iphone",
                footer: "settings.data.clear.footer"
            ) {
                SettingsSubmitButton(
                    title: "settings.data.clear",
                    systemImage: "arrow.counterclockwise",
                    isDestructive: true,
                    prominent: false,
                    action: { confirmsPreferenceReset = true }
                )
            }

            SettingsPanel(
                "settings.notifications.title",
                systemImage: "bell.badge.waveform",
                footer: "settings.notifications.footer"
            ) {
                SettingsValueRow(
                    "settings.notifications.status",
                    systemImage: notificationStatusImage
                ) {
                    Text(notificationStatusKey)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(notificationStatusColor)
                }

                SettingsDivider()

                SettingsSubmitButton(
                    title: notificationActionKey,
                    systemImage: notifications.permission == .denied
                        ? "gearshape"
                        : "bell.badge",
                    prominent: notifications.permission != .authorized,
                    isWorking: isRequestingNotifications || notifications.isRegistering,
                    isDisabled: notifications.permission == .authorized,
                    action: configureNotifications
                )

                if let error = notifications.registrationError, !error.isEmpty {
                    SettingsNoticeBanner(verbatim: error, kind: .error)
                }
            }

            AboutSettingsPanel(presentsWhatsNew: $presentsWhatsNew)

            LocalPreferencesNote(compact: false)
                .padding(.horizontal, 4)

            if let status {
                switch status {
                case .success(let key):
                    SettingsNoticeBanner(key, kind: .success)
                case .imported(let count):
                    SettingsNoticeBanner(
                        message: Text("settings.data.imported")
                            + Text(verbatim: " \(count)"),
                        kind: .success
                    )
                case .validationError(let key):
                    SettingsNoticeBanner(key, kind: .error)
                case .error(let message):
                    SettingsNoticeBanner(verbatim: message, kind: .error)
                }
            }
        }
        .fileExporter(
            isPresented: $presentsExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Firas-AI-backup"
        ) { result in
            switch result {
            case .success:
                status = .success("settings.data.exported")
            case .failure(let error):
                status = .error(error.localizedDescription)
            }
            exportDocument = nil
        }
        .fileImporter(
            isPresented: $presentsImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                readImport(url)
            case .failure(let error):
                status = .error(error.localizedDescription)
            }
        }
        .confirmationDialog(
            "settings.data.import.confirmTitle",
            isPresented: $confirmsImport,
            titleVisibility: .visible
        ) {
            Button("settings.data.import.confirm", action: importChats)
            Button("common.cancel", role: .cancel) {
                pendingImport = nil
            }
        } message: {
            Text("settings.data.import.confirmMessage")
        }
        .confirmationDialog(
            "settings.data.clear.confirmTitle",
            isPresented: $confirmsPreferenceReset,
            titleVisibility: .visible
        ) {
            Button("settings.data.clear.confirm", role: .destructive) {
                preferences.resetToDefaults()
                status = .success("settings.data.preferencesCleared")
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.data.clear.confirmMessage")
        }
        .sheet(isPresented: $presentsWhatsNew) {
            WhatsNewSheet()
                .presentationDragIndicator(.visible)
                .presentationSizing(.form)
        }
    }

    private var notificationStatusKey: LocalizedStringKey {
        switch notifications.permission {
        case .unknown: "settings.notifications.status.unknown"
        case .denied: "settings.notifications.status.denied"
        case .authorized: "settings.notifications.status.authorized"
        }
    }

    private var notificationActionKey: LocalizedStringKey {
        switch notifications.permission {
        case .unknown: "settings.notifications.enable"
        case .denied: "settings.notifications.openSettings"
        case .authorized: "settings.notifications.enabled"
        }
    }

    private var notificationStatusImage: String {
        switch notifications.permission {
        case .unknown: "bell"
        case .denied: "bell.slash"
        case .authorized: "checkmark.circle.fill"
        }
    }

    private var notificationStatusColor: Color {
        switch notifications.permission {
        case .unknown: preferences.palette.textSecondary
        case .denied: preferences.palette.error
        case .authorized: preferences.palette.success
        }
    }

    private func configureNotifications() {
        switch notifications.permission {
        case .denied:
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(settingsURL)
        case .unknown:
            isRequestingNotifications = true
            Task { @MainActor in
                defer { isRequestingNotifications = false }
                _ = await notifications.requestAuthorizationIfNeeded(
                    context: .userRequested,
                    preferredLanguageCode: preferences.language.rawValue
                )
            }
        case .authorized:
            break
        }
    }

    private func exportChats() {
        status = nil
        Task { @MainActor in
            guard let backup = await session.makeChatBackup() else {
                if let error = session.errorMessage {
                    status = .error(error)
                }
                return
            }

            guard !backup.chats.isEmpty else {
                status = .success("settings.data.noChats")
                return
            }

            exportDocument = FirasChatBackupDocument(backup: backup)
            presentsExporter = true
        }
    }

    private func readImport(_ url: URL) {
        status = nil
        isReadingImport = true
        Task { @MainActor in
            defer { isReadingImport = false }
            do {
                pendingImport = try await ChatBackupFileReader.read(from: url)
                confirmsImport = true
            } catch {
                if let key = importValidationKey(for: error) {
                    status = .validationError(key)
                } else {
                    status = .error(error.localizedDescription)
                }
            }
        }
    }

    private func importChats() {
        guard let backup = pendingImport else { return }
        pendingImport = nil
        status = nil

        Task { @MainActor in
            if let count = await session.importChatBackup(backup) {
                await chatStore.loadConversations()
                status = .imported(count)
            } else if let error = session.errorMessage {
                status = .error(error)
            }
        }
    }

    private func importValidationKey(for error: Error) -> LocalizedStringKey? {
        guard let validationError = error as? ChatBackupValidationError else {
            return nil
        }

        switch validationError {
        case .fileTooLarge:
            return "settings.data.invalidImport.tooLarge"
        case .unsupportedFormat:
            return "settings.data.invalidImport.format"
        case .noChats:
            return "settings.data.invalidImport.empty"
        case .tooManyChats:
            return "settings.data.invalidImport.tooMany"
        }
    }
}

private enum DataStatus {
    case success(LocalizedStringKey)
    case imported(Int)
    case validationError(LocalizedStringKey)
    case error(String)
}

private struct AboutSettingsPanel: View {
    @Binding var presentsWhatsNew: Bool

    @Environment(PreferencesStore.self) private var preferences

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (short, build) {
        case let (.some(short), .some(build)):
            return "\(short) (\(build))"
        case let (.some(short), .none):
            return short
        default:
            return "—"
        }
    }

    var body: some View {
        SettingsPanel("settings.data.about", systemImage: "info.circle") {
            VStack(spacing: 2) {
                HStack(spacing: 12) {
                    Image(systemName: "number")
                        .foregroundStyle(preferences.palette.accent)
                        .frame(width: 24)
                        .accessibilityHidden(true)

                    Text("settings.data.version")
                        .font(.body.weight(.medium))
                        .foregroundStyle(preferences.palette.textPrimary)

                    Spacer(minLength: 12)

                    Text(verbatim: version)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(preferences.palette.textSecondary)
                        .environment(\.layoutDirection, .leftToRight)
                }
                .frame(minHeight: 52)

                SettingsDivider()

                Button {
                    presentsWhatsNew = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(preferences.palette.accent)
                            .frame(width: 24)
                            .accessibilityHidden(true)

                        Text("settings.data.whatsNew")
                            .font(.body.weight(.medium))
                            .foregroundStyle(preferences.palette.textPrimary)

                        Spacer(minLength: 12)

                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(preferences.palette.textMuted)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct WhatsNewSheet: View {
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()

                ScrollView {
                    GlassSurface(cornerRadius: 26, tintStrength: 0.06) {
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 38, weight: .medium))
                                .foregroundStyle(preferences.palette.accent)
                                .accessibilityHidden(true)

                            Text("settings.whatsNew.title")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(preferences.palette.textPrimary)

                            WhatsNewRow(
                                systemImage: "rectangle.split.3x1",
                                title: "settings.whatsNew.native",
                                detail: "settings.whatsNew.native.footer"
                            )
                            WhatsNewRow(
                                systemImage: "paintpalette",
                                title: "settings.whatsNew.themes",
                                detail: "settings.whatsNew.themes.footer"
                            )
                            WhatsNewRow(
                                systemImage: "arrow.up.arrow.down.doc",
                                title: "settings.whatsNew.backup",
                                detail: "settings.whatsNew.backup.footer"
                            )
                        }
                        .padding(20)
                    }
                    .frame(maxWidth: 620)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("settings.data.whatsNew")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                        .foregroundStyle(preferences.palette.accent)
                }
            }
        }
    }
}

private struct WhatsNewRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: systemImage)
                .foregroundStyle(preferences.palette.accent)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(preferences.palette.textPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(preferences.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

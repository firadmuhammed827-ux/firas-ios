import SwiftUI
import UniformTypeIdentifiers
import WebKit

private enum CodeWorkspaceTab: String, CaseIterable, Identifiable {
    case files
    case editor
    case preview

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .files: CodeStrings.files
        case .editor: CodeStrings.editor
        case .preview: CodeStrings.preview
        }
    }

    var systemImage: String {
        switch self {
        case .files: "folder"
        case .editor: "chevron.left.forwardslash.chevron.right"
        case .preview: "play.rectangle"
        }
    }
}

struct CodeScreen: View {
    let store: CodeStore
    let showsSidebarButton: Bool
    let onOpenSidebar: () -> Void
    let onOpenProfile: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var projectName = ""
    @State private var prompt = ""
    @State private var selectedTab: CodeWorkspaceTab = .editor
    @State private var showsImporter = false
    @State private var pendingDelete: CodeWorkspaceProject?
    @State private var showsOmnixAccess = false

    init(
        store: CodeStore,
        showsSidebarButton: Bool,
        onOpenSidebar: @escaping () -> Void,
        onOpenProfile: @escaping () -> Void
    ) {
        self.store = store
        self.showsSidebarButton = showsSidebarButton
        self.onOpenSidebar = onOpenSidebar
        self.onOpenProfile = onOpenProfile
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()
                if let workspace = store.workspace {
                    workspaceView(workspace)
                } else {
                    homeView
                }
            }
            .environment(\.layoutDirection, preferences.language.layoutDirection)
            .navigationTitle(
                store.workspace.map { Text(verbatim: $0.name) } ?? Text(CodeStrings.title)
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { toolbarContent }
            .overlay(alignment: .top) {
                if let error = store.errorMessage, !error.isEmpty {
                    CodeErrorBanner(message: error) {
                        store.errorMessage = nil
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
                }
            }
        }
        .task(id: session.identityID) {
            await store.loadProjects()
            store.resumeIfNeeded()
        }
        .sheet(isPresented: $showsOmnixAccess) { OmnixAccessSheet(product: .code, initialDraft: prompt) }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: Self.attachmentTypes,
            allowsMultipleSelection: true,
            onCompletion: handleAttachments
        )
        .alert(deleteAlertTitle, isPresented: deleteAlertBinding) {
            Button(role: .destructive) {
                guard let pendingDelete else { return }
                Task { await store.delete(pendingDelete) }
                self.pendingDelete = nil
            } label: {
                Text(CodeStrings.delete)
            }
            Button(role: .cancel) { pendingDelete = nil } label: {
                Text(CodeStrings.cancel)
            }
        } message: {
            if let pendingDelete { Text(verbatim: pendingDelete.name) }
        }
    }

    private var homeView: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                CodeHeroCard()
                Button { showsOmnixAccess = true } label: {
                    HStack {
                        Text(verbatim: "omnix 1").font(.headline).environment(\.layoutDirection, .leftToRight)
                        Spacer()
                        Text(verbatim: preferences.language == .arabic ? "طلب الوصول" : "Request access")
                        Image(systemName: "chevron.forward")
                    }.padding(14)
                }.buttonStyle(.bordered)
                buildCard

                if let response = store.lastResponse {
                    GlassSurface(cornerRadius: 20, tintStrength: 0.03) {
                        Text(verbatim: response).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }

                if store.isBuilding {
                    CodeBuildProgressCard(store: store)
                }

                if !store.projects.isEmpty {
                    recentProjects
                }
            }
            .frame(maxWidth: min(820, preferences.contentWidth.maxWidth))
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var buildCard: some View {
        GlassSurface(cornerRadius: 24, tintStrength: 0.045) {
            VStack(alignment: .leading, spacing: 13) {
                TextField(
                    text: $projectName,
                    prompt: Text(CodeStrings.projectNamePlaceholder)
                ) {
                    Text(CodeStrings.projectNamePlaceholder)
                }
                    .font(.headline)
                    .foregroundStyle(preferences.palette.textPrimary)
                    .padding(.horizontal, 13)
                    .frame(minHeight: 48)
                    .background(preferences.palette.surfaceSunken.opacity(0.68), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel(Text(CodeStrings.projectName))

                TextField(
                    text: $prompt,
                    prompt: Text(CodeStrings.promptPlaceholder),
                    axis: .vertical
                ) {
                    Text(CodeStrings.promptPlaceholder)
                }
                    .font(.body)
                    .foregroundStyle(preferences.palette.textPrimary)
                    .lineLimit(4...9)
                    .padding(13)
                    .background(preferences.palette.surfaceSunken.opacity(0.68), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel(Text(CodeStrings.prompt))

                if !store.attachments.isEmpty || store.isReadingAttachments {
                    attachmentTray
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { buildActions }
                    VStack(spacing: 10) { buildActions }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var buildActions: some View {
        Button {
            showsImporter = true
        } label: {
            Label(CodeStrings.attach, systemImage: "paperclip")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
        }
        .buttonStyle(.bordered)
        .disabled(store.isReadingAttachments || store.isBuilding)

        Button(action: createBlank) {
            Label(CodeStrings.blank, systemImage: "doc.badge.plus")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
        }
        .buttonStyle(.bordered)
        .disabled(store.isBuilding)

        if session.isAuthenticated {
            Button(action: startBuild) {
                Label(CodeStrings.build, systemImage: "sparkles")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(preferences.palette.accent)
            .foregroundStyle(preferences.palette.onAccent)
            .disabled(!canBuild)
        } else {
            Button(action: onOpenProfile) {
                Label(CodeStrings.signIn, systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(preferences.palette.accent)
            .foregroundStyle(preferences.palette.onAccent)
        }
    }

    private var attachmentTray: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isReadingAttachments {
                HStack(spacing: 8) {
                    ProgressView().tint(preferences.palette.accent)
                    Text(CodeStrings.readingAttachments)
                        .font(.caption)
                        .foregroundStyle(preferences.palette.textSecondary)
                }
                .frame(minHeight: 36)
            }
            ForEach(store.attachments) { attachment in
                HStack(spacing: 9) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(preferences.palette.accent)
                        .accessibilityHidden(true)
                    Text(verbatim: attachment.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(preferences.palette.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        store.removeAttachment(attachment)
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Text(CodeStrings.removeAttachment))
                }
                .padding(.leading, 11)
                .padding(.trailing, 2)
                .background(preferences.palette.surfaceSunken.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(CodeStrings.recent, systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .foregroundStyle(preferences.palette.textPrimary)
                .padding(.horizontal, 4)

            ForEach(store.projects) { project in
                CodeProjectRow(
                    project: project,
                    open: { store.open(project) },
                    delete: { pendingDelete = project }
                )
            }
        }
    }

    @ViewBuilder
    private func workspaceView(_ workspace: CodeWorkspaceProject) -> some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                CodeFileNavigator(store: store)
                    .frame(width: 250)
                Divider().overlay(preferences.palette.border)
                VStack(spacing: 0) {
                    CodeEditorPreviewPicker(selectedTab: $selectedTab, includesFiles: false)
                        .padding(10)
                    Divider().overlay(preferences.palette.border)
                    if selectedTab == .preview {
                        previewPane
                    } else {
                        editorPane
                    }
                }
            }
        } else {
            VStack(spacing: 0) {
                CodeEditorPreviewPicker(selectedTab: $selectedTab, includesFiles: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                Divider().overlay(preferences.palette.border)
                switch selectedTab {
                case .files:
                    CodeFileNavigator(store: store)
                case .editor:
                    editorPane
                case .preview:
                    previewPane
                }
            }
        }
    }

    private var editorPane: some View {
        ZStack(alignment: .topLeading) {
            preferences.palette.backgroundSubtle.opacity(0.35)
            if store.currentFile == nil {
                VStack(spacing: 10) {
                    Image(systemName: "doc")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(preferences.palette.textMuted)
                    Text(CodeStrings.files)
                        .font(.headline)
                        .foregroundStyle(preferences.palette.textSecondary)
                }
            } else {
                TextEditor(text: editorBinding)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(preferences.palette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .environment(\.layoutDirection, .leftToRight)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    private var previewPane: some View {
        Group {
            if let html = store.previewHTML {
                CodePreviewView(html: html)
                    .clipShape(.rect(cornerRadius: 12))
                    .padding(10)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(preferences.palette.textMuted)
                    Text(CodeStrings.noPreview)
                        .font(.headline)
                        .foregroundStyle(preferences.palette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(preferences.palette.backgroundSubtle.opacity(0.35))
    }

    private var editorBinding: Binding<String> {
        Binding(
            get: { store.editorText },
            set: { store.updateEditorText($0) }
        )
    }

    private var canBuild: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.canBuild
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { presented in if !presented { pendingDelete = nil } }
        )
    }

    private var deleteAlertTitle: String {
        preferences.language == .arabic ? "حذف هذا المشروع؟" : "Delete this project?"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if showsSidebarButton {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenSidebar) {
                    Image(systemName: "line.3.horizontal")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(CodeStrings.openSidebar))
            }
        }

        if store.workspace != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: store.showProjectLibrary) {
                    Image(systemName: "square.grid.2x2")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(CodeStrings.library))
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onOpenProfile) {
                Image(systemName: "person.crop.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text(CodeStrings.account))
        }
    }

    private func createBlank() {
        store.createBlank(name: projectName, language: preferences.language)
    }

    private func startBuild() {
        guard canBuild else { return }
        store.startBuild(
            projectName: projectName,
            prompt: prompt,
            modelGeneration: preferences.modelGeneration,
            language: preferences.language
        )
    }

    private func handleAttachments(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            store.addAttachments(urls, language: preferences.language)
        case .failure(let error):
            store.errorMessage = error.localizedDescription
        }
    }

    private static var attachmentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .image, .json, .xml]
        for ext in ["md", "swift", "js", "ts", "py", "html", "css", "docx", "pptx", "xlsx"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }
}

private struct CodeHeroCard: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 24, tintStrength: 0.05) {
            HStack(spacing: 14) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(preferences.palette.accent)
                    .frame(width: 54, height: 54)
                    .background(preferences.palette.accent.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(CodeStrings.hero)
                        .font(.headline)
                        .foregroundStyle(preferences.palette.textPrimary)
                    Text(CodeStrings.heroDetail)
                        .font(.subheadline)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CodeBuildProgressCard: View {
    let store: CodeStore
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 22, tintStrength: 0.055) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 11) {
                    FirasActivityLabel(kind: .building, isActive: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: store.buildingProjectName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(preferences.palette.textPrimary)
                        Text(CodeStrings.buildCloud)
                            .font(.caption)
                            .foregroundStyle(preferences.palette.textMuted)
                    }
                    Spacer()
                    CodeElapsedView(startedAt: store.buildStartedAt)
                }

                ProgressView(value: normalizedProgress)
                    .tint(preferences.palette.accent)

                if let stage = store.buildProgress?.stage, !stage.isEmpty {
                    Text(verbatim: stage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(preferences.palette.textSecondary)
                } else {
                    Text(CodeStrings.building)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(preferences.palette.textSecondary)
                }
            }
            .padding(16)
        }
    }

    private var normalizedProgress: Double {
        guard let percent = store.buildProgress?.percent else { return 0.08 }
        return min(max(percent > 1 ? percent / 100 : percent, 0.02), 1)
    }
}

private struct CodeProjectRow: View {
    let project: CodeWorkspaceProject
    let open: () -> Void
    let delete: () -> Void
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 18, tintStrength: 0.025) {
            HStack(spacing: 10) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(preferences.palette.accent)
                            .frame(width: 42, height: 42)
                            .background(preferences.palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: project.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(preferences.palette.textPrimary)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Text(project.files.count, format: .number)
                                Text(CodeStrings.files)
                            }
                            .font(.caption)
                            .foregroundStyle(preferences.palette.textMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 52)

                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(CodeStrings.delete))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

private struct CodeFileNavigator: View {
    let store: CodeStore
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                Label(CodeStrings.files, systemImage: "folder")
                    .font(.headline)
                    .foregroundStyle(preferences.palette.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                ForEach(store.workspace?.files ?? []) { file in
                    Button {
                        store.selectFile(path: file.path)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: fileIcon(file.path))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(
                                    store.selectedFilePath == file.path
                                        ? preferences.palette.accent
                                        : preferences.palette.textMuted
                                )
                                .frame(width: 24)
                            Text(verbatim: file.path)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(preferences.palette.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .background(
                            store.selectedFilePath == file.path
                                ? preferences.palette.accent.opacity(0.10)
                                : .clear,
                            in: RoundedRectangle(cornerRadius: 11)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .environment(\.layoutDirection, .leftToRight)
                }
            }
            .padding(8)
        }
        .background(preferences.palette.sidebar.opacity(0.78))
    }

    private func fileIcon(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return switch ext {
        case "html", "htm": "globe"
        case "css": "paintbrush"
        case "js", "mjs", "ts": "curlybraces"
        case "json": "list.bullet.rectangle"
        case "md": "doc.text"
        case "png", "jpg", "jpeg", "svg": "photo"
        default: "doc"
        }
    }
}

private struct CodeEditorPreviewPicker: View {
    @Binding var selectedTab: CodeWorkspaceTab
    let includesFiles: Bool

    var body: some View {
        Picker("", selection: $selectedTab) {
            ForEach(CodeWorkspaceTab.allCases.filter { includesFiles || $0 != .files }) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(Text(CodeStrings.editor))
    }
}

private struct CodeElapsedView: View {
    let startedAt: Date?
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        if let startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsed(startedAt, context.date))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(preferences.palette.textSecondary)
            }
        }
    }

    private func elapsed(_ start: Date, _ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CodePreviewView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Generated project pages never share the native account cookie jar or a persistent browser profile.
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        webView.isInspectable = true
        #endif
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme?.lowercased()
            // Preview HTML and ordinary web navigation only; no file URLs, app deep links, or native bridge.
            decisionHandler(["about", "http", "https", "data", "blob"].contains(scheme ?? "") ? .allow : .cancel)
        }
    }
}

private struct CodeErrorBanner: View {
    let message: String
    let dismiss: () -> Void
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 16, tintStrength: 0.02) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(preferences.palette.error)
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(preferences.palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(CodeStrings.dismissError))
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
        }
    }
}

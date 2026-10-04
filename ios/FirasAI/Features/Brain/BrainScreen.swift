import SwiftUI
import UniformTypeIdentifiers

struct BrainScreen: View {
    let store: BrainStore
    let showsSidebarButton: Bool
    let onOpenSidebar: () -> Void
    let onOpenProfile: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @State private var query = ""
    @State private var showsImporter = false
    @State private var pendingDelete: BrainDocument?
    @FocusState private var isSearchFocused: Bool

    init(
        store: BrainStore,
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
                content
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
            }
            .navigationTitle(Text(BrainStrings.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { toolbarContent }
            .overlay(alignment: .top) {
                if let error = store.errorMessage, !error.isEmpty {
                    BrainErrorBanner(message: error) {
                        store.errorMessage = nil
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
                }
            }
        }
        .task(id: session.identityID) { await store.loadLibrary() }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: Self.supportedImportTypes,
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .sheet(isPresented: passagePresentedBinding) {
            if let passage = store.selectedPassage {
                BrainPassageSheet(passage: passage) {
                    store.dismissPassage()
                }
                .environment(preferences)
                .environment(\.locale, preferences.language.locale)
                .environment(\.layoutDirection, preferences.language.layoutDirection)
            }
        }
        .alert(deleteAlertTitle, isPresented: deleteAlertBinding) {
            Button(role: .destructive) {
                guard let document = pendingDelete else { return }
                Task { await store.delete(document) }
                pendingDelete = nil
            } label: {
                Text(BrainStrings.delete)
            }
            Button(role: .cancel) { pendingDelete = nil } label: {
                Text(BrainStrings.cancel)
            }
        } message: {
            if let pendingDelete {
                Text(verbatim: pendingDelete.title)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !session.isAuthenticated {
            signedOutView
        } else if store.isLoading, store.library == nil {
            ProgressView()
                .tint(preferences.palette.accent)
        } else {
            libraryView
        }
    }

    private var signedOutView: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 40, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(preferences.palette.accent)
                .accessibilityHidden(true)
            Text(BrainStrings.hero)
                .font(.title2.weight(.semibold))
                .foregroundStyle(preferences.palette.textPrimary)
                .multilineTextAlignment(.center)
            Text(BrainStrings.heroDetail)
                .font(.body)
                .foregroundStyle(preferences.palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onOpenProfile) {
                Label(BrainStrings.signIn, systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(preferences.palette.accent)
            .foregroundStyle(preferences.palette.onAccent)
        }
        .padding(28)
        .frame(maxWidth: 560)
    }

    private var libraryView: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                BrainHeroCard()
                counters
                supportCard
                sourcesCard

                if !store.documents.isEmpty {
                    searchCard
                }

                if store.isSearching {
                    HStack(spacing: 10) {
                        FirasActivityLabel(kind: .searching, isActive: true)
                        Text(BrainStrings.searching)
                            .font(.footnote)
                            .foregroundStyle(preferences.palette.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !store.hits.isEmpty {
                    resultsCard
                } else if store.didSearch, !store.isSearching {
                    Text(BrainStrings.noResults)
                        .font(.subheadline)
                        .foregroundStyle(preferences.palette.textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 18)
                }
            }
            .frame(maxWidth: preferences.contentWidth.maxWidth)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var counters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { counterCards }
            VStack(spacing: 12) { counterCards }
        }
    }

    @ViewBuilder
    private var counterCards: some View {
        BrainCounterCard(
            title: BrainStrings.documentsCounter,
            value: store.usage?.docs ?? store.documents.count,
            limit: store.limits?.docs ?? 0,
            systemImage: "books.vertical"
        )
        BrainCounterCard(
            title: BrainStrings.pagesCounter,
            value: store.usage?.pagesToday ?? 0,
            limit: store.limits?.pagesPerDay ?? 0,
            systemImage: "doc.text"
        )
    }

    private var supportCard: some View {
        GlassSurface(cornerRadius: 20, tintStrength: 0.025) {
            VStack(alignment: .leading, spacing: 12) {
                Label(BrainStrings.supported, systemImage: "checkmark.seal")
                    .font(.headline)
                    .foregroundStyle(preferences.palette.textPrimary)

                HStack(spacing: 8) {
                    BrainFormatBadge(label: "PDF", systemImage: "doc.richtext", isNative: true)
                    BrainFormatBadge(label: "TXT", systemImage: "text.alignleft", isNative: true)
                    BrainFormatBadge(label: "IMG", systemImage: "photo", isNative: true)
                }

                Text(BrainStrings.officeExport)
                    .font(.caption)
                    .foregroundStyle(preferences.palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourcesCard: some View {
        GlassSurface(cornerRadius: 22, tintStrength: 0.035) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    Label(BrainStrings.sources, systemImage: "books.vertical")
                        .font(.headline)
                        .foregroundStyle(preferences.palette.textPrimary)
                    Spacer()
                    Button {
                        showsImporter = true
                    } label: {
                        Label(BrainStrings.addSources, systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .disabled(store.isImporting)
                }

                if store.isImporting {
                    HStack(spacing: 10) {
                        ProgressView().tint(preferences.palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(BrainStrings.importing)
                                .font(.subheadline.weight(.semibold))
                            Text(verbatim: store.importingFilename)
                                .font(.caption)
                                .foregroundStyle(preferences.palette.textMuted)
                                .lineLimit(1)
                        }
                    }
                    .frame(minHeight: 48)
                }

                if store.documents.isEmpty, !store.isImporting {
                    Text(BrainStrings.noSources)
                        .font(.subheadline)
                        .foregroundStyle(preferences.palette.textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 18)
                } else {
                    VStack(spacing: 9) {
                        ForEach(store.documents) { document in
                            BrainDocumentRow(
                                document: document,
                                selected: store.selectedDocumentIDs.contains(document.id),
                                onSelect: { store.toggleSelection(document.id) },
                                onDelete: { pendingDelete = document }
                            )
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var searchCard: some View {
        GlassSurface(cornerRadius: 22, tintStrength: 0.045) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(BrainStrings.ask, systemImage: "quote.bubble")
                        .font(.headline)
                        .foregroundStyle(preferences.palette.textPrimary)
                    Spacer()
                    if !store.selectedDocumentIDs.isEmpty {
                        Button(action: store.clearSelection) {
                            Text(BrainStrings.allSources)
                                .font(.caption.weight(.semibold))
                                .frame(minHeight: 44)
                        }
                    }
                }

                HStack(alignment: .bottom, spacing: 10) {
                    TextField(
                        text: $query,
                        prompt: Text(BrainStrings.askPlaceholder),
                        axis: .vertical
                    ) {
                        Text(BrainStrings.askPlaceholder)
                    }
                        .focused($isSearchFocused)
                        .lineLimit(1...4)
                        .font(.body)
                        .foregroundStyle(preferences.palette.textPrimary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                        .background(preferences.palette.surfaceSunken.opacity(0.70), in: RoundedRectangle(cornerRadius: 15))
                        .onSubmit { startSearch() }

                    Button(action: startSearch) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 46, height: 46)
                            .background(canSearch ? preferences.palette.accent : preferences.palette.surfaceSunken, in: Circle())
                            .foregroundStyle(canSearch ? preferences.palette.onAccent : preferences.palette.textMuted)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSearch)
                    .accessibilityLabel(Text(BrainStrings.askButton))
                }
            }
            .padding(15)
        }
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(BrainStrings.results, systemImage: "text.magnifyingglass")
                .font(.headline)
                .foregroundStyle(preferences.palette.textPrimary)
                .padding(.horizontal, 4)

            ForEach(store.hits) { hit in
                BrainHitCard(hit: hit) {
                    Task { await store.loadPassage(for: hit) }
                }
            }
        }
    }

    private var canSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isSearching
    }

    private var passagePresentedBinding: Binding<Bool> {
        Binding(
            get: { store.selectedPassage != nil },
            set: { presented in if !presented { store.dismissPassage() } }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { presented in if !presented { pendingDelete = nil } }
        )
    }

    private var deleteAlertTitle: String {
        preferences.language == .arabic ? "حذف هذا المصدر؟" : "Delete this source?"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if showsSidebarButton {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenSidebar) {
                    Image(systemName: "line.3.horizontal")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(BrainStrings.openSidebar))
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onOpenProfile) {
                Image(systemName: "person.crop.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text(BrainStrings.account))
        }
    }

    private func startSearch() {
        guard canSearch else { return }
        isSearchFocused = false
        store.search(query: query, language: preferences.language)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            store.importDocuments(urls, language: preferences.language)
        case .failure(let error):
            store.errorMessage = error.localizedDescription
        }
    }

    private static var supportedImportTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .image, .commaSeparatedText, .json, .xml]
        for ext in ["md", "swift", "js", "ts", "py", "html", "css", "docx", "pptx", "xlsx"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }
}

private struct BrainHeroCard: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 24, tintStrength: 0.05) {
            HStack(spacing: 14) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(preferences.palette.accent)
                    .frame(width: 52, height: 52)
                    .background(preferences.palette.accent.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(BrainStrings.hero)
                        .font(.headline)
                        .foregroundStyle(preferences.palette.textPrimary)
                    Text(BrainStrings.heroDetail)
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

private struct BrainCounterCard: View {
    let title: LocalizedStringResource
    let value: Int
    let limit: Int
    let systemImage: String
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 20, tintStrength: 0.025) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(preferences.palette.accent)
                    .frame(width: 42, height: 42)
                    .background(preferences.palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(preferences.palette.textSecondary)
                    Text(verbatim: limit > 0 ? "\(value) / \(limit)" : "\(value)")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(preferences.palette.textPrimary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BrainFormatBadge: View {
    let label: String
    let systemImage: String
    let isNative: Bool
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Label {
            Text(verbatim: label)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isNative ? preferences.palette.accent : preferences.palette.textMuted)
        .padding(.horizontal, 10)
        .frame(minHeight: 34)
        .background(preferences.palette.surfaceSunken.opacity(0.65), in: Capsule())
    }
}

private struct BrainDocumentRow: View {
    let document: BrainDocument
    let selected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 11) {
                    Image(systemName: selected ? "checkmark.circle.fill" : icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(selected ? preferences.palette.accent : preferences.palette.textSecondary)
                        .frame(width: 38, height: 38)
                        .background(preferences.palette.surfaceSunken.opacity(0.75), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: document.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(preferences.palette.textPrimary)
                            .lineLimit(1)
                        Text(verbatim: "\(document.kind.rawValue.uppercased()) · \(document.pages)")
                            .font(.caption)
                            .foregroundStyle(preferences.palette.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 52)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text(BrainStrings.delete))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            selected ? preferences.palette.accent.opacity(0.09) : preferences.palette.surfaceSunken.opacity(0.50),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private var icon: String {
        switch document.kind {
        case .pdf: "doc.richtext"
        case .docx: "doc.text"
        case .pptx: "rectangle.on.rectangle.angled"
        case .xlsx: "tablecells"
        case .text: "text.alignleft"
        case .image: "photo"
        }
    }
}

private struct BrainHitCard: View {
    let hit: BrainHit
    let open: () -> Void
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Button(action: open) {
            GlassSurface(cornerRadius: 19, tintStrength: 0.025) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(preferences.palette.accent)
                            .accessibilityHidden(true)
                        Text(verbatim: hit.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(preferences.palette.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(pageLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(preferences.palette.accent)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 28)
                            .background(preferences.palette.accent.opacity(0.10), in: Capsule())
                    }
                    Text(verbatim: hit.text)
                        .font(.body)
                        .foregroundStyle(preferences.palette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(BrainStrings.openPassage))
    }

    private var pageLabel: String {
        let prefix = preferences.language == .arabic ? "ص" : "p"
        return "\(prefix) \(hit.label ?? String(hit.page))"
    }
}

private struct BrainPassageSheet: View {
    let passage: BrainPassage
    let close: () -> Void
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(segments) { segment in
                            Text(verbatim: segment.text)
                                .font(segment.isFocus ? .body.weight(.medium) : .body)
                                .foregroundStyle(
                                    segment.isFocus
                                        ? preferences.palette.textPrimary
                                        : preferences.palette.textSecondary
                                )
                                .textSelection(.enabled)
                                .padding(15)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    segment.isFocus
                                        ? preferences.palette.accent.opacity(0.09)
                                        : preferences.palette.surface.opacity(0.40),
                                    in: RoundedRectangle(cornerRadius: 16)
                                )
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(passage.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Text(BrainStrings.close))
                }
            }
        }
    }

    private var segments: [BrainPassageSegment] {
        passage.before.map {
            BrainPassageSegment(id: "before-\($0.ci)", text: $0.t, isFocus: false)
        } + [
            BrainPassageSegment(id: "focus-\(passage.ci)", text: passage.text, isFocus: true)
        ] + passage.after.map {
            BrainPassageSegment(id: "after-\($0.ci)", text: $0.t, isFocus: false)
        }
    }
}

private struct BrainPassageSegment: Identifiable {
    let id: String
    let text: String
    let isFocus: Bool
}

private struct BrainErrorBanner: View {
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
                .accessibilityLabel(Text(BrainStrings.dismissError))
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
        }
    }
}

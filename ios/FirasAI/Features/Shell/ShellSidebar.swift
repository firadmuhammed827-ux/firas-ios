import SwiftUI

private nonisolated struct SidebarChatDeletion: Sendable {
    let request: ChatDeletionRequest
    let product: ProductKind
    let navigationGeneration: Int
}

struct ShellSidebar: View {
    @Binding var selectedProduct: ProductKind
    @Binding var compactSidebarPresented: Bool
    @Binding var presentedSheet: ShellSheet?
    let isCompact: Bool
    /// True where iOS 26 floats this split-view column on system glass.
    var floatsOverContent = false
    /// The split view's column: shows the chosen screen in a collapsed split view.
    var onShowDetail: (() -> Void)? = nil

    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(ChatStore.self) private var chatStore
    @Environment(CodeStore.self) private var codeStore
    @Environment(BrainStore.self) private var brainStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var searchQuery = ""
    @State private var pendingDeletion: SidebarChatDeletion?
    @State private var deletionNavigationGeneration = 0
    @State private var isRefreshingRecent = false
    /// A chat this sidebar asked to open that has not opened yet.
    @State private var requestedConversationID: String?

    private let products: [ProductKind] = [.ai, .code, .brain]

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            searchField
            sidebarList
            accountFooter
        }
        .background(sidebarFill)
        .overlay(alignment: .trailing) {
            if isCompact {
                Rectangle()
                    .fill(preferences.palette.border.opacity(0.9))
                    .frame(width: 0.5)
                    .accessibilityHidden(true)
            }
        }
        .confirmationDialog(Text(ShellStrings.deleteChat), isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { deletion in
            Button(role: .destructive) { confirmDeletion(deletion) } label: {
                Text(ShellStrings.deleteChat)
            }
            Button(role: .cancel) { pendingDeletion = nil } label: {
                Text(ShellStrings.cancelDeletion)
            }
        } message: { deletion in
            Text(deletion.request.title) + Text("\n") + Text(ShellStrings.deleteChatHint)
        }
        .onChange(of: session.identityID) { _, _ in retireDeletion() }
        .onChange(of: session.identityGeneration) { _, _ in retireDeletion() }
        .onChange(of: session.isWorking) { _, working in if working { retireDeletion() } }
        .onChange(of: selectedProduct) { _, _ in
            retireDeletion()
            // Each product searches its own list.
            searchQuery = ""
        }
        .onChange(of: chatStore.selectedConversationID) { _, id in
            retireDeletion()
            if id == requestedConversationID { requestedConversationID = nil }
        }
        .onChange(of: compactSidebarPresented) { _, visible in if !visible { retireDeletion() } }
        .onChange(of: presentedSheet) { _, sheet in if sheet != nil { retireDeletion() } }
        .onDisappear { retireDeletion() }
    }

    private var sidebarHeader: some View {
        HStack(spacing: 10) {
            FirasBrandMark(size: 30, showsWordmark: true)

            Spacer(minLength: 8)

            FirasGlassControlGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: createConversation) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .modifier(FirasGlassControlStyle(circular: true))
                    .accessibilityLabel(Text(ShellStrings.newChat))

                    // The split view has its own sidebar toggle; only the
                    // drawer needs a close button.
                    if isCompact {
                        Button(action: closeSidebar) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 44, height: 44)
                                .contentShape(.circle)
                        }
                        .modifier(FirasGlassControlStyle(circular: true))
                        .accessibilityLabel(Text(ShellStrings.closeSidebar))
                    }
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, isCompact ? 8 : 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(preferences.palette.textMuted)
                .accessibilityHidden(true)

            TextField(
                text: $searchQuery,
                prompt: Text(searchPrompt)
            ) {
                Text(searchPrompt)
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(preferences.palette.textPrimary)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(preferences.palette.textMuted)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ShellStrings.clearSearch))
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, 7)
        .frame(minHeight: 44)
        .background(
            preferences.palette.surface,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(preferences.palette.border, lineWidth: 1)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var sidebarList: some View {
        List {
            Section {
                ForEach(products) { product in
                    Button {
                        selectProduct(product)
                    } label: {
                        ProductSidebarRow(
                            product: product,
                            isSelected: selectedProduct == product
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } header: {
                Text(ShellStrings.products)
                    .foregroundStyle(preferences.palette.textMuted)
            }

            Section {
                // A pull to refresh shows its own spinner instead.
                if recentIsLoading && !isRefreshingRecent {
                    loadingRow
                } else {
                    switch selectedProduct {
                    case .ai: conversationRows
                    case .code: projectRows
                    case .brain: sourceRows
                    }
                }
            } header: {
                Text(recentHeader)
                    .foregroundStyle(preferences.palette.textMuted)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 48)
        .refreshable { await refreshRecent() }
    }

    @ViewBuilder
    private var conversationRows: some View {
        let conversations = filteredConversations
        if conversations.isEmpty {
            emptyRow(searchTerm.isEmpty ? ShellStrings.noChats : ShellStrings.noMatches)
        } else {
            ForEach(conversations) { conversation in
                Button {
                    selectConversation(conversation.id)
                } label: {
                    RecentSidebarRow(
                        title: conversation.title,
                        systemImage: conversation.pinned ? "pin.fill" : "bubble.left",
                        accentsIcon: conversation.pinned,
                        isSelected: chatStore.selectedConversationID == conversation.id,
                        isOpening: chatStore.loadingConversationID == conversation.id
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        requestDeletion(conversation)
                    } label: {
                        Label {
                            Text(ShellStrings.deleteChat)
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
    }

    /// Firas Code projects live in CodeStore on this device; a row opens the
    /// project in the Code screen and never touches the Chat conversation.
    @ViewBuilder
    private var projectRows: some View {
        let projects = filteredProjects
        if projects.isEmpty {
            emptyRow(searchTerm.isEmpty ? ShellStrings.noProjects : ShellStrings.noMatches)
        } else {
            ForEach(projects) { project in
                Button {
                    openProject(project)
                } label: {
                    RecentSidebarRow(
                        title: project.name,
                        systemImage: "folder",
                        accentsIcon: false,
                        isSelected: codeStore.workspace?.id == project.id
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }

    /// Firas Brain sources; a row chooses the source for the next question,
    /// the same choice its row on the Brain screen makes.
    @ViewBuilder
    private var sourceRows: some View {
        let sources = filteredSources
        if sources.isEmpty {
            emptyRow(searchTerm.isEmpty ? ShellStrings.noSources : ShellStrings.noMatches)
        } else {
            ForEach(sources) { source in
                let isChosen = brainStore.selectedDocumentIDs.contains(source.id)
                Button {
                    chooseSource(source)
                } label: {
                    RecentSidebarRow(
                        title: source.title,
                        systemImage: isChosen ? "checkmark.circle.fill" : "doc.text",
                        accentsIcon: isChosen,
                        isSelected: isChosen
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }

    private func emptyRow(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(preferences.palette.textMuted)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// Shown instead of the empty state while the list has not arrived yet.
    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(preferences.palette.textMuted)
            Text(ShellStrings.loading)
                .font(.subheadline)
                .foregroundStyle(preferences.palette.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .accessibilityElement(children: .combine)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var accountFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(preferences.palette.border)

            HStack(spacing: 8) {
                Button {
                    retireDeletion()
                    presentedSheet = ShellSheet.account(isAuthenticated: session.isAuthenticated)
                    closeDrawer()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: session.isAuthenticated ? "person.crop.circle.fill" : "person.crop.circle")
                            .font(.title3)
                            .foregroundStyle(preferences.palette.accent)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            if let userName = session.user?.name, !userName.isEmpty {
                                Text(userName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(preferences.palette.textPrimary)
                                    .lineLimit(1)
                            } else {
                                Text(ShellStrings.guest)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(preferences.palette.textPrimary)
                            }
                            Text(ShellStrings.account)
                                .font(.caption)
                                .foregroundStyle(preferences.palette.textMuted)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Button {
                    retireDeletion()
                    presentedSheet = .settings
                    closeDrawer()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .modifier(FirasGlassControlStyle(circular: true))
                .accessibilityLabel(Text(ShellStrings.settings))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(sidebarFill)
    }

    /// iOS 26 floats the split view's sidebar on system glass, which an opaque
    /// fill would cover. The drawer, a collapsed split view, earlier systems
    /// and Reduce Transparency keep the theme's own fill.
    private var sidebarFill: Color {
        if #available(iOS 26, *), floatsOverContent, !isCompact, !reduceTransparency {
            return .clear
        }
        return preferences.palette.sidebar
    }

    private var searchPrompt: LocalizedStringResource {
        switch selectedProduct {
        case .ai: ShellStrings.searchChats
        case .code: ShellStrings.searchProjects
        case .brain: ShellStrings.searchSources
        }
    }

    /// Chat lists its recent conversations; Code and Brain list their whole
    /// project and source libraries.
    private var recentHeader: LocalizedStringResource {
        switch selectedProduct {
        case .ai: ShellStrings.recent
        case .code: ShellStrings.projects
        case .brain: ShellStrings.sources
        }
    }

    private var searchTerm: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ordinary chats only. Server chats flagged for Code or Brain are never
    /// opened in Chat; those products list their own items.
    private var filteredConversations: [ChatSummary] {
        let term = searchTerm
        return chatStore.conversations.filter { conversation in
            guard !conversation.agent else { return false }
            guard !conversation.codeProj, !conversation.brainNb else { return false }
            return term.isEmpty || conversation.title.localizedCaseInsensitiveContains(term)
        }
    }

    private var filteredProjects: [CodeWorkspaceProject] {
        let term = searchTerm
        return codeStore.projects.filter {
            term.isEmpty || $0.name.localizedCaseInsensitiveContains(term)
        }
    }

    private var filteredSources: [BrainDocument] {
        let term = searchTerm
        return brainStore.documents.filter {
            term.isEmpty || $0.title.localizedCaseInsensitiveContains(term)
        }
    }

    /// True only while the list has nothing to show yet and is being fetched,
    /// including the sign-in restore that comes before the first chat list.
    private var recentIsLoading: Bool {
        switch selectedProduct {
        case .ai:
            chatStore.conversations.isEmpty
                && (chatStore.isLoading || (session.isWorking && session.phase == .restoring))
        case .code:
            codeStore.isLoadingProjects && codeStore.projects.isEmpty
        case .brain:
            brainStore.isLoading && brainStore.documents.isEmpty
        }
    }

    /// Each read runs in its own task. Closing the drawer removes this view
    /// and cancels the pull, which must not cancel the read and report it
    /// as a failure.
    private func refreshRecent() async {
        isRefreshingRecent = true
        defer { isRefreshingRecent = false }
        switch selectedProduct {
        case .ai:
            guard !session.isWorking else { return }
            // A launch whose sign-in restore failed has no account to list yet.
            if session.identityID == nil {
                if session.phase == .restoring {
                    let sessionStore = session
                    await Task { await sessionStore.restore() }.value
                }
                return
            }
            let store = chatStore
            await Task {
                await store.loadConversations()
                await store.refreshSelectedConversation()
            }.value
        case .brain:
            let store = brainStore
            await Task { await store.loadLibrary() }.value
        case .code:
            // Projects are stored on this device. Only an empty library is
            // re-read, which retries a failed read; re-reading a listed one
            // could list an older copy of a project whose edit is still saving.
            guard codeStore.projects.isEmpty else { return }
            let store = codeStore
            await Task { await store.loadProjects() }.value
        }
    }

    private var sidebarAnimation: Animation? {
        guard preferences.motionEnabled, !reduceMotion else { return nil }
        return .snappy(duration: 0.28, extraBounce: 0)
    }

    private func selectProduct(_ product: ProductKind) {
        retireDeletion()
        selectedProduct = product
        dismissCompactSidebar()
    }

    /// Tapping the open chat shows it again and re-reads what was saved in it
    /// elsewhere: select(_:) would retire a send still being prepared before
    /// finding nothing to load. It still runs when this sidebar is opening
    /// another chat, so the tap wins over it.
    private func selectConversation(_ id: String) {
        retireDeletion()
        dismissCompactSidebar()
        if id == chatStore.selectedConversationID,
           requestedConversationID == nil || requestedConversationID == id {
            requestedConversationID = nil
            let store = chatStore
            Task { await store.refreshSelectedConversation() }
            return
        }
        requestedConversationID = id
        Task {
            await chatStore.select(id)
            // A choice that failed, was refused or was overtaken never opens;
            // it must not turn the next tap on the open chat into a select.
            if requestedConversationID == id { requestedConversationID = nil }
        }
    }

    private func openProject(_ project: CodeWorkspaceProject) {
        retireDeletion()
        codeStore.open(project)
        dismissCompactSidebar()
    }

    /// Chooses the source; a second tap from here never clears the choice.
    /// The Brain screen's own row and "All sources" undo it.
    private func chooseSource(_ source: BrainDocument) {
        retireDeletion()
        if !brainStore.selectedDocumentIDs.contains(source.id) {
            brainStore.toggleSelection(source.id)
        }
        dismissCompactSidebar()
    }

    private func createConversation() {
        retireDeletion()
        requestedConversationID = nil
        selectedProduct = .ai
        dismissCompactSidebar()
        Task {
            await chatStore.new()
        }
    }

    private func dismissCompactSidebar() {
        guard isCompact else {
            onShowDetail?()
            return
        }
        closeDrawer()
    }

    /// Account and Settings open a sheet, which presents over either split
    /// view column; showing the detail column in the same transaction would
    /// push and present at once. Only the drawer closes.
    private func closeDrawer() {
        guard isCompact else { return }
        withAnimation(sidebarAnimation) {
            compactSidebarPresented = false
        }
    }

    private func closeSidebar() {
        retireDeletion()
        dismissCompactSidebar()
    }

    private func requestDeletion(_ conversation: ChatSummary) {
        guard let request = chatStore.deletionRequest(id: conversation.id, title: conversation.title) else { return }
        pendingDeletion = SidebarChatDeletion(request: request, product: selectedProduct,
            navigationGeneration: deletionNavigationGeneration)
    }

    private func confirmDeletion(_ deletion: SidebarChatDeletion) {
        let request = deletion.request
        let language = preferences.language
        pendingDeletion = nil
        Task {
            guard deletionNavigationGeneration == deletion.navigationGeneration,
                  selectedProduct == deletion.product,
                  session.identityID == request.ownerID,
                  session.identityGeneration == request.identityGeneration,
                  !session.isWorking else { return }
            await chatStore.delete(request, language: language)
        }
    }

    private func retireDeletion() {
        pendingDeletion = nil
        deletionNavigationGeneration &+= 1
    }
}

private struct ProductSidebarRow: View {
    let product: ProductKind
    let isSelected: Bool

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        SidebarSelectionSurface(isSelected: isSelected) {
            HStack(spacing: 12) {
                Image(systemName: ShellStrings.productSystemImage(product))
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 30, height: 30)
                    .foregroundStyle(isSelected ? preferences.palette.accent : preferences.palette.textSecondary)
                    .background(
                        isSelected
                            ? preferences.palette.accent.opacity(0.12)
                            : preferences.palette.surfaceSunken.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .accessibilityHidden(true)

                Text(ShellStrings.productTitle(product))
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(preferences.palette.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// One Recent row: a chat, a Code project or a Brain source.
private struct RecentSidebarRow: View {
    let title: String
    let systemImage: String
    let accentsIcon: Bool
    let isSelected: Bool
    /// A chat whose transcript is still being read after it was chosen.
    var isOpening = false

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        SidebarSelectionSurface(isSelected: isSelected) {
            HStack(spacing: 11) {
                Group {
                    if isOpening {
                        ProgressView()
                            .controlSize(.small)
                            .tint(preferences.palette.textMuted)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(
                                accentsIcon ? preferences.palette.accent : preferences.palette.textMuted
                            )
                    }
                }
                .frame(width: 22)
                .accessibilityHidden(true)

                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(preferences.palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 6)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityValue(isOpening ? Text(ShellStrings.loading) : Text(verbatim: ""))
    }
}

private struct SidebarSelectionSurface<Content: View>: View {
    let isSelected: Bool
    let content: Content

    @Environment(PreferencesStore.self) private var preferences

    init(isSelected: Bool, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.content = content()
    }

    var body: some View {
        content
            .background(
                isSelected ? preferences.palette.accent.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
    }
}

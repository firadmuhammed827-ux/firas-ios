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
    var onCloseSidebar: (() -> Void)? = nil

    @Environment(PreferencesStore.self) private var preferences
    @Environment(SessionStore.self) private var session
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchQuery = ""
    @State private var pendingDeletion: SidebarChatDeletion?
    @State private var deletionNavigationGeneration = 0

    private let products: [ProductKind] = [.ai, .code, .brain]

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            searchField
            sidebarList
            accountFooter
        }
        .background(preferences.palette.sidebar)
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
        .onChange(of: selectedProduct) { _, _ in retireDeletion() }
        .onChange(of: chatStore.selectedConversationID) { _, _ in retireDeletion() }
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

                    if isCompact || onCloseSidebar != nil {
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
                prompt: Text(ShellStrings.searchChats)
            ) {
                Text(ShellStrings.searchChats)
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
        .environment(\.layoutDirection, preferences.language.layoutDirection)
    }

    private var sidebarList: some View {
        let conversations = filteredConversations
        return List {
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
                if conversations.isEmpty {
                    Text(ShellStrings.noChats)
                        .font(.subheadline)
                        .foregroundStyle(preferences.palette.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(conversations) { conversation in
                        Button {
                            selectConversation(conversation.id)
                        } label: {
                            ConversationSidebarRow(
                                conversation: conversation,
                                isSelected: chatStore.selectedConversationID == conversation.id
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
            } header: {
                Text(ShellStrings.recent)
                    .foregroundStyle(preferences.palette.textMuted)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 48)
        .environment(\.layoutDirection, preferences.language.layoutDirection)
    }

    private var accountFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(preferences.palette.border)

            HStack(spacing: 8) {
                Button {
                    retireDeletion()
                    presentedSheet = .authentication
                    dismissCompactSidebar()
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
                    dismissCompactSidebar()
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
        .background(preferences.palette.sidebar)
        .environment(\.layoutDirection, preferences.language.layoutDirection)
    }

    private var filteredConversations: [ChatSummary] {
        let productChats = chatStore.conversations.filter { conversation in
            guard !conversation.agent else { return false }
            return switch selectedProduct {
            case .ai: !conversation.agent && !conversation.codeProj && !conversation.brainNb
            case .code: conversation.codeProj
            case .brain: conversation.brainNb
            }
        }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return productChats }
        return productChats.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
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

    private func selectConversation(_ id: String) {
        retireDeletion()
        dismissCompactSidebar()
        Task {
            await chatStore.select(id)
        }
    }

    private func createConversation() {
        retireDeletion()
        selectedProduct = .ai
        dismissCompactSidebar()
        Task {
            await chatStore.new()
        }
    }

    private func dismissCompactSidebar() {
        guard isCompact else { return }
        withAnimation(sidebarAnimation) {
            compactSidebarPresented = false
        }
    }

    private func closeSidebar() {
        retireDeletion()
        if isCompact {
            dismissCompactSidebar()
        } else {
            onCloseSidebar?()
        }
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

private struct ConversationSidebarRow: View {
    let conversation: ChatSummary
    let isSelected: Bool

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        SidebarSelectionSurface(isSelected: isSelected) {
            HStack(spacing: 11) {
                Image(systemName: conversation.pinned ? "pin.fill" : "bubble.left")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(
                        conversation.pinned ? preferences.palette.accent : preferences.palette.textMuted
                    )
                    .accessibilityHidden(true)

                Text(conversation.title)
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

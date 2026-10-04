import SwiftUI

private enum ChatSheet: Identifiable, Equatable {
    case modelPicker
    case addContext
    case skills(ownerID: String?)
    case media(MediaStudioKind, focusedJobID: String?)
    case promptEngineer
    case difficulty(ChatDifficultyRequest<ChatDifficultyDraft>)

    var id: String {
        switch self {
        case .modelPicker: "model-picker"
        case .addContext: "add-context"
        case .skills(let ownerID): "skills-\(ownerID ?? "guest")"
        case .media(let kind, let jobID): "media-\(kind.rawValue)-\(jobID ?? "new")"
        case .promptEngineer: "prompt-engineer"
        case .difficulty(let request): "difficulty-\(request.id.uuidString)"
        }
    }
}

private enum ChatNotice {
    case voiceUnavailable
    case contextProcessing
    case contextPreparationFailed

    var message: LocalizedStringResource {
        switch self {
        case .voiceUnavailable: ChatStrings.voiceUnavailable
        case .contextProcessing: ChatStrings.contextProcessing
        case .contextPreparationFailed: ChatStrings.contextFileImportFailed
        }
    }

    var systemImage: String {
        switch self {
        case .voiceUnavailable: "mic.slash"
        case .contextProcessing: "hourglass"
        case .contextPreparationFailed: "exclamationmark.triangle"
        }
    }
}

private struct DirectMediaPreparation {
    let binding: MediaTurnBinding
    let preparationID: UUID
    let identityGeneration: Int
    let ownerGeneration: Int
}

struct ChatScreen: View {
    let showsSidebarButton: Bool
    let onOpenSidebar: () -> Void
    let onOpenProfile: () -> Void
    let onOpenBrain: () -> Void
    var onStartCall: (() -> Void)?
    let mediaPresentationRequest: MediaPresentationRequest?
    let onConsumeMediaPresentation: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(ChatStore.self) private var chatStore
    @Environment(SessionStore.self) private var session
    @Environment(MediaStudioStore.self) private var mediaStudioStore
    @Environment(PromptEngineerStore.self) private var promptEngineerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var presentedSheet: ChatSheet?
    @State private var notice: ChatNotice?
    @State private var isPreparingContext = false
    @State private var contextPreparationTask: Task<Void, Never>?
    @State private var contextPreparationID: UUID?
    @State private var directMediaPreparation: DirectMediaPreparation?
    @State private var skillSelection = ChatSkillSelection()
    @State private var scrollFollow = ChatScrollFollowState()
    @State private var helperObservationLease: UUID?
    @FocusState private var isComposerFocused: Bool

    init(
        showsSidebarButton: Bool,
        onOpenSidebar: @escaping () -> Void,
        onOpenProfile: @escaping () -> Void,
        onOpenBrain: @escaping () -> Void,
        onStartCall: (() -> Void)? = nil,
        mediaPresentationRequest: MediaPresentationRequest? = nil,
        onConsumeMediaPresentation: @escaping () -> Void = {}
    ) {
        self.showsSidebarButton = showsSidebarButton
        self.onOpenSidebar = onOpenSidebar
        self.onOpenProfile = onOpenProfile
        self.onOpenBrain = onOpenBrain
        self.onStartCall = onStartCall
        self.mediaPresentationRequest = mediaPresentationRequest
        self.onConsumeMediaPresentation = onConsumeMediaPresentation
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()
                conversation
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                chatToolbar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if let notice {
                        ChatNoticeBanner(notice: notice) {
                            self.notice = nil
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if promptEngineerStore.hasResult {
                        PromptEngineerStatusControl { presentedSheet = .promptEngineer }
                    }
                    if chatStore.canForgetUnavailableReceipt, let cid = chatStore.unavailableReceiptCID,
                       let ownerID = session.identityID {
                        let identityGeneration = session.identityGeneration
                        VStack(spacing: 6) {
                            Text(LocalizedStringResource("receiptLocalRemovalHint", table: "Chat"))
                                .font(.caption).foregroundStyle(.secondary)
                            FirasGlassControlGroup(spacing: 8) {
                                Button {
                                    Task {
                                        guard session.identityID == ownerID, session.identityGeneration == identityGeneration,
                                              chatStore.unavailableReceiptCID == cid else { return }
                                        await chatStore.resumeActiveJob()
                                    }
                                } label: {
                                    Text(LocalizedStringResource("receiptReconnect", table: "Chat")).frame(minHeight: 44)
                                }.modifier(FirasGlassControlStyle())
                                Button {
                                    chatStore.forgetUnavailableReceipt(cid: cid, expectedOwnerID: ownerID,
                                        expectedIdentityGeneration: identityGeneration)
                                } label: {
                                    Text(LocalizedStringResource("receiptRemoveLocal", table: "Chat")).frame(minHeight: 44)
                                }.modifier(FirasGlassControlStyle())
                            }
                        }
                    }

                    ChatComposer(
                        draft: draftBinding,
                        isFocused: $isComposerFocused,
                        isSending: chatStore.isSending || isPreparingContext,
                        isPreparing: isPreparingContext,
                        selectedTier: preferences.tier,
                        contextCount: draftContext.itemCount,
                        hasReadyContext: draftContext.hasReadyContent,
                        selectedSkills: visibleSelectedSkills,
                        promptEngineerRecognized: chatStore.promptEngineerCommandMatches,
                        promptEngineerReady: chatStore.promptEngineerSourceReady && !chatStore.isSending && !isPreparingContext && !promptEngineerStore.blocksNewHelper,
                        promptEngineerBusy: promptEngineerStore.blocksOrdinarySend,
                        onPromptEngineerLanguage: startPromptEngineer,
                        onRemoveSkill: removeSkill,
                        onAddContext: showAddContext,
                        onDraftChanged: dismissNotice,
                        onSelectModel: showModelPicker,
                        onSend: send,
                        onStop: stop,
                        onStartCall: startCallTapped
                    )
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .environment(\.layoutDirection, preferences.language.layoutDirection)
            }
            .overlay(alignment: .top) {
                if let errorMessage = chatStore.errorMessage, !errorMessage.isEmpty {
                    ChatErrorBanner(message: errorMessage) {
                        chatStore.errorMessage = nil
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .environment(\.layoutDirection, preferences.language.layoutDirection)
                }
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .modelPicker:
                ModelSelectionSheet(initialDraft: draft)
            case .addContext:
                AddContextSheet(
                    selection: draftContextBinding,
                    onOpenBrain: onOpenBrain,
                    onOpenSkills: openSkillsFromContext,
                    onOpenMedia: openMediaStudio
                )
            case .skills(let ownerID):
                ChatSkillsPicker(ownerID: ownerID, selection: $skillSelection)
            case .media(let kind, let focusedJobID):
                MediaStudioScreen(
                    store: mediaStudioStore,
                    initialKind: kind,
                    focusedJobID: focusedJobID,
                    onOpenProfile: openProfileFromMediaStudio
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(34)
            case .promptEngineer:
                PromptEngineerPanel()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(34)
            case .difficulty(let request):
                DifficultySelectionSheet(request: request,
                    onChoose: { chooseDifficulty(request, level: $0) },
                    onSkip: { chooseDifficulty(request, level: request.decision.calibration.level) },
                    onCancel: { cancelDifficulty(request) })
            }
        }
        .onChange(of: mediaPresentationRequest, initial: true) { _, request in
            guard let request else { return }
            isComposerFocused = false
            presentedSheet = .media(request.kind, focusedJobID: request.focusedJobID)
            onConsumeMediaPresentation()
        }
        .onChange(of: session.identityID, initial: true) { previous, current in
            chatStore.synchronizeDraftOwner()
            skillSelection.bind(ownerID: session.isAuthenticated ? current : nil)
            if previous != current {
                contextPreparationTask?.cancel()
                contextPreparationTask = nil
                contextPreparationID = nil
                isPreparingContext = false
                presentedSheet = nil
                notice = nil
            }
        }
        .onChange(of: session.identityGeneration) { _, _ in
            chatStore.synchronizeDraftOwner()
            retirePreparation()
            dismissDifficultyChoice()
        }
        .onChange(of: chatStore.selectedConversationID) { _, _ in dismissDifficultyChoice() }
        .onChange(of: chatStore.composerDraft.snapshot()) { _, current in
            if case .difficulty(let request)? = presentedSheet, current != request.scope.draft {
                cancelDifficulty(request)
            }
        }
        .onChange(of: presentedSheet) { previous, current in
            if case .difficulty(let request)? = previous, previous != current {
                chatStore.cancelDifficulty(requestID: request.id)
            }
            if let current, case .difficulty(_) = current { return }
            if current != nil { chatStore.retireDifficultySelection() }
        }
        .onAppear {
            if helperObservationLease == nil { helperObservationLease = promptEngineerStore.acquireObservation() }
        }
        .onChange(of: promptEngineerStore.presentationID, initial: true) { _, id in
            guard let id else { return }
            presentedSheet = .promptEngineer
            promptEngineerStore.consumePresentation(id)
        }
        .onChange(of: chatStore.lastAcceptedSend) { _, receipt in
            guard let receipt, receipt.ownerID == session.identityID else { return }
            skillSelection.accept(receipt)
        }
        .onDisappear {
            if let helperObservationLease { promptEngineerStore.releaseObservation(helperObservationLease) }
            helperObservationLease = nil
            // Editable input belongs to the store. Leaving a surface retires
            // only its preparation/consumption, never an accepted cloud job.
            retirePreparation()
            chatStore.retireDraftSubmission(expectedOwnerID: session.identityID,
                expectedIdentityGeneration: session.identityGeneration)
        }
    }

    private var draft: String { chatStore.draftText }
    private var draftContext: DraftContextSelection { chatStore.draftContext }

    private var draftBinding: Binding<String> {
        let ownerID = session.identityID
        let generation = session.identityGeneration
        return Binding(get: {
            guard session.identityID == ownerID, session.identityGeneration == generation else { return "" }
            return chatStore.draftText
        }, set: {
            chatStore.updateDraftText($0, expectedOwnerID: ownerID, expectedIdentityGeneration: generation)
        })
    }

    private var draftContextBinding: Binding<DraftContextSelection> {
        let ownerID = session.identityID
        let generation = session.identityGeneration
        return Binding(get: {
            guard session.identityID == ownerID, session.identityGeneration == generation else { return DraftContextSelection() }
            return chatStore.draftContext
        }, set: {
            chatStore.updateDraftContext($0, expectedOwnerID: ownerID, expectedIdentityGeneration: generation)
        })
    }

    private func retirePreparation() {
        contextPreparationTask?.cancel()
        contextPreparationTask = nil
        contextPreparationID = nil
        isPreparingContext = false
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if chatStore.messages.isEmpty {
                    ChatWelcomeView()
                        .containerRelativeFrame(.vertical, alignment: .center)
                } else {
                    LazyVStack(spacing: 24) {
                        ForEach(chatStore.messages) { message in
                            ChatMessageRow(message: message)
                                .id(message.id)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(ChatScrollAnchor.bottom)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: preferences.contentWidth.maxWidth)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: ChatScrollGeometryProjection.self) { geometry in
                ChatScrollGeometryProjection(
                    contentHeight: geometry.contentSize.height,
                    viewportHeight: geometry.containerSize.height,
                    nearBottom: geometry.contentSize.height - geometry.visibleRect.maxY < 120
                )
            } action: { previous, current in
                // Content growth from streaming must not be mistaken for a
                // user choosing to read an earlier part of the conversation.
                var nextFollow = scrollFollow
                let shouldScroll = nextFollow.geometryChanged(from: previous, to: current)
                if nextFollow != scrollFollow { scrollFollow = nextFollow }
                if shouldScroll {
                    scrollToLatest(proxy, animated: false)
                }
            }
            .onScrollPhaseChange { _, phase, context in
                var nextFollow = scrollFollow
                switch phase {
                case .tracking, .interacting, .decelerating:
                    nextFollow.updateInteraction(.user, nearBottom: context.geometry.contentSize.height
                        - context.geometry.visibleRect.maxY < 120)
                case .idle:
                    nextFollow.updateInteraction(.idle, nearBottom: context.geometry.contentSize.height
                        - context.geometry.visibleRect.maxY < 120)
                case .animating:
                    nextFollow.updateInteraction(.programmatic, nearBottom: context.geometry.contentSize.height
                        - context.geometry.visibleRect.maxY < 120)
                @unknown default:
                    break
                }
                if nextFollow != scrollFollow { scrollFollow = nextFollow }
            }
            .overlay(alignment: .bottomTrailing) {
                if !scrollFollow.followsLatestMessage, !chatStore.messages.isEmpty {
                    Button {
                        scrollFollow.resumeFollowingLatest()
                        scrollToLatest(proxy, animated: true)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(preferences.palette.textPrimary)
                    .background(.regularMaterial, in: Circle())
                    .accessibilityLabel(Text("chat.latestMessage"))
                    .padding(16)
                }
            }
            .onChange(of: scrollTrigger, initial: true) { previous, current in
                var nextFollow = scrollFollow
                let shouldScroll = nextFollow.transcriptChanged(from: previous, to: current)
                if nextFollow != scrollFollow { scrollFollow = nextFollow }
                guard shouldScroll else { return }
                // Follow accepted row changes immediately; actual stream growth
                // follows geometry. Animate only intentional jumps.
                scrollToLatest(proxy, animated: false)
            }
        }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        if showsSidebarButton {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: openSidebar) {
                    Image(systemName: "line.3.horizontal")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text(ShellStrings.openSidebar))
            }
        }

        if !chatStore.messages.isEmpty {
            ToolbarItem(placement: .principal) {
                ChatNavigationTitle(title: chatStore.selectedConversation?.title)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button(action: openProfile) {
                Image(systemName: "person.crop.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text(ShellStrings.account))
        }
    }

    private var scrollTrigger: ChatTranscriptProjection {
        ChatTranscriptProjection(
            conversationID: chatStore.selectedConversationID,
            messageCount: chatStore.messages.count,
            lastMessageID: chatStore.messages.last?.id
        )
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated, !reduceMotion, preferences.motionEnabled {
            withAnimation(.smooth(duration: 0.24)) {
                proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
        }
    }

    private func showModelPicker() {
        notice = nil
        isComposerFocused = false
        presentedSheet = .modelPicker
    }

    private func showAddContext() {
        notice = nil
        isComposerFocused = false
        presentedSheet = .addContext
    }

    private var visibleSelectedSkills: [AccountSkill] {
        guard session.isAuthenticated, skillSelection.ownerID == session.identityID else { return [] }
        return skillSelection.skills
    }

    private func showSkillsPicker() {
        guard !chatStore.isSending, !isPreparingContext else { return }
        let ownerID = session.isAuthenticated ? session.identityID : nil
        skillSelection.bind(ownerID: ownerID)
        isComposerFocused = false
        notice = nil
        presentedSheet = .skills(ownerID: ownerID)
    }

    private func openSkillsFromContext() {
        let ownerID = session.identityID
        presentedSheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, session.identityID == ownerID, presentedSheet == nil else { return }
            showSkillsPicker()
        }
    }

    private func removeSkill(_ id: String) {
        guard !chatStore.isSending, !isPreparingContext, let ownerID = session.identityID else { return }
        skillSelection.remove(id: id, expectedOwnerID: ownerID)
    }

    private func openMediaStudio(_ kind: MediaStudioKind) {
        presentedSheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            guard presentedSheet == nil else { return }
            presentedSheet = .media(kind, focusedJobID: nil)
        }
    }

    private func openProfileFromMediaStudio() {
        presentedSheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            onOpenProfile()
        }
    }

    private func openSidebar() {
        isComposerFocused = false
        dismissDifficultyChoice()
        chatStore.retireDifficultySelection()
        onOpenSidebar()
    }

    private func openProfile() {
        isComposerFocused = false
        dismissDifficultyChoice()
        chatStore.retireDifficultySelection()
        onOpenProfile()
    }

    private func send() {
        guard !chatStore.isSending, !isPreparingContext, !promptEngineerStore.blocksOrdinarySend,
              !chatStore.promptEngineerCommandMatches else { return }
        guard let snapshot = chatStore.snapshotDraft() else { return }
        let message = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || snapshot.context.hasReadyContent else { return }
        guard !draftContext.isProcessing else {
            withAnimation(noticeAnimation) {
                notice = .contextProcessing
            }
            return
        }
        guard presentedSheet == nil,
              let admission = chatStore.difficultyAdmission(for: snapshot, language: preferences.language) else { return }
        switch admission {
        case .choose(let request):
            isComposerFocused = false
            presentedSheet = .difficulty(request)
        case .ready(let submission):
            send(snapshot: snapshot, difficultySubmission: submission)
        }
    }

    private func chooseDifficulty(_ request: ChatDifficultyRequest<ChatDifficultyDraft>, level: Int) {
        guard presentedSheet == .difficulty(request) else { return }
        let submission = chatStore.chooseDifficulty(request, level: level)
        presentedSheet = nil
        guard let submission else { return }
        send(snapshot: request.scope.draft, difficultySubmission: submission)
    }

    private func cancelDifficulty(_ request: ChatDifficultyRequest<ChatDifficultyDraft>) {
        chatStore.cancelDifficulty(requestID: request.id)
        if presentedSheet == .difficulty(request) { presentedSheet = nil }
    }

    private func dismissDifficultyChoice() {
        if case .difficulty(let request)? = presentedSheet { cancelDifficulty(request) }
    }

    private func send(snapshot: ChatDifficultyDraft,
                      difficultySubmission: ChatDifficultySubmission<ChatDifficultyDraft>) {
        guard !chatStore.isSending, !isPreparingContext,
              !promptEngineerStore.blocksOrdinarySend, !chatStore.promptEngineerCommandMatches,
              chatStore.isDifficultySubmissionCurrent(difficultySubmission) else { return }
        let message = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        isPreparingContext = true
        let preparationID = UUID()
        contextPreparationID = preparationID
        scrollFollow.resumeFollowingLatest()
        let images = snapshot.context.images
        let files = snapshot.context.files
        guard let ownerID = session.identityID else {
            isPreparingContext = false
            contextPreparationID = nil
            return
        }
        let conversationID = chatStore.selectedConversationID
        let identityGeneration = session.identityGeneration
        let tier = preferences.tier
        let modelGeneration = preferences.modelGeneration
        let thinking = preferences.thinkingEnabled
        let webSearch = preferences.webSearchEnabled
        let language = preferences.language
        let sharpenImages = preferences.sharpenImages
        let selectedSkillIDs = visibleSelectedSkills.map(\.id)
        let hasPriorImage = chatStore.messages.contains {
            $0.images?.isEmpty == false || $0.imageThumbs?.isEmpty == false
        }
        contextPreparationTask = Task {
            defer {
                if contextPreparationID == preparationID {
                    isPreparingContext = false
                    contextPreparationTask = nil
                    contextPreparationID = nil
                }
            }
            let context: PreparedChatContext?
            if images.isEmpty && files.isEmpty {
                context = nil
            } else {
                do {
                    context = try await ChatAttachmentProcessor.prepare(
                        images: images,
                        files: files,
                        sharpenImages: sharpenImages
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard contextPreparationID == preparationID, session.identityID == ownerID else { return }
                    withAnimation(noticeAnimation) {
                        notice = .contextPreparationFailed
                    }
                    return
                }
            }

            guard !Task.isCancelled, contextPreparationID == preparationID, session.identityID == ownerID,
                  session.identityGeneration == identityGeneration,
                  chatStore.selectedConversationID == conversationID,
                  chatStore.isDifficultySubmissionCurrent(difficultySubmission) else { return }
            guard !message.isEmpty || (context?.isEmpty == false) else {
                withAnimation(noticeAnimation) {
                    notice = .contextPreparationFailed
                }
                return
            }

            let intent: IntentDecision
            if message.utf16.count <= 60_000 {
                intent = await chatStore.classifyDraft(text: message, context: context, expectedOwnerID: ownerID)
            } else {
                intent = .unavailable
            }
            guard !Task.isCancelled, contextPreparationID == preparationID,
                  session.identityID == ownerID, session.identityGeneration == identityGeneration,
                  chatStore.selectedConversationID == conversationID,
                  !chatStore.isSending,
                  chatStore.isDifficultySubmissionCurrent(difficultySubmission) else { return }
            if let mediaKind = intent.nativeMediaKind(
                hasAttachedImage: context?.fullImages.isEmpty == false,
                hasPriorImage: hasPriorImage,
                hasFileContext: context?.files.isEmpty == false
            ) {
                await routeDirectMediaRequest(mediaKind, message: message, tier: tier,
                    modelGeneration: modelGeneration, language: language, ownerID: ownerID,
                    identityGeneration: identityGeneration, preparationID: preparationID, snapshot: snapshot)
                return
            }

            let cid = await chatStore.send(
                text: message,
                tier: tier,
                modelGeneration: modelGeneration,
                thinking: thinking,
                webSearch: webSearch,
                language: language,
                context: context,
                skillIDs: selectedSkillIDs,
                expectedOwnerID: ownerID,
                prefetchedIntent: intent,
                difficultySubmission: difficultySubmission
            )
            guard let cid, session.identityID == ownerID, session.identityGeneration == identityGeneration,
                  !Task.isCancelled, contextPreparationID == preparationID else { return }
            chatStore.beginDraftSubmission(cid: cid, snapshot: snapshot)
            notice = nil
            skillSelection.beginSubmission(cid: cid, ids: selectedSkillIDs, expectedOwnerID: ownerID)
            // A very fast terminal response may be published before this view
            // observes the cid; reconcile it without depending on callback order.
            if let receipt = chatStore.lastAcceptedSend { skillSelection.accept(receipt) }
        }
    }

    private func routeDirectMediaRequest(
        _ intent: NativeChatMediaKind, message: String, tier: ModelTier,
        modelGeneration: ModelGeneration, language: AppLanguage, ownerID: String,
        identityGeneration: Int, preparationID: UUID, snapshot: ChatDraftSnapshot<DraftContextSelection>
    ) async {
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMessage.isEmpty, !Task.isCancelled, contextPreparationID == preparationID,
              session.identityID == ownerID, session.identityGeneration == identityGeneration,
              chatStore.snapshotDraft() == snapshot else { return }
        let mediaKind: MediaStudioKind
        let seconds: Int?
        switch intent {
        case .image: mediaKind = .image; seconds = nil
        case .video:
            mediaKind = .video
            seconds = detectMediaSeconds(from: message, defaultSeconds: 10, maximum: 30, minimum: 2)
        case .music:
            mediaKind = .music
            seconds = detectMediaSeconds(from: message, defaultSeconds: 90, maximum: 600, minimum: 10)
        }
        guard MediaRequestPolicy.validationProblem(kind: mediaKind, prompt: message, seconds: seconds) == nil else {
            let limit = MediaRequestPolicy.promptLimit(mediaKind)
            chatStore.errorMessage = language == .arabic
                ? "الطلب أطول من حد إنشاء الوسائط (\(limit) حرف). عدّله ثم أرسله؛ نصك يبقى عندك."
                : "The media brief exceeds \(limit) characters. Edit it and send again; your text is still here."
            return
        }
        mediaStudioStore.synchronizeOwner()
        guard mediaStudioStore.canCreate, chatStore.snapshotDraft() == snapshot else { return }
        let mediaGeneration = mediaStudioStore.ownerGeneration
        guard let binding = await chatStore.prepareMediaTurn(
            prompt: message, tier: tier, modelGeneration: modelGeneration, language: language,
            expectedOwnerID: ownerID, expectedIdentityGeneration: identityGeneration
        ), !Task.isCancelled, contextPreparationID == preparationID,
              session.identityID == ownerID, session.identityGeneration == identityGeneration,
              mediaStudioStore.ownerGeneration == mediaGeneration,
              chatStore.snapshotDraft() == snapshot else { return }

        directMediaPreparation = DirectMediaPreparation(binding: binding, preparationID: preparationID,
            identityGeneration: identityGeneration, ownerGeneration: mediaGeneration)
        defer {
            if directMediaPreparation?.preparationID == preparationID { directMediaPreparation = nil }
        }

        let accepted: Bool
        switch intent {
        case .image:
            accepted = await mediaStudioStore.createImage(prompt: message, preset: resolveImageAspect(from: message.lowercased()),
                language: language, binding: binding, tier: tier,
                expectedOwnerID: ownerID, expectedOwnerGeneration: mediaGeneration, expectedIdentityGeneration: identityGeneration)
        case .video:
            accepted = await mediaStudioStore.createVideo(prompt: message,
                seconds: seconds ?? 10,
                language: language, binding: binding, tier: tier,
                expectedOwnerID: ownerID, expectedOwnerGeneration: mediaGeneration, expectedIdentityGeneration: identityGeneration)
        case .music:
            accepted = await mediaStudioStore.createMusic(
                prompt: message,
                // Song instructions are not lyrics. Studio supplies explicit
                // lyrics separately; direct requests use the brief alone.
                lyrics: "",
                seconds: seconds ?? 90,
                language: language, binding: binding, tier: tier,
                expectedOwnerID: ownerID, expectedOwnerGeneration: mediaGeneration, expectedIdentityGeneration: identityGeneration
            )
        }
        guard accepted, !Task.isCancelled, contextPreparationID == preparationID,
              session.identityID == ownerID, session.identityGeneration == identityGeneration else { return }
        chatStore.consumeAcceptedMediaDraft(binding: binding, snapshot: snapshot)
        notice = nil

        switch intent {
        case .image:
            presentedSheet = .media(.image, focusedJobID: nil)
        case .video:
            presentedSheet = .media(.video, focusedJobID: nil)
        case .music:
            presentedSheet = .media(.music, focusedJobID: nil)
        }
    }

    private func detectMediaSeconds(
        from text: String,
        defaultSeconds: Int,
        maximum: Int,
        minimum: Int
    ) -> Int {
        guard let match = text.range(of: #"(\d+)"#, options: .regularExpression) else {
            return defaultSeconds
        }
        let numberText = String(text[match]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(numberText) else { return defaultSeconds }
        return min(maximum, max(minimum, value))
    }

    private func resolveImageAspect(from text: String) -> ImageAspectPreset {
        if text.contains("عمودي") || text.contains("portrait") {
            return .portrait
        }
        if text.contains("بورتريه") || text.contains("poster") {
            return .portrait
        }
        if text.contains("أفقي") || text.contains("wide") || text.contains("landscape") {
            return .landscape
        }
        if text.contains("story") || text.contains("قصة") {
            return .story
        }
        if text.contains("cover") || text.contains("غلاف") {
            return .cover
        }
        return .square
    }

    private func stop() {
        if promptEngineerStore.blocksOrdinarySend, let saved = promptEngineerStore.pointer,
           let ownerID = promptEngineerStore.ownerID {
            promptEngineerStore.stop(cid: saved.cid, expectedOwnerID: ownerID,
                expectedIdentityGeneration: promptEngineerStore.identityGeneration)
            return
        }
        notice = nil
        chatStore.retireDraftSubmission(expectedOwnerID: session.identityID,
            expectedIdentityGeneration: session.identityGeneration)
        if let direct = directMediaPreparation,
           direct.preparationID == contextPreparationID,
           direct.binding.ownerID == session.identityID,
           direct.identityGeneration == session.identityGeneration,
           direct.ownerGeneration == mediaStudioStore.ownerGeneration,
           let creation = mediaStudioStore.creations.first(where: {
               $0.ownerID == direct.binding.ownerID && $0.cid == direct.binding.cid
           }) {
            mediaStudioStore.stop(creation, language: preferences.language)
        }
        let stopRequest = chatStore.stopRequest()
        contextPreparationTask?.cancel()
        if let stopRequest {
            Task { await chatStore.stop(stopRequest) }
        }
    }

    private func startCallTapped() {
        if let onStartCall {
            onStartCall()
        } else {
            withAnimation(noticeAnimation) {
                notice = .voiceUnavailable
            }
        }
    }

    private func startPromptEngineer(_ languageCode: String) {
        guard !chatStore.isSending, !isPreparingContext, let snapshot = chatStore.snapshotDraft() else { return }
        if promptEngineerStore.start(snapshot: snapshot, languageCode: languageCode) {
            isComposerFocused = false
            presentedSheet = .promptEngineer
        }
    }

    private func dismissNotice() {
        guard notice != nil else { return }
        withAnimation(noticeAnimation) {
            notice = nil
        }
    }

    private var noticeAnimation: Animation? {
        guard preferences.motionEnabled, !reduceMotion else { return nil }
        return .smooth(duration: 0.22)
    }
}

private enum ChatScrollAnchor {
    static let bottom = "chat-bottom-anchor"
}

private struct ChatNavigationTitle: View {
    let title: String?

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        if let title, !title.isEmpty {
            Text(title)
                .font(.headline)
                .foregroundStyle(preferences.palette.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: 260)
        } else {
            Text(ShellStrings.productTitle(.ai))
                .font(.headline)
                .foregroundStyle(preferences.palette.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: 260)
        }
    }
}

private struct ChatWelcomeView: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        VStack(spacing: 20) {
            FirasBrandMark(size: 54)

            Text("chat.empty.title")
                .font(.title2.weight(.semibold))
                .foregroundStyle(preferences.palette.textPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 28)
        .padding(.vertical, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ChatNoticeBanner: View {
    let notice: ChatNotice
    let dismiss: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 15, tintStrength: 0.05) {
            HStack(spacing: 10) {
                Image(systemName: notice.systemImage)
                    .foregroundStyle(preferences.palette.textSecondary)
                    .accessibilityHidden(true)

                Text(notice.message)
                    .font(.subheadline)
                    .foregroundStyle(preferences.palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(preferences.palette.textMuted)
                .accessibilityLabel(Text(ChatStrings.dismissNotice))
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(maxWidth: 720, minHeight: 48)
        }
    }
}

private struct ChatErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(preferences.palette.error)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(preferences.palette.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(ChatStrings.dismissNotice))
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .background(preferences.palette.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(preferences.palette.error.opacity(0.38), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .frame(maxWidth: 720, minHeight: 50)
        .accessibilityElement(children: .contain)
    }
}

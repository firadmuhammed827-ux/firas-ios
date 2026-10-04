import AVFoundation
import Observation
@preconcurrency import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum RecentPhotoAccessState {
    case loading
    case available
    case denied
    case configurationMissing
}

private enum DictationLanguage: String, CaseIterable, Identifiable {
    case automatic
    case arabic
    case english

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .automatic: ChatStrings.contextDictationAutomatic
        case .arabic: ChatStrings.contextDictationArabic
        case .english: ChatStrings.contextDictationEnglish
        }
    }
}

struct AddContextSheet: View {
    @Binding var selection: DraftContextSelection
    let onOpenBrain: () -> Void
    let onOpenSkills: () -> Void
    let onOpenMedia: (MediaStudioKind) -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("dictationLanguage") private var dictationLanguageRaw = DictationLanguage.automatic.rawValue
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var recentAssets: [PHAsset] = []
    @State private var recentPhotoAccess: RecentPhotoAccessState = .loading
    @State private var showsFileImporter = false
    @State private var showsCamera = false
    @State private var notice: LocalizedStringResource?
    @State private var contentVisible = false
    @State private var pickerImportGeneration = UUID()

    var body: some View {
        @Bindable var preferences = preferences

        NavigationStack {
            ZStack {
                FirasBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ContextSectionHeading(title: ChatStrings.contextPhotos)
                        photoStrip

                        ContextSectionHeading(title: ChatStrings.contextFiles)
                        filesSection

                        ContextSectionHeading(title: MediaStrings.title)
                        mediaCreationSection

                        ContextSectionHeading(title: ChatStrings.contextTools)
                        GlassSurface(cornerRadius: 22, tintStrength: 0.035) {
                            VStack(spacing: 0) {
                                Button {
                                    dismiss()
                                    onOpenSkills()
                                } label: {
                                    HStack(spacing: 13) {
                                        ContextIcon(systemImage: "text.badge.star")
                                        ContextTextColumn(title: ChatStrings.selectSkills, detail: ChatStrings.skillsContextDetail)
                                        Spacer(minLength: 10)
                                        Image(systemName: "chevron.forward")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(preferences.palette.textMuted)
                                            .accessibilityHidden(true)
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 58)
                                }
                                .buttonStyle(.plain)

                                ContextDivider()

                                Button {
                                    dismiss()
                                    onOpenBrain()
                                } label: {
                                    HStack(spacing: 13) {
                                        ContextIcon(systemImage: "brain.head.profile")
                                        ContextTextColumn(
                                            title: ChatStrings.contextBrain,
                                            detail: ChatStrings.contextBrainDetail
                                        )
                                        Spacer(minLength: 10)
                                        Image(systemName: "chevron.forward")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(preferences.palette.textMuted)
                                            .accessibilityHidden(true)
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 58)
                                }
                                .buttonStyle(.plain)

                                ContextDivider()

                                Toggle(isOn: $preferences.webSearchEnabled) {
                                    ContextControlLabel(
                                        title: ChatStrings.contextWebSearch,
                                        detail: ChatStrings.contextWebSearchDetail,
                                        systemImage: "globe"
                                    )
                                }
                                .tint(preferences.palette.accent)
                                .frame(minHeight: 58)
                                .padding(.horizontal, 14)

                                ContextDivider()

                                Toggle(isOn: $preferences.thinkingEnabled) {
                                    ContextControlLabel(
                                        title: ChatStrings.contextThinking,
                                        detail: ChatStrings.contextThinkingDetail,
                                        systemImage: "lightbulb.max"
                                    )
                                }
                                .tint(preferences.palette.accent)
                                .frame(minHeight: 58)
                                .padding(.horizontal, 14)

                                ContextDivider()

                                dictationLanguageRow
                            }
                        }

                        if !selection.isEmpty {
                            ContextSelectionNotice(
                                count: selection.itemCount,
                                isProcessing: selection.isProcessing
                            )
                        }

                        if let notice {
                            ContextInlineNotice(message: notice)
                        }
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 34)
                    .frame(maxWidth: .infinity)
                    .opacity(contentVisible ? 1 : 0)
                    .offset(y: contentVisible ? 0 : 24)
                    .scaleEffect(contentVisible ? 1 : 0.978, anchor: .top)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(Text(ChatStrings.contextTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !selection.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            selection.clear()
                            photoPickerItems.removeAll()
                        } label: {
                            Text(ChatStrings.contextClear)
                                .frame(minHeight: 44)
                        }
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("common.done")
                            .frame(minHeight: 44)
                    }
                }
            }
        }
        .tint(preferences.palette.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
        .presentationBackground(preferences.palette.background)
        .presentationContentInteraction(.scrolls)
        .environment(\.layoutDirection, .leftToRight)
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleImportedFiles
        )
        .fullScreenCover(isPresented: $showsCamera) {
            CameraCaptureView(isPresented: $showsCamera) { image in
                importCameraImage(image)
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoPickerItems) { _, items in
            importPickerItems(items)
        }
        .task {
            await loadRecentPhotos()
        }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            if reduceMotion || !preferences.motionEnabled {
                contentVisible = true
            } else {
                withAnimation(.snappy(duration: 0.44, extraBounce: 0.035)) {
                    contentVisible = true
                }
            }
        }
    }

    private var photoStrip: some View {
        let allPhotosTitle = ChatStrings.contextAllPhotos

        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                Button(action: requestCamera) {
                    ContextPhotoActionTile(
                        title: ChatStrings.contextCamera,
                        systemImage: "camera"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(ChatStrings.contextCamera))

                switch recentPhotoAccess {
                case .loading:
                    ForEach(0 ..< 3, id: \.self) { _ in
                        ContextPhotoPlaceholder()
                    }
                case .available:
                    if recentAssets.isEmpty {
                        ContextPhotoStatusTile(
                            title: ChatStrings.contextNoRecentPhotos,
                            systemImage: "photo"
                        )
                    } else {
                        ForEach(Array(recentAssets.enumerated()), id: \.element.localIdentifier) { index, asset in
                            RecentPhotoTile(
                                asset: asset,
                                index: index,
                                isSelected: selection.recentPhotoIDs.contains(asset.localIdentifier)
                            ) {
                                toggleRecentPhoto(asset)
                            }
                        }
                    }
                case .denied:
                    Button(action: openPhotoSettings) {
                        ContextPhotoStatusTile(
                            title: ChatStrings.contextPhotoAccessDenied,
                            systemImage: "lock"
                        )
                    }
                    .buttonStyle(.plain)
                case .configurationMissing:
                    ContextPhotoStatusTile(
                        title: ChatStrings.contextPhotoSetupRequired,
                        systemImage: "exclamationmark.triangle"
                    )
                }

                PhotosPicker(
                    selection: $photoPickerItems,
                    maxSelectionCount: 10,
                    matching: .images
                ) {
                    ContextPhotoActionTile(
                        title: allPhotosTitle,
                        systemImage: "photo.on.rectangle.angled"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(allPhotosTitle))
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .environment(\.layoutDirection, .leftToRight)
    }

    private var filesSection: some View {
        Button {
            notice = nil
            showsFileImporter = true
        } label: {
            GlassSurface(cornerRadius: 22, tintStrength: 0.035) {
                HStack(spacing: 13) {
                    ContextIcon(systemImage: "folder")

                    ContextTextColumn(
                        title: ChatStrings.contextFiles,
                        detail: ChatStrings.contextFilesDetail
                    )

                    Spacer(minLength: 10)

                    if !selection.fileNames.isEmpty {
                        ContextCountBadge(count: selection.fileNames.count)
                    }

                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(preferences.palette.textMuted)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 64)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(ChatStrings.contextFiles))
        .accessibilityValue(Text(verbatim: "\(selection.fileNames.count)"))
    }

    private var mediaCreationSection: some View {
        GlassSurface(cornerRadius: 22, tintStrength: 0.045) {
            VStack(spacing: 0) {
                mediaCreationRow(
                    kind: .image,
                    title: MediaStrings.image,
                    detail: MediaStrings.imagePrompt,
                    systemImage: "photo.artframe"
                )
                ContextDivider()
                mediaCreationRow(
                    kind: .video,
                    title: MediaStrings.video,
                    detail: MediaStrings.videoPrompt,
                    systemImage: "video"
                )
                ContextDivider()
                mediaCreationRow(
                    kind: .music,
                    title: MediaStrings.music,
                    detail: MediaStrings.musicPrompt,
                    systemImage: "waveform"
                )
            }
        }
    }

    private func mediaCreationRow(
        kind: MediaStudioKind,
        title: LocalizedStringResource,
        detail: LocalizedStringResource,
        systemImage: String
    ) -> some View {
        Button {
            dismiss()
            onOpenMedia(kind)
        } label: {
            HStack(spacing: 13) {
                ContextIcon(systemImage: systemImage)
                ContextTextColumn(title: title, detail: detail)
                Spacer(minLength: 10)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(preferences.palette.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private var dictationLanguageRow: some View {
        HStack(spacing: 13) {
            ContextControlLabel(
                title: ChatStrings.contextDictationLanguage,
                detail: ChatStrings.contextDictationDetail,
                systemImage: "waveform"
            )

            Spacer(minLength: 10)

            Menu {
                ForEach(DictationLanguage.allCases) { language in
                    Button {
                        dictationLanguageRaw = language.rawValue
                    } label: {
                        if language == dictationLanguage {
                            Label {
                                Text(language.title)
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Text(language.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(dictationLanguage.title)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(preferences.palette.textSecondary)
                .padding(.horizontal, 9)
                .frame(minHeight: 44)
            }
            .accessibilityLabel(Text(ChatStrings.contextDictationLanguage))
            .accessibilityValue(Text(dictationLanguage.title))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
    }

    private var dictationLanguage: DictationLanguage {
        DictationLanguage(rawValue: dictationLanguageRaw) ?? .automatic
    }

    private func requestCamera() {
        notice = nil

        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            notice = ChatStrings.contextCameraSetupRequired
            return
        }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            notice = ChatStrings.contextCameraUnavailable
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showsCamera = true
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) {
                    showsCamera = true
                } else {
                    notice = ChatStrings.contextCameraAccessDenied
                }
            }
        case .denied, .restricted:
            notice = ChatStrings.contextCameraAccessDenied
        @unknown default:
            notice = ChatStrings.contextCameraUnavailable
        }
    }

    private func loadRecentPhotos() async {
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil else {
            recentPhotoAccess = .configurationMissing
            return
        }

        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status: PHAuthorizationStatus
        if currentStatus == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            status = currentStatus
        }

        switch status {
        case .authorized, .limited:
            let options = PHFetchOptions()
            options.fetchLimit = 8
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

            let result = PHAsset.fetchAssets(with: .image, options: options)
            var assets: [PHAsset] = []
            result.enumerateObjects { asset, _, _ in
                assets.append(asset)
            }
            recentAssets = assets
            recentPhotoAccess = .available
        case .denied, .restricted:
            recentPhotoAccess = .denied
        case .notDetermined:
            recentPhotoAccess = .loading
        @unknown default:
            recentPhotoAccess = .denied
        }
    }

    private func openPhotoSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
    }

    private func handleImportedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            notice = nil
            importFiles(urls)
        case let .failure(error):
            let cocoaError = error as NSError
            guard cocoaError.code != NSUserCancelledError else { return }
            notice = ChatStrings.contextFileImportFailed
        }
    }

    private func toggleRecentPhoto(_ asset: PHAsset) {
        let identifier = asset.localIdentifier
        let sourceID = "recent:\(identifier)"
        if selection.recentPhotoIDs.contains(identifier) {
            selection.recentPhotoIDs.remove(identifier)
            selection.images.removeAll { $0.sourceID == sourceID }
            selection.processingItemIDs.remove(sourceID)
            return
        }

        guard selection.images.count + selection.processingItemIDs.count < 10 else {
            notice = ChatStrings.contextImageLimit
            return
        }
        selection.recentPhotoIDs.insert(identifier)
        selection.processingItemIDs.insert(sourceID)

        Task {
            do {
                guard let data = await imageData(for: asset) else {
                    throw ChatAttachmentError.unreadableImage
                }
                let prepared = try await ChatAttachmentProcessor.draftImage(
                    data: data,
                    sourceID: sourceID
                )
                guard selection.recentPhotoIDs.contains(identifier) else { return }
                selection.images.removeAll { $0.sourceID == sourceID }
                selection.images.append(prepared)
            } catch {
                guard selection.processingItemIDs.contains(sourceID) else { return }
                selection.recentPhotoIDs.remove(identifier)
                notice = ChatStrings.contextImageImportFailed
            }
            selection.processingItemIDs.remove(sourceID)
        }
    }

    private func importPickerItems(_ items: [PhotosPickerItem]) {
        let generation = UUID()
        pickerImportGeneration = generation

        let descriptors = items.prefix(10).enumerated().map { index, item in
            (
                item,
                item.itemIdentifier ?? "local-\(index)-\(generation.uuidString)"
            )
        }
        selection.pickerPhotoIDs = descriptors.map { $0.1 }
        selection.images.removeAll { $0.sourceID.hasPrefix("picker:") }
        selection.processingItemIDs = Set(
            selection.processingItemIDs.filter { !$0.hasPrefix("picker:") }
        )

        for (item, identifier) in descriptors {
            let sourceID = "picker:\(identifier)"
            selection.processingItemIDs.insert(sourceID)
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ChatAttachmentError.unreadableImage
                    }
                    let prepared = try await ChatAttachmentProcessor.draftImage(
                        data: data,
                        sourceID: sourceID
                    )
                    guard pickerImportGeneration == generation,
                          selection.pickerPhotoIDs.contains(identifier)
                    else { return }
                    selection.images.append(prepared)
                } catch {
                    guard pickerImportGeneration == generation else { return }
                    selection.pickerPhotoIDs.removeAll { $0 == identifier }
                    notice = ChatStrings.contextImageImportFailed
                }
                selection.processingItemIDs.remove(sourceID)
            }
        }
    }

    private func importCameraImage(_ image: UIImage) {
        guard selection.images.count + selection.processingItemIDs.count < 10 else {
            notice = ChatStrings.contextImageLimit
            return
        }
        guard let data = image.jpegData(compressionQuality: 0.92) else {
            notice = ChatStrings.contextImageImportFailed
            return
        }

        let sourceID = "camera:\(UUID().uuidString)"
        selection.cameraPhotoCount += 1
        selection.processingItemIDs.insert(sourceID)
        Task {
            do {
                let prepared = try await ChatAttachmentProcessor.draftImage(
                    data: data,
                    sourceID: sourceID
                )
                guard selection.processingItemIDs.contains(sourceID) else { return }
                selection.images.append(prepared)
            } catch {
                guard selection.processingItemIDs.contains(sourceID) else { return }
                selection.cameraPhotoCount = max(0, selection.cameraPhotoCount - 1)
                notice = ChatStrings.contextImageImportFailed
            }
            selection.processingItemIDs.remove(sourceID)
        }
    }

    private func importFiles(_ urls: [URL]) {
        let remainingSlots = max(0, 5 - selection.files.count - selection.processingItemIDs.filter {
            $0.hasPrefix("file:")
        }.count)
        guard remainingSlots > 0 else {
            notice = ChatStrings.contextFileLimit
            return
        }

        for url in urls.prefix(remainingSlots) {
            let name = String(url.lastPathComponent.prefix(120))
            guard !selection.fileNames.contains(name) else { continue }
            let sourceID = "file:\(UUID().uuidString)"
            selection.fileNames.append(name)
            selection.processingItemIDs.insert(sourceID)

            Task {
                do {
                    let prepared = try await ChatAttachmentProcessor.draftFile(url: url)
                    guard selection.processingItemIDs.contains(sourceID) else { return }
                    selection.files.append(prepared)
                    if prepared.wasTruncated {
                        notice = ChatStrings.contextFileTruncated
                    }
                } catch let error as ChatAttachmentError where error == .unsupportedFile {
                    guard selection.processingItemIDs.contains(sourceID) else { return }
                    selection.fileNames.removeAll { $0 == name }
                    notice = ChatStrings.contextOfficeUseBrain
                } catch {
                    guard selection.processingItemIDs.contains(sourceID) else { return }
                    selection.fileNames.removeAll { $0 == name }
                    notice = ChatStrings.contextFileImportFailed
                }
                selection.processingItemIDs.remove(sourceID)
            }
        }

        if urls.count > remainingSlots {
            notice = ChatStrings.contextFileLimit
        }
    }

    private func imageData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .none
            options.isNetworkAccessAllowed = true
            options.version = .current

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

private struct ContextSectionHeading: View {
    let title: LocalizedStringResource

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(preferences.palette.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, .leftToRight)
    }
}

private struct ContextPhotoActionTile: View {
    let title: LocalizedStringResource
    let systemImage: String

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 18, tintStrength: 0.045) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(preferences.palette.accent)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(preferences.palette.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.82)
            }
            .frame(width: 78, height: 78)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ContextPhotoStatusTile: View {
    let title: LocalizedStringResource
    let systemImage: String

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        GlassSurface(cornerRadius: 18, tintStrength: 0.025) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(preferences.palette.textMuted)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(preferences.palette.textMuted)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 116, height: 78)
            .padding(.horizontal, 4)
        }
    }
}

private struct ContextPhotoPlaceholder: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(preferences.palette.surfaceSunken)
            .frame(width: 78, height: 78)
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(preferences.palette.textMuted.opacity(0.55))
            }
            .accessibilityHidden(true)
    }
}

private struct RecentPhotoTile: View {
    let asset: PHAsset
    let index: Int
    let isSelected: Bool
    let action: () -> Void

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail = RecentPhotoThumbnailLoader()

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = thumbnail.image(for: asset.localIdentifier) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        preferences.palette.surfaceSunken
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(preferences.palette.textMuted)
                            }
                    }
                }
                .frame(width: 78, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(
                            isSelected ? preferences.palette.accent : preferences.palette.border,
                            lineWidth: isSelected ? 3 : 1
                        )
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(preferences.palette.onAccent, preferences.palette.accent)
                        .font(.system(size: 21, weight: .semibold))
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 78, minHeight: 78)
        .accessibilityLabel(Text(ChatStrings.contextRecentPhoto))
        .accessibilityValue(Text(verbatim: "\(index + 1)"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .task(id: RecentPhotoThumbnailTarget(assetID: asset.localIdentifier, scale: displayScale)) {
            guard !Task.isCancelled else { return }
            thumbnail.load(asset: asset, displayScale: displayScale)
        }
        .onDisappear { thumbnail.cancel() }
    }
}

private nonisolated struct RecentPhotoThumbnailTarget: Equatable {
    let assetID: String
    let scale: CGFloat
}

/// Photos supplies an immutable image; it is handed to MainActor without mutation.
private nonisolated struct RecentPhotoThumbnailResult: @unchecked Sendable {
    let image: UIImage?
    let cancelled: Bool
    let degraded: Bool
}

@MainActor
@Observable
private final class RecentPhotoThumbnailLoader {
    private var currentImage: UIImage?
    @ObservationIgnored private var requests = PhotoThumbnailRequestState()
    @ObservationIgnored private var receivedFinalImage = false
    @ObservationIgnored private let manager = PHImageManager.default()

    func image(for assetID: String) -> UIImage? {
        guard requests.assetID == assetID else { return nil }
        return currentImage
    }

    func load(asset: PHAsset, displayScale: CGFloat) {
        let reservation = requests.reserve(assetID: asset.localIdentifier)
        if let retired = reservation.retiredRequestID { cancelRequest(retired) }
        currentImage = nil
        receivedFinalImage = false
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        let targetSize = CGSize(width: 78 * displayScale, height: 78 * displayScale)
        let requestID = manager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, info in
            let result = RecentPhotoThumbnailResult(image: image,
                cancelled: (info?[PHImageCancelledKey] as? NSNumber)?.boolValue == true,
                degraded: (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue == true)
            Task { @MainActor [weak self] in
                guard let self, self.requests.accepts(reservation.ticket) else { return }
                if result.cancelled {
                    self.cancel(matching: reservation.ticket)
                } else if let image = result.image {
                    guard !self.receivedFinalImage || !result.degraded else { return }
                    if !result.degraded { self.receivedFinalImage = true }
                    self.currentImage = image
                }
            }
        }
        if !requests.attach(requestID, to: reservation.ticket) { cancelRequest(requestID) }
    }

    func cancel(matching ticket: PhotoThumbnailRequestState.Ticket? = nil) {
        if let ticket, !requests.accepts(ticket) { return }
        if let requestID = requests.retire(matching: ticket) { cancelRequest(requestID) }
        currentImage = nil
        receivedFinalImage = false
    }

    private func cancelRequest(_ requestID: PHImageRequestID) {
        guard requestID != PHInvalidImageRequestID else { return }
        manager.cancelImageRequest(requestID)
    }
}

private struct ContextIcon: View {
    let systemImage: String

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 34, height: 34)
            .foregroundStyle(preferences.palette.accent)
            .background(
                preferences.palette.accent.opacity(0.11),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

private struct ContextControlLabel: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let systemImage: String

    var body: some View {
        HStack(spacing: 13) {
            ContextIcon(systemImage: systemImage)
            ContextTextColumn(title: title, detail: detail)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

private struct ContextTextColumn: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    @Environment(PreferencesStore.self) private var preferences

    private var alignment: HorizontalAlignment {
        preferences.language == .arabic ? .trailing : .leading
    }

    private var frameAlignment: Alignment {
        preferences.language == .arabic ? .trailing : .leading
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(preferences.palette.textPrimary)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(preferences.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .multilineTextAlignment(preferences.language == .arabic ? .trailing : .leading)
        .environment(\.layoutDirection, preferences.language.layoutDirection)
    }
}

private struct ContextCountBadge: View {
    let count: Int

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Text(verbatim: "\(count)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(preferences.palette.onAccent)
            .frame(minWidth: 22, minHeight: 22)
            .background(preferences.palette.accent, in: Capsule())
    }
}

private struct ContextDivider: View {
    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        Divider()
            .overlay(preferences.palette.border)
            .padding(.leading, 61)
            .accessibilityHidden(true)
    }
}

private struct ContextSelectionNotice: View {
    let count: Int
    let isProcessing: Bool

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isProcessing ? "hourglass" : "checkmark.circle")
                .foregroundStyle(preferences.palette.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(isProcessing ? ChatStrings.contextProcessing : ChatStrings.contextReady)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(preferences.palette.textPrimary)

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(preferences.palette.accent)
                }
            }

            Spacer(minLength: 8)
            ContextCountBadge(count: count)
        }
        .padding(14)
        .background(
            preferences.palette.surface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(preferences.palette.border, lineWidth: 1)
        }
        .environment(\.layoutDirection, preferences.language.layoutDirection)
    }
}

private struct ContextInlineNotice: View {
    let message: LocalizedStringResource

    @Environment(PreferencesStore.self) private var preferences

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(preferences.palette.error)
                .accessibilityHidden(true)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(preferences.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            preferences.palette.surface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(preferences.palette.error.opacity(0.35), lineWidth: 1)
        }
        .environment(\.layoutDirection, preferences.language.layoutDirection)
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onCapture: onCapture)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private var isPresented: Binding<Bool>
        private let onCapture: (UIImage) -> Void

        init(isPresented: Binding<Bool>, onCapture: @escaping (UIImage) -> Void) {
            self.isPresented = isPresented
            self.onCapture = onCapture
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            isPresented.wrappedValue = false
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            isPresented.wrappedValue = false
        }
    }
}

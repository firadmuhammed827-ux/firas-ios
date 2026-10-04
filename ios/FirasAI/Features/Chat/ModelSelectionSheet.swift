import SwiftUI

struct ModelSelectionSheet: View {
    let initialDraft: String

    init(initialDraft: String = "") { self.initialDraft = initialDraft }
    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var contentVisible = false
    @State private var showsOmnixAccess = false

    var body: some View {
        NavigationStack {
            ZStack {
                FirasBackground()

                ScrollView {
                    VStack(spacing: 14) {
                        Button {
                            showsOmnixAccess = true
                        } label: {
                            HStack {
                                Text(verbatim: "omnix 1").font(.headline).environment(\.layoutDirection, .leftToRight)
                                Spacer()
                                Text(verbatim: preferences.language == .arabic ? "طلب الوصول" : "Request access")
                            }.padding(18)
                        }.buttonStyle(.bordered)
                        generationCard
                        modelCard
                        responseStyleCard
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 34)
                    .frame(maxWidth: .infinity)
                    .opacity(contentVisible ? 1 : 0)
                    .offset(y: contentVisible ? 0 : 22)
                    .scaleEffect(contentVisible ? 1 : 0.975, anchor: .top)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(Text(ChatStrings.modelPickerTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: dismiss.callAsFunction) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("common.close"))
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .frame(minHeight: 44)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showsOmnixAccess) { OmnixAccessSheet(product: .ai, initialDraft: initialDraft) }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
        .presentationBackground(preferences.palette.background)
        .presentationContentInteraction(.scrolls)
        .environment(\.layoutDirection, preferences.language.layoutDirection)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            if reduceMotion || !preferences.motionEnabled {
                contentVisible = true
            } else {
                withAnimation(.snappy(duration: 0.42, extraBounce: 0.035)) {
                    contentVisible = true
                }
            }
        }
    }

    private var generationCard: some View {
        GlassSurface(cornerRadius: 22, tintStrength: 0.035, usesLiquidGlass: false) {
            ModelGenerationPicker()
                .padding(16)
        }
    }

    private var modelCard: some View {
        GlassSurface(cornerRadius: 25, tintStrength: 0.045, usesLiquidGlass: false) {
            VStack(spacing: 0) {
                ForEach(ModelTier.allCases) { tier in
                    Button {
                        select(tier)
                    } label: {
                        ModelTierRow(
                            tier: tier,
                            isSelected: preferences.tier == tier
                        )
                    }
                    .buttonStyle(.plain)

                    if tier != ModelTier.allCases.last {
                        Divider()
                            .overlay(preferences.palette.border)
                            .padding(.leading, 63)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityElement(children: .contain)
    }

    private var responseStyleCard: some View {
        GlassSurface(cornerRadius: 22, tintStrength: 0.035, usesLiquidGlass: false) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(preferences.palette.accent)
                    .background(
                        preferences.palette.accent.opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .accessibilityHidden(true)

                Text("modelPicker.responseStyle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(preferences.palette.textPrimary)

                Spacer(minLength: 10)

                Text("modelPicker.automatic")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(preferences.palette.textSecondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 64)
        }
        .accessibilityElement(children: .combine)
    }

    private func select(_ tier: ModelTier) {
        preferences.tier = tier
        dismiss()
    }
}

private struct ModelTierRow: View {
    let tier: ModelTier
    let isSelected: Bool

    @Environment(PreferencesStore.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 36, height: 36)
                .foregroundStyle(
                    isSelected ? preferences.palette.onAccent : preferences.palette.accent
                )
                .background(
                    isSelected
                        ? preferences.palette.accent
                        : preferences.palette.accent.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: preferences.modelLabel(for: tier))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(preferences.palette.textPrimary)

                Text(verbatim: tier.tagline(language: preferences.language))
                    .font(.subheadline)
                    .foregroundStyle(preferences.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(preferences.palette.accent)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .animation(
            reduceMotion || !preferences.motionEnabled
                ? nil : .snappy(duration: 0.24, extraBounce: 0.08),
            value: isSelected
        )
    }

    private var systemImage: String {
        switch tier {
        case .mini: "bolt.fill"
        case .pro: "sparkles"
        case .ultra: "atom"
        case .max: "crown.fill"
        }
    }
}

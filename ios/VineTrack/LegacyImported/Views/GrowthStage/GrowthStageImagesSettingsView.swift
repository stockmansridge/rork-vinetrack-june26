import SwiftUI
import PhotosUI

struct GrowthStageImagesSettingsView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @State private var selectedStage: GrowthStage?
    @State private var refreshID: UUID = UUID()

    private var canManageSetup: Bool { accessControl.canChangeSettings }

    private var stagesWithImages: [GrowthStage] {
        GrowthStage.allStages.filter { $0.imageName != nil || store.hasCustomELStageImage(for: $0.code) }
    }

    private var stagesWithoutImages: [GrowthStage] {
        GrowthStage.allStages.filter { $0.imageName == nil && !store.hasCustomELStageImage(for: $0.code) }
    }

    var body: some View {
        List {
            Section {
                ForEach(stagesWithImages) { stage in
                    stageRow(stage)
                }
            } header: {
                Text("Stages with Images")
            } footer: {
                Text("Tap a stage to view, replace, or reset its reference image.")
            }

            if !stagesWithoutImages.isEmpty {
                Section {
                    ForEach(stagesWithoutImages) { stage in
                        stageRowNoImage(stage)
                    }
                } header: {
                    Text("Stages without Images")
                } footer: {
                    Text("Add a custom image for stages that don't have a default reference photo.")
                }
            }
        }
        .id(refreshID)
        .navigationTitle("Growth Stage Images")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedStage) { stage in
            GrowthStageImageDetailSheet(stage: stage, canManageSetup: canManageSetup, onChanged: {
                refreshID = UUID()
            })
        }
    }

    private func stageRow(_ stage: GrowthStage) -> some View {
        Button {
            selectedStage = stage
        } label: {
            HStack(spacing: 12) {
                stageThumb(stage)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(stage.code)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                        if store.hasCustomELStageImage(for: stage.code) {
                            Text("Custom")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.gradient, in: Capsule())
                        }
                    }
                    Text(stage.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func stageRowNoImage(_ stage: GrowthStage) -> some View {
        // Read-only roles don't see entries for stages without images at all.
        if !canManageSetup {
            EmptyView()
        } else {
            stageRowNoImageButton(stage)
        }
    }

    private func stageRowNoImageButton(_ stage: GrowthStage) -> some View {
        Button {
            selectedStage = stage
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.tertiarySystemGroupedBackground))
                        .frame(width: 56, height: 42)
                    Image(systemName: "photo.badge.plus")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.code)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(stage.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "plus.circle")
                    .font(.body)
                    .foregroundStyle(.green)
            }
        }
    }

    private func stageThumb(_ stage: GrowthStage) -> some View {
        Group {
            if let resolved = store.resolvedELStageImage(for: stage) {
                Image(uiImage: resolved)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 42)
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.tertiarySystemGroupedBackground))
                    .frame(width: 56, height: 42)
                    .overlay {
                        GrapeLeafIcon(size: 18, color: Color.secondary)
                    }
            }
        }
    }
}

struct GrowthStageImageDetailSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let stage: GrowthStage
    let canManageSetup: Bool
    let onChanged: () -> Void
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var showResetConfirm: Bool = false
    @State private var localRefreshID: UUID = UUID()

    private var hasCustomImage: Bool {
        store.hasCustomELStageImage(for: stage.code)
    }

    private var hasDefaultImage: Bool {
        stage.imageName != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    imageSection
                    infoSection
                    actionsSection
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .id(localRefreshID)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(stage.code)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: selectedPhotoItem) { _, newItem in
                handlePhotoSelection(newItem)
            }
            .alert("Reset to Default", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    store.removeCustomELStageImage(for: stage.code)
                    localRefreshID = UUID()
                    onChanged()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove the custom image and restore the default reference image for \(stage.code).")
            }
        }
    }

    private var imageSection: some View {
        Group {
            if let resolved = store.resolvedELStageImage(for: stage) {
                Image(uiImage: resolved)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(height: 200)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No image available")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
    }

    private var infoSection: some View {
        VStack(spacing: 8) {
            Text(stage.code)
                .font(.title.weight(.bold))
                .foregroundStyle(.green)

            Text(stage.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if hasCustomImage {
                HStack(spacing: 4) {
                    Image(systemName: "paintbrush.fill")
                        .font(.caption)
                    Text("Using custom image")
                        .font(.caption)
                }
                .foregroundStyle(.orange)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var actionsSection: some View {
        if !canManageSetup {
            readOnlyNotice
        } else {
            editableActionsSection
        }
    }

    private var readOnlyNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            Text("Reference images are managed by vineyard owners and managers.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var editableActionsSection: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                HStack(spacing: 8) {
                    Image(systemName: hasCustomImage || hasDefaultImage ? "photo.badge.arrow.down" : "photo.badge.plus")
                    Text(hasCustomImage || hasDefaultImage ? "Replace Image" : "Add Custom Image")
                }
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.green.gradient)
                .foregroundStyle(.white)
                .clipShape(.rect(cornerRadius: 12))
            }

            if hasCustomImage && hasDefaultImage {
                Button {
                    showResetConfirm = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset to Default")
                    }
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .foregroundStyle(.primary)
                    .clipShape(.rect(cornerRadius: 12))
                }
            }

            if hasCustomImage && !hasDefaultImage {
                Button(role: .destructive) {
                    store.removeCustomELStageImage(for: stage.code)
                    localRefreshID = UUID()
                    onChanged()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                        Text("Remove Custom Image")
                    }
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .foregroundStyle(.red)
                    .clipShape(.rect(cornerRadius: 12))
                }
            }
        }
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                let maxSize: CGFloat = 1024
                let scale = min(maxSize / uiImage.size.width, maxSize / uiImage.size.height, 1.0)
                let newSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: newSize)
                let resized = renderer.image { _ in
                    uiImage.draw(in: CGRect(origin: .zero, size: newSize))
                }
                store.saveCustomELStageImage(resized, for: stage.code)
                localRefreshID = UUID()
                onChanged()
            }
            selectedPhotoItem = nil
        }
    }
}

import SwiftUI
import CoreLocation

struct GrowthObservationActionView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(LocationService.self) private var locationService
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(TripTrackingService.self) private var tracking

    @State private var showEditButtons: Bool = false
    @State private var showGrowthPicker: Bool = false
    @State private var pendingSide: PinSide = .right
    @State private var lastGrowthStage: GrowthStage?
    @State private var feedbackMessage: String?
    @State private var feedbackKind: VineyardBadgeKind = .success
    @State private var pendingPhotoPinId: UUID?
    @State private var showPhotoPicker: Bool = false
    @State private var showAutoPhotoConfirm: Bool = false
    @State private var pendingShowPicker: Bool = false

    private var canCreate: Bool { accessControl.canCreateOperationalRecords }
    private var canEdit: Bool { accessControl.canChangeSettings }

    /// Original Growth screen exposes 3 editable observation buttons (excluding Growth Stage which has its own bar).
    /// We deduplicate by name to collapse the 8 default growth buttons into the canonical 3.
    private var observationButtons: [ButtonConfig] {
        let nonGrowthStage = store.growthButtons
            .filter { !$0.isGrowthStageButton }
            .sorted { $0.index < $1.index }

        var seen = Set<String>()
        var unique: [ButtonConfig] = []
        for btn in nonGrowthStage {
            let key = btn.name.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(btn)
            }
        }
        return Array(unique.prefix(3))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !canCreate {
                    PermissionRow()
                }

                growthStageBar

                observationGrid

                if let feedbackMessage {
                    FeedbackBar(message: feedbackMessage, kind: feedbackKind)
                }

                Spacer(minLength: 16)
            }
            .padding(.top, 12)
        }
        .background(VineyardTheme.appBackground)
        .navigationTitle("Growth")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showEditButtons = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
        }
        .sheet(isPresented: $showEditButtons) {
            EditButtonsSheet(mode: .growth)
        }
        .sheet(isPresented: $showGrowthPicker) {
            GrowthStagePickerSheet { stage in
                handleGrowthStageSelected(stage)
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            CameraImagePicker { data in
                attachPhoto(data: data)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showAutoPhotoConfirm, onDismiss: {
            if pendingShowPicker {
                pendingShowPicker = false
                showPhotoPicker = true
            } else {
                pendingPhotoPinId = nil
            }
        }) {
            AutoPhotoConfirmSheet(
                onConfirm: {
                    pendingShowPicker = true
                    showAutoPhotoConfirm = false
                },
                onCancel: {
                    pendingShowPicker = false
                    showAutoPhotoConfirm = false
                }
            )
        }
    }

    private func attachPhoto(data: Data?) {
        defer { pendingPhotoPinId = nil }
        guard let data, let pinId = pendingPhotoPinId else { return }
        guard var pin = store.pins.first(where: { $0.id == pinId }) else { return }
        pin.photoData = data
        store.updatePin(pin)
    }

    // MARK: - Growth Stage bar

    private var growthStageBar: some View {
        Button {
            pendingSide = .right
            showGrowthPicker = true
        } label: {
            HStack(spacing: 12) {
                GrapeLeafIcon(size: 22, color: .white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Growth Stage")
                        .font(.headline.weight(.bold))
                    if let stage = lastGrowthStage {
                        Text("EL \(stage.code) — \(stage.description)")
                            .font(.caption)
                            .lineLimit(1)
                            .opacity(0.9)
                    } else {
                        Text("Tap to select current E-L stage")
                            .font(.caption)
                            .opacity(0.9)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.18, green: 0.55, blue: 0.28), Color(red: 0.12, green: 0.42, blue: 0.20)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: .rect(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canCreate)
        .padding(.horizontal)
    }

    // MARK: - Observation grid

    private var observationGrid: some View {
        VStack(spacing: 8) {
            HStack {
                Text("LEFT")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Text("RIGHT")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal)

            if observationButtons.isEmpty {
                EmptyButtonsState(canEdit: canEdit, showEditButtons: $showEditButtons)
                    .padding(.horizontal)
            } else {
                VStack(spacing: 10) {
                    ForEach(observationButtons) { btn in
                        HStack(spacing: 10) {
                            ActionButtonTile(button: btn, side: .left, canCreate: canCreate) {
                                handleTap(button: btn, side: .left)
                            }
                            ActionButtonTile(button: btn, side: .right, canCreate: canCreate) {
                                handleTap(button: btn, side: .right)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Actions

    private func handleTap(button: ButtonConfig, side: PinSide) {
        guard canCreate else { return }
        guard let location = locationService.location else {
            showFeedback("Waiting for GPS location.", kind: .warning)
            return
        }
        let resolved = PinContextResolver.resolve(coordinate: location.coordinate, store: store, tracking: tracking)
        let createdPin = store.createPinFromButton(
            button: button,
            coordinate: location.coordinate,
            heading: locationService.heading?.trueHeading ?? 0,
            side: side,
            paddockId: resolved.paddockId,
            rowNumber: resolved.rowNumber,
            createdBy: auth.userName,
            createdByUserId: auth.userId,
            notes: nil
        )
        print(PinContextResolver.diagnostic(coordinate: location.coordinate, side: side, mode: .growth, resolved: resolved, store: store, tracking: tracking))
        showFeedback("Pin: \(button.name) (\(side == .left ? "L" : "R"))", kind: .success)
        if store.settings.autoPhotoPrompt, let pin = createdPin {
            pendingPhotoPinId = pin.id
            showAutoPhotoConfirm = true
        }
    }

    private func handleGrowthStageSelected(_ stage: GrowthStage) {
        guard let location = locationService.location else {
            showFeedback("Waiting for GPS location.", kind: .warning)
            return
        }
        lastGrowthStage = stage
        let resolved = PinContextResolver.resolve(coordinate: location.coordinate, store: store, tracking: tracking)
        let createdPin = store.createGrowthStagePin(
            stageCode: stage.code,
            stageDescription: stage.description,
            coordinate: location.coordinate,
            heading: locationService.heading?.trueHeading ?? 0,
            side: pendingSide,
            paddockId: resolved.paddockId,
            rowNumber: resolved.rowNumber,
            createdBy: auth.userName,
            createdByUserId: auth.userId,
            notes: nil
        )
        print(PinContextResolver.diagnostic(coordinate: location.coordinate, side: pendingSide, mode: .growth, resolved: resolved, store: store, tracking: tracking))
        showFeedback("Growth pin: EL \(stage.code)", kind: .success)
        if store.settings.autoPhotoPrompt, let pin = createdPin {
            pendingPhotoPinId = pin.id
            showAutoPhotoConfirm = true
        }
    }

    private func showFeedback(_ message: String, kind: VineyardBadgeKind) {
        withAnimation(.snappy) {
            feedbackMessage = message
            feedbackKind = kind
        }
        Task {
            try? await Task.sleep(for: .seconds(2.0))
            await MainActor.run {
                withAnimation(.easeOut) { feedbackMessage = nil }
            }
        }
    }
}

import SwiftUI
import CoreLocation

struct RepairsActionView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(LocationService.self) private var locationService
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(TripTrackingService.self) private var tracking

    @State private var showEditButtons: Bool = false
    @State private var feedbackMessage: String?
    @State private var feedbackKind: VineyardBadgeKind = .success
    @State private var pendingPhotoPinId: UUID?
    @State private var showPhotoPicker: Bool = false
    @State private var showAutoPhotoConfirm: Bool = false
    @State private var pendingShowPicker: Bool = false

    private var canCreate: Bool { accessControl.canCreateOperationalRecords }
    private var canEdit: Bool { accessControl.canChangeSettings }

    private var sortedButtons: [ButtonConfig] {
        store.repairButtons
            .filter { !$0.isGrowthStageButton }
            .sorted { $0.index < $1.index }
    }

    private var leftButtons: [ButtonConfig] {
        let all = sortedButtons
        let half = max(all.count / 2, 0)
        return Array(all.prefix(half))
    }

    private var rightButtons: [ButtonConfig] {
        let all = sortedButtons
        let half = max(all.count / 2, 0)
        return Array(all.dropFirst(half))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !canCreate {
                    PermissionRow()
                }
                ButtonGridView(
                    leftButtons: leftButtons,
                    rightButtons: rightButtons,
                    canCreate: canCreate,
                    canEdit: canEdit,
                    showEditButtons: $showEditButtons
                ) { btn, side in
                    handleTap(button: btn, side: side)
                }

                if let feedbackMessage {
                    FeedbackBar(message: feedbackMessage, kind: feedbackKind)
                }

                Spacer(minLength: 16)
            }
            .padding(.top, 12)
        }
        .background(VineyardTheme.appBackground)
        .navigationTitle("Repairs")
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
            EditButtonsSheet(mode: .repairs)
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
        print(PinContextResolver.diagnostic(coordinate: location.coordinate, side: side, mode: .repairs, resolved: resolved, store: store, tracking: tracking))
        showFeedback("Pin: \(button.name) (\(side == .left ? "L" : "R"))", kind: .success)
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

// MARK: - Shared Components

struct ActionButtonTile: View {
    let button: ButtonConfig
    let side: PinSide
    let canCreate: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Image(systemName: ButtonIconMap.icon(for: button.name))
                    .font(.title2.weight(.semibold))
                Text(button.name)
                    .font(.title3.weight(.heavy))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .background(
                LinearGradient(
                    colors: [Color.fromString(button.color), Color.fromString(button.color).opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: .rect(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.black.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(!canCreate)
        .opacity(canCreate ? 1 : 0.55)
    }

    private var foreground: Color {
        let isLightColor = ["yellow", "white", "cyan"].contains(button.color.lowercased())
        return isLightColor ? .black : .white
    }
}

struct ButtonGridView: View {
    let leftButtons: [ButtonConfig]
    let rightButtons: [ButtonConfig]
    let canCreate: Bool
    let canEdit: Bool
    @Binding var showEditButtons: Bool
    let onTap: (ButtonConfig, PinSide) -> Void

    var body: some View {
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

            if leftButtons.isEmpty && rightButtons.isEmpty {
                EmptyButtonsState(canEdit: canEdit, showEditButtons: $showEditButtons)
                    .padding(.horizontal)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 10) {
                        ForEach(leftButtons) { btn in
                            ActionButtonTile(button: btn, side: .left, canCreate: canCreate) {
                                onTap(btn, .left)
                            }
                        }
                    }
                    VStack(spacing: 10) {
                        ForEach(rightButtons) { btn in
                            ActionButtonTile(button: btn, side: .right, canCreate: canCreate) {
                                onTap(btn, .right)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct EmptyButtonsState: View {
    let canEdit: Bool
    @Binding var showEditButtons: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No buttons configured")
                .font(.subheadline.weight(.semibold))
            if canEdit {
                Button("Configure Buttons") { showEditButtons = true }
                    .buttonStyle(.vineyardSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Color.white, in: .rect(cornerRadius: 12))
    }
}

struct PermissionRow: View {
    var body: some View {
        Label("Read-only — you do not have permission to drop pins.", systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }
}

struct FeedbackBar: View {
    let message: String
    let kind: VineyardBadgeKind

    var body: some View {
        Label(message, systemImage: kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(kind.foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(kind.background, in: .rect(cornerRadius: 10))
            .padding(.horizontal)
            .transition(.opacity)
    }
}

// MARK: - Icon mapping

enum ButtonIconMap {
    static func icon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("irrigation") || lower.contains("water") || lower.contains("leak") {
            return "drop.fill"
        }
        if lower.contains("post") || lower.contains("trellis") || lower.contains("wire") {
            return "hammer.fill"
        }
        if lower.contains("vine") || lower.contains("leaf") {
            return "leaf.fill"
        }
        if lower.contains("powder") {
            return "sparkles"
        }
        if lower.contains("downy") {
            return "cloud.drizzle.fill"
        }
        if lower.contains("blackberr") || lower.contains("berry") {
            return "circle.hexagongrid.fill"
        }
        if lower.contains("growth") {
            return "leaf.arrow.triangle.circlepath"
        }
        if lower.contains("pest") || lower.contains("bug") || lower.contains("insect") {
            return "ant.fill"
        }
        if lower.contains("disease") {
            return "cross.case.fill"
        }
        if lower.contains("weed") {
            return "leaf.circle.fill"
        }
        if lower.contains("fire") {
            return "flame.fill"
        }
        if lower.contains("frost") || lower.contains("ice") {
            return "snowflake"
        }
        return "mappin.and.ellipse"
    }
}

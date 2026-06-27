import SwiftUI
import CoreLocation

struct PinDropView: View {
    let mode: PinMode

    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(LocationService.self) private var locationService
    @Environment(BackendAccessControl.self) private var accessControl

    @State private var currentMode: PinMode
    @State private var selectedPaddockId: UUID?
    @State private var rowText: String = ""
    @State private var notes: String = ""
    @State private var showEditButtons: Bool = false
    @State private var showGrowthPicker: Bool = false
    @State private var pendingGrowthButton: ButtonConfig?
    @State private var pendingSide: PinSide = .right
    @State private var lastGrowthStage: GrowthStage?
    @State private var feedbackMessage: String?
    @State private var feedbackKind: VineyardBadgeKind = .success
    @State private var showLocationOptions: Bool = false

    init(mode: PinMode) {
        self.mode = mode
        _currentMode = State(initialValue: mode)
    }

    private var canCreate: Bool { accessControl.canCreateOperationalRecords }
    private var canEdit: Bool { accessControl.canChangeSettings }

    private var sortedButtons: [ButtonConfig] {
        let all = currentMode == .repairs ? store.repairButtons : store.growthButtons
        return all.sorted { $0.index < $1.index }
    }

    private var gridButtons: [ButtonConfig] {
        sortedButtons.filter { !$0.isGrowthStageButton }
    }

    private var leftButtons: [ButtonConfig] {
        let all = gridButtons
        let half = max(all.count / 2, 0)
        return Array(all.prefix(half))
    }

    private var rightButtons: [ButtonConfig] {
        let all = gridButtons
        let half = max(all.count / 2, 0)
        if all.count > half {
            return Array(all.dropFirst(half))
        }
        return Array(all.prefix(half))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                modeToggle
                if !canCreate {
                    permissionWarning
                }
                if currentMode == .growth {
                    growthStageBar
                }
                buttonsGrid
                if let feedbackMessage {
                    Label(feedbackMessage, systemImage: feedbackKind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(feedbackKind.foreground)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(feedbackKind.background, in: .rect(cornerRadius: 10))
                        .padding(.horizontal)
                        .transition(.opacity)
                }
                Spacer(minLength: 16)
            }
            .padding(.top, 8)
        }
        .background(VineyardTheme.appBackground)
        .navigationTitle(currentMode == .repairs ? "Repairs" : "Growth")
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
            EditButtonsSheet(mode: currentMode)
        }
        .sheet(isPresented: $showGrowthPicker) {
            GrowthStagePickerSheet { stage in
                handleGrowthStageSelected(stage)
            }
        }
    }

    // MARK: - Mode toggle

    private var modeToggle: some View {
        Picker("Mode", selection: $currentMode) {
            Text("Repairs").tag(PinMode.repairs)
            Text("Growth").tag(PinMode.growth)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    // MARK: - Permission

    private var permissionWarning: some View {
        Label("Read-only — you do not have permission to drop pins.", systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }

    // MARK: - Growth Stage bar

    private var growthStageBar: some View {
        Button {
            pendingSide = .right
            pendingGrowthButton = sortedButtons.first(where: { $0.isGrowthStageButton })
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

    // MARK: - Buttons grid

    private var buttonsGrid: some View {
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

            if leftButtons.isEmpty {
                emptyButtonsState
                    .padding(.horizontal)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 10) {
                        ForEach(leftButtons) { btn in
                            buttonTile(btn, side: .left)
                        }
                    }
                    VStack(spacing: 10) {
                        ForEach(rightButtons) { btn in
                            buttonTile(btn, side: .right)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var emptyButtonsState: some View {
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

    private func buttonTile(_ btn: ButtonConfig, side: PinSide) -> some View {
        let isLightColor = ["yellow", "white", "cyan"].contains(btn.color.lowercased())
        let fg: Color = isLightColor ? .black : .white
        return Button {
            handleTap(button: btn, side: side)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.title3.weight(.semibold))
                Text(btn.name)
                    .font(.title3.weight(.heavy))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background(
                LinearGradient(
                    colors: [Color.fromString(btn.color), Color.fromString(btn.color).opacity(0.82)],
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

    // MARK: - GPS & Location strip

    private var gpsAndLocationStrip: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: gpsAvailable ? "location.fill" : "location.slash")
                    .foregroundStyle(gpsAvailable ? VineyardTheme.success : VineyardTheme.warning)
                Text(gpsAvailable ? "GPS Ready" : "Waiting for GPS…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VineyardTheme.textPrimary)
                if let coord = locationService.location?.coordinate {
                    Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showLocationOptions.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(showLocationOptions ? "Hide" : "Location")
                            .font(.caption.weight(.semibold))
                        Image(systemName: showLocationOptions ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(VineyardTheme.olive)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white, in: .rect(cornerRadius: 10))
            .padding(.horizontal)

            if showLocationOptions {
                VStack(spacing: 8) {
                    HStack {
                        Text("Block")
                            .font(.subheadline)
                            .foregroundStyle(VineyardTheme.textSecondary)
                        Spacer()
                        Picker("Block", selection: $selectedPaddockId) {
                            Text("None").tag(UUID?.none)
                            ForEach(store.paddocks) { paddock in
                                Text(paddock.name).tag(UUID?.some(paddock.id))
                            }
                        }
                        .labelsHidden()
                        .tint(VineyardTheme.olive)
                    }
                    Divider()
                    HStack {
                        Text("Row")
                            .font(.subheadline)
                            .foregroundStyle(VineyardTheme.textSecondary)
                        Spacer()
                        TextField("Optional", text: $rowText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.white, in: .rect(cornerRadius: 10))
                .padding(.horizontal)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy, value: showLocationOptions)
    }

    private var gpsAvailable: Bool { locationService.location != nil }

    // MARK: - Notes

    private var notesField: some View {
        TextField("Notes (optional)", text: $notes, axis: .vertical)
            .lineLimit(1...3)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white, in: .rect(cornerRadius: 10))
            .padding(.horizontal)
    }

    // MARK: - Actions

    private func handleTap(button: ButtonConfig, side: PinSide) {
        guard canCreate else { return }

        if currentMode == .growth && button.isGrowthStageButton {
            pendingGrowthButton = button
            pendingSide = side
            showGrowthPicker = true
            return
        }

        guard let location = locationService.location else {
            showFeedback("Waiting for GPS location.", kind: .warning)
            return
        }

        let rowNumber = Int(rowText.trimmingCharacters(in: .whitespacesAndNewlines))
        store.createPinFromButton(
            button: button,
            coordinate: location.coordinate,
            heading: locationService.heading?.trueHeading ?? 0,
            side: side,
            paddockId: selectedPaddockId,
            rowNumber: rowNumber,
            createdBy: auth.userName,
            createdByUserId: auth.userId,
            notes: nil
        )
        showFeedback("Pin: \(button.name) (\(side == .left ? "L" : "R"))", kind: .success)
    }

    private func handleGrowthStageSelected(_ stage: GrowthStage) {
        guard let location = locationService.location else {
            showFeedback("Waiting for GPS location.", kind: .warning)
            return
        }
        lastGrowthStage = stage
        let rowNumber = Int(rowText.trimmingCharacters(in: .whitespacesAndNewlines))
        store.createGrowthStagePin(
            stageCode: stage.code,
            stageDescription: stage.description,
            coordinate: location.coordinate,
            heading: locationService.heading?.trueHeading ?? 0,
            side: pendingSide,
            paddockId: selectedPaddockId,
            rowNumber: rowNumber,
            createdBy: auth.userName,
            createdByUserId: auth.userId,
            notes: nil
        )
        showFeedback("Growth pin: EL \(stage.code)", kind: .success)
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

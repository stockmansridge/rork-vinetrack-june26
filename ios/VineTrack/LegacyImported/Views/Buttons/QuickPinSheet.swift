import SwiftUI
import CoreLocation

struct QuickPinSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(LocationService.self) private var locationService
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(TripTrackingService.self) private var tracking
    @Environment(\.dismiss) private var dismiss

    @State private var mode: PinMode = .repairs
    @State private var selectedButtonId: UUID?
    @State private var selectedPaddockId: UUID?
    @State private var rowText: String = ""
    @State private var side: PinSide = .right
    @State private var notes: String = ""
    @State private var showGrowthPicker: Bool = false
    @State private var pendingGrowthButton: ButtonConfig?
    @State private var errorMessage: String?
    @State private var duplicateWarning: DuplicateWarning?
    @State private var pinForDetailSheet: VinePin?

    private struct DuplicateWarning: Identifiable {
        let id = UUID()
        let existing: VinePin
        let distance: Double
        let radius: Double
        let attempt: PinDuplicateCreateAttempt
    }

    private typealias ResolvedPlacement = (
        paddockId: UUID?,
        attachment: PinAttachmentResolver.Attachment,
        fallbackRowNumber: Int?
    )

    private var canCreate: Bool { accessControl.canCreateOperationalRecords }

    private var activeButtons: [ButtonConfig] {
        let all = mode == .repairs ? store.repairButtons : store.growthButtons
        // Show only one button per row (first 4 by index)
        return all.sorted { $0.index < $1.index }.prefix(4).map { $0 }
    }

    private var selectedButton: ButtonConfig? {
        guard let id = selectedButtonId else { return nil }
        return activeButtons.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !canCreate {
                    Section {
                        Label("You do not have permission to create pins.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Mode") {
                    Picker("Mode", selection: $mode) {
                        ForEach(PinMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { _, _ in
                        selectedButtonId = nil
                    }
                }

                Section("Button") {
                    if activeButtons.isEmpty {
                        Text("No buttons configured for this mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(activeButtons) { button in
                            Button {
                                selectedButtonId = button.id
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(Color.fromString(button.color).gradient)
                                        .frame(width: 24, height: 24)
                                    Text(button.name)
                                        .foregroundStyle(.primary)
                                    if button.isGrowthStageButton {
                                        GrapeLeafIcon(size: 12, color: .green)
                                    }
                                    Spacer()
                                    if selectedButtonId == button.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(VineyardTheme.leafGreen)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Location") {
                    Picker("Block", selection: $selectedPaddockId) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.paddocks) { paddock in
                            Text(paddock.name).tag(UUID?.some(paddock.id))
                        }
                    }
                    HStack {
                        Text("Row")
                        Spacer()
                        TextField("Optional", text: $rowText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    Picker("Side", selection: $side) {
                        Text("Left").tag(PinSide.left)
                        Text("Right").tag(PinSide.right)
                    }
                    .pickerStyle(.segmented)

                    if let coord = locationService.location?.coordinate {
                        LabeledContent("Coordinates", value: String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                            .font(.caption)
                    } else {
                        Label("Waiting for GPS…", systemImage: "location.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Notes") {
                    TextField("Optional", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Quick Pin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Drop") { handleDrop() }
                        .disabled(!canDrop)
                }
            }
            .sheet(isPresented: $showGrowthPicker) {
                GrowthStagePickerSheet { stage in
                    handleGrowthStageSelected(stage)
                }
            }
            .sheet(item: $duplicateWarning) { warning in
                PinDuplicateWarningSheet(
                    existingPin: warning.existing,
                    distance: warning.distance,
                    radius: warning.radius,
                    onCreateAnyway: {
                        if warning.attempt.createAnyway() {
                            tracking.diagDuplicateCheckResult = appendDuplicateAction("create_anyway")
                        }
                    },
                    onViewExisting: {
                        if warning.attempt.cancel() {
                            tracking.diagDuplicateCheckResult = appendDuplicateAction("view_existing")
                            pinForDetailSheet = warning.existing
                        }
                    },
                    onCancel: {
                        if warning.attempt.cancel() {
                            tracking.diagDuplicateCheckResult = appendDuplicateAction("cancelled")
                        }
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $pinForDetailSheet) { pin in
                PinDetailSheet(pin: pin)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var canDrop: Bool {
        canCreate && selectedButton != nil && locationService.location != nil
    }

    private func handleDrop() {
        guard canCreate else { return }
        guard let button = selectedButton else { return }
        let fix = locationService.freshLocation()
        guard let loc = fix.location else {
            errorMessage = "Location unavailable \u{2014} enable location services to drop a pin."
            return
        }
        if let warning = staleOrLowAccuracyWarning(for: fix.quality) {
            errorMessage = warning
            return
        }

        if mode == .growth && button.isGrowthStageButton {
            pendingGrowthButton = button
            showGrowthPicker = true
            return
        }

        let placement = resolvePlacement(coordinate: loc.coordinate, side: side)
        let duplicateCoordinate = placement.attachment.snappedCoordinate ?? loc.coordinate
        let proceed = { createPin(button: button, location: loc, placement: placement) }
        if let dup = checkDuplicate(
            at: duplicateCoordinate,
            rawCoordinate: loc.coordinate,
            placement: placement,
            side: side,
            mode: button.mode,
            logicalType: button.name
        ) {
            duplicateWarning = DuplicateWarning(
                existing: dup.pin,
                distance: dup.distance,
                radius: dup.radius,
                attempt: PinDuplicateCreateAttempt(create: proceed)
            )
            return
        }
        proceed()
    }

    private func handleGrowthStageSelected(_ stage: GrowthStage) {
        let fix = locationService.freshLocation()
        guard let loc = fix.location else {
            errorMessage = "Location unavailable \u{2014} enable location services to drop a pin."
            return
        }
        if let warning = staleOrLowAccuracyWarning(for: fix.quality) {
            errorMessage = warning
            return
        }
        let placement = resolvePlacement(coordinate: loc.coordinate, side: side)
        let duplicateCoordinate = placement.attachment.snappedCoordinate ?? loc.coordinate
        let proceed = { createGrowthPin(stage: stage, location: loc, placement: placement) }
        if let dup = checkDuplicate(
            at: duplicateCoordinate,
            rawCoordinate: loc.coordinate,
            placement: placement,
            side: side,
            mode: .growth,
            logicalType: "Growth Stage"
        ) {
            duplicateWarning = DuplicateWarning(
                existing: dup.pin,
                distance: dup.distance,
                radius: dup.radius,
                attempt: PinDuplicateCreateAttempt(create: proceed)
            )
            return
        }
        proceed()
    }

    private func createGrowthPin(
        stage: GrowthStage,
        location: CLLocation,
        placement: ResolvedPlacement
    ) {
        let rowNumber = Int(rowText.trimmingCharacters(in: .whitespacesAndNewlines))
        store.createGrowthStagePin(
            stageCode: stage.code,
            stageDescription: stage.description,
            coordinate: location.coordinate,
            heading: locationService.heading?.trueHeading,
            side: side,
            paddockId: placement.paddockId,
            rowNumber: rowNumber ?? placement.attachment.pinRowNumber ?? placement.fallbackRowNumber,
            createdBy: auth.userName,
            createdByUserId: auth.userId,
            notes: notes.isEmpty ? nil : notes,
            attachment: placement.attachment
        )
        dismiss()
    }

    private func createPin(
        button: ButtonConfig,
        location: CLLocation,
        placement: ResolvedPlacement
    ) {
        let rowNumber = Int(rowText.trimmingCharacters(in: .whitespacesAndNewlines))
        store.createPinFromButton(
            button: button,
            coordinate: location.coordinate,
            heading: locationService.heading?.trueHeading,
            side: side,
            paddockId: placement.paddockId,
            rowNumber: rowNumber ?? placement.attachment.pinRowNumber ?? placement.fallbackRowNumber,
            createdBy: auth.userName,
            createdByUserId: auth.userId,
            notes: notes.isEmpty ? nil : notes,
            attachment: placement.attachment
        )
        dismiss()
    }

    /// One-shot immutable placement resolution at commit time (Android
    /// `PinPlacement` parity): explicit block selection wins, else polygon
    /// containment; then snap to the nearest mapped vine row. The result is
    /// used verbatim by the save so payload and UI can never disagree.
    private func resolvePlacement(
        coordinate: CLLocationCoordinate2D,
        side: PinSide
    ) -> ResolvedPlacement {
        let resolved = PinContextResolver.resolve(
            coordinate: coordinate,
            store: store,
            tracking: tracking
        )
        let paddockId = selectedPaddockId ?? resolved.paddockId
        let paddock = paddockId.flatMap { id in store.paddocks.first(where: { $0.id == id }) }
        let attachment = PinAttachmentResolver.resolveManual(
            coordinate: coordinate,
            operatorSide: side,
            paddock: paddock
        )
        return (paddockId, attachment, resolved.rowNumber)
    }

    private func staleOrLowAccuracyWarning(for quality: LocationService.LocationQuality) -> String? {
        switch quality {
        case .fresh:
            return nil
        case .stale:
            return "GPS fix is stale \u{2014} wait a moment for a fresh location before dropping a pin."
        case .lowAccuracy:
            return "GPS accuracy is low \u{2014} move to open sky and try again for a precise pin."
        case .unavailable:
            return "Location unavailable \u{2014} enable location services to drop a pin."
        }
    }

    private func checkDuplicate(
        at coord: CLLocationCoordinate2D,
        rawCoordinate: CLLocationCoordinate2D,
        placement: ResolvedPlacement,
        side: PinSide,
        mode: PinMode,
        logicalType: String
    ) -> (pin: VinePin, distance: Double, radius: Double)? {
        let manualRow = Int(rowText.trimmingCharacters(in: .whitespacesAndNewlines))
        let evaluation = PinDuplicateChecker.evaluate(
            coordinate: coord,
            rawCoordinate: rawCoordinate,
            vineyardId: store.selectedVineyardId,
            paddockId: placement.paddockId,
            rowNumber: placement.attachment.pinRowNumber ?? manualRow ?? placement.fallbackRowNumber,
            side: placement.attachment.pinSide ?? side,
            mode: mode,
            logicalType: logicalType,
            in: store.pins,
            paddocks: store.paddocks
        )
        tracking.diagDuplicateRadiusMeters = evaluation.diagnostics.radius
        tracking.diagDuplicateCheckResult = evaluation.diagnostics.description
        guard let match = evaluation.match else { return nil }
        return (match.pin, match.distance, match.radius)
    }

    private func appendDuplicateAction(_ action: String) -> String {
        "\(tracking.diagDuplicateCheckResult ?? "result=unknown"); action=\(action)"
    }
}

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
    @State private var pendingGrowthLocation: CLLocation?
    @State private var pendingGrowthPlacement: ResolvedPlacement?
    @State private var errorMessage: String?
    @State private var duplicateWarning: DuplicateWarning?
    @State private var pinForDetailSheet: VinePin?
    @State private var pendingAisleConfirmation: PendingMappedAisleConfirmation?

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
        fallbackRowNumber: Int?,
        capture: PinCaptureContext?
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
            .confirmationDialog(
                "Confirm mapped aisle and row",
                isPresented: Binding(
                    get: { pendingAisleConfirmation != nil },
                    set: { if !$0 { pendingAisleConfirmation = nil } }
                ),
                presenting: pendingAisleConfirmation
            ) { request in
                ForEach(request.choices) { choice in
                    Button(choice.label) {
                        pendingAisleConfirmation = nil
                        choice.confirm()
                    }
                }
                Button("Cancel", role: .cancel) { pendingAisleConfirmation = nil }
            } message: { request in
                Text("Frozen GPS observation in \(request.paddockName). Confirm this mapped result to continue.")
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

        let placement = resolvePlacement(location: loc, side: side)
        if mode == .growth && button.isGrowthStageButton {
            let sideFree: ResolvedPlacement = (
                placement.paddockId,
                PinAttachmentResolver.Attachment(
                    drivingRowNumber: nil,
                    pinRowNumber: nil,
                    pinSide: nil,
                    snappedCoordinate: nil,
                    alongRowDistanceM: nil,
                    snappedToRow: false,
                    heading: placement.attachment.heading
                ),
                nil,
                placement.capture
            )
            pendingGrowthButton = button
            pendingGrowthLocation = loc
            pendingGrowthPlacement = sideFree
            showGrowthPicker = true
            return
        }

        let continueWith: @MainActor (ResolvedPlacement) -> Void = { frozenPlacement in
            let duplicateCoordinate = frozenPlacement.attachment.snappedCoordinate ?? loc.coordinate
            let proceed = { createPin(button: button, location: loc, placement: frozenPlacement) }
            if let dup = checkDuplicate(
                at: duplicateCoordinate,
                rawCoordinate: loc.coordinate,
                placement: frozenPlacement,
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
            } else {
                proceed()
            }
        }
        // Missing heading/aisle/row leaves enrichment fields unset; a valid
        // accepted point is persisted immediately without a compulsory dialog.
        continueWith(placement)
    }

    private func handleGrowthStageSelected(_ stage: GrowthStage) {
        guard let loc = pendingGrowthLocation, let placement = pendingGrowthPlacement else {
            errorMessage = "The frozen GPS observation is no longer available. Press Drop again."
            return
        }
        pendingGrowthLocation = nil
        pendingGrowthPlacement = nil
        pendingGrowthButton = nil
        let duplicateCoordinate = loc.coordinate
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
        let created = store.createGrowthStagePin(
            stageCode: stage.code,
            stageDescription: stage.description,
            coordinate: location.coordinate,
            heading: placement.attachment.heading,
            capture: placement.capture,
            side: nil,
            paddockId: placement.paddockId,
            rowNumber: nil,
            createdBy: auth.userName,
            createdByUserId: auth.userId,
            notes: notes.isEmpty ? nil : notes,
            attachment: placement.attachment
        )
        guard created != nil else {
            errorMessage = "Could not create pin \u{2014} the vineyard or trip changed since this sheet was opened. Try again."
            return
        }
        dismiss()
    }

    private func createPin(
        button: ButtonConfig,
        location: CLLocation,
        placement: ResolvedPlacement
    ) {
        let rowNumber = Int(rowText.trimmingCharacters(in: .whitespacesAndNewlines))
        let created = store.createPinFromButton(
            button: button,
            // The original observation, never the snapped point.
            coordinate: location.coordinate,
            // Frozen capture heading: the exact facing the row choice used.
            heading: placement.attachment.heading,
            capture: placement.capture,
            side: side,
            paddockId: placement.paddockId,
            // Typed row (manual intent) wins; otherwise only a confirmed
            // attached row — never the nearest-row guess.
            rowNumber: rowNumber ?? placement.attachment.pinRowNumber,
            createdBy: auth.userName,
            createdByUserId: auth.userId,
            notes: notes.isEmpty ? nil : notes,
            attachment: placement.attachment
        )
        guard created != nil else {
            errorMessage = "Could not create pin \u{2014} the vineyard or trip changed since this sheet was opened. Try again."
            return
        }
        dismiss()
    }

    /// One-shot immutable placement resolution at commit time (Android
    /// `PinPlacement` parity): explicit block selection wins, else polygon
    /// containment; then the automatic aisle/side geometry attaches the pin to
    /// the vine row on the operator's side for their recorded heading. The
    /// result is used verbatim by the save so payload and UI can never
    /// disagree, and an unconfirmed capture stays honestly point-only.
    private func resolvePlacement(
        location: CLLocation,
        side: PinSide
    ) -> ResolvedPlacement {
        let coordinate = location.coordinate
        let resolved = PinContextResolver.resolve(
            coordinate: coordinate,
            store: store,
            tracking: tracking
        )
        let paddockId = selectedPaddockId ?? resolved.paddockId
        let paddock = paddockId.flatMap { id in store.paddocks.first(where: { $0.id == id }) }
        let capturedAt = Date()
        let headingAge: Double? = locationService.heading.map { sample in
            capturedAt.timeIntervalSince(sample.timestamp)
        }
        let historyLock = PinAisleObservationLock.resolve(
            locations: locationService.pinAisleObservationHistory,
            current: location,
            paddock: paddock
        )
        let attachment = PinAttachmentResolver.resolveAutomatic(
            rawCoordinate: coordinate,
            heading: locationService.heading?.trueHeading,
            headingAgeSeconds: headingAge,
            horizontalAccuracyMetres: location.horizontalAccuracy,
            operatorSide: side,
            paddock: paddock,
            capturedAt: capturedAt,
            aisleLock: historyLock
        )
        // Identity and time are frozen here so a duplicate confirmation or a
        // growth-stage picker cannot save into a different context.
        let capture: PinCaptureContext? = store.selectedVineyardId.map { vineyardId in
            PinCaptureContext(
                capturedAt: capturedAt,
                locationObservedAt: location.timestamp,
                vineyardId: vineyardId,
                tripId: store.currentActiveTripIdProvider?(),
                rawCoordinate: coordinate,
                horizontalAccuracyMetres: location.horizontalAccuracy
            )
        }
        return (paddockId, attachment, resolved.rowNumber, capture)
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
        side: PinSide?,
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

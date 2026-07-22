import SwiftUI
import CoreLocation

struct RepairsGrowthView: View {
    enum Tab: Int, Hashable { case repairs = 0, growth = 1 }

    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(LocationService.self) private var locationService
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(TripTrackingService.self) private var tracking

    @State private var selection: Tab
    @State private var showEditButtons: Bool = false
    @State private var showGrowthPicker: Bool = false
    @State private var lastGrowthStage: GrowthStage?
    @State private var errorMessage: String?
    @State private var pinToast: PinDroppedToastInfo?
    @State private var pendingPhotoPinId: UUID?
    @State private var showPhotoPicker: Bool = false
    @State private var showAutoPhotoConfirm: Bool = false
    @State private var pendingShowPicker: Bool = false

    // Pin-duplicate warning state
    @State private var duplicateWarning: DuplicateWarning?
    @State private var pinForDetailSheet: VinePin?

    private struct DuplicateWarning: Identifiable {
        let id = UUID()
        let existing: VinePin
        let distance: Double
        let radius: Double
        let proceed: () -> Void
    }

    init(initial: Tab = .repairs) {
        _selection = State(initialValue: initial)
    }

    private var canCreate: Bool { accessControl.canCreateOperationalRecords }
    private var canEdit: Bool { accessControl.canChangeSettings }

    /// All non-growth-stage repair buttons sorted by index.
    private var repairButtons: [ButtonConfig] {
        store.repairButtons
            .filter { !$0.isGrowthStageButton }
            .sorted { $0.index < $1.index }
    }

    /// All non-growth-stage growth observation buttons sorted by index.
    private var growthButtons: [ButtonConfig] {
        store.growthButtons
            .filter { !$0.isGrowthStageButton }
            .sorted { $0.index < $1.index }
    }

    private func leftHalf(_ buttons: [ButtonConfig]) -> [ButtonConfig] {
        let half = max(buttons.count / 2, 0)
        return Array(buttons.prefix(half))
    }

    private func rightHalf(_ buttons: [ButtonConfig]) -> [ButtonConfig] {
        let half = max(buttons.count / 2, 0)
        return buttons.count > half ? Array(buttons.dropFirst(half)) : []
    }

    var body: some View {
        VStack(spacing: 0) {
            segmentHeader
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 6)

            TabView(selection: $selection) {
                repairsPage
                    .tag(Tab.repairs)
                growthPage
                    .tag(Tab.growth)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.25), value: selection)

            if let errorMessage {
                FeedbackBar(message: errorMessage, kind: .destructive)
                    .padding(.bottom, 8)
            }
        }
        .background(VineyardTheme.appBackground)
        .pinDroppedToast($pinToast)
        .navigationTitle(store.selectedVineyard?.name ?? "Vineyard")
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
            EditButtonsSheet(mode: selection == .repairs ? .repairs : .growth)
        }
        .sheet(isPresented: $showGrowthPicker) {
            GrowthStagePickerSheet { stage in
                lastGrowthStage = stage
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
        .sheet(item: $duplicateWarning) { warning in
            PinDuplicateWarningSheet(
                existingPin: warning.existing,
                distance: warning.distance,
                radius: warning.radius,
                onCreateAnyway: {
                    tracking.diagDuplicateCheckResult = "duplicate_create_anyway"
                    warning.proceed()
                },
                onViewExisting: {
                    tracking.diagDuplicateCheckResult = "duplicate_view_existing"
                    pinForDetailSheet = warning.existing
                },
                onCancel: {
                    tracking.diagDuplicateCheckResult = "duplicate_cancelled"
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

    private func attachPhoto(data: Data?) {
        defer { pendingPhotoPinId = nil }
        guard let data, let pinId = pendingPhotoPinId else { return }
        guard var pin = store.pins.first(where: { $0.id == pinId }) else { return }
        pin.photoData = data
        store.updatePin(pin)
    }

    // MARK: - Segmented header

    private var segmentHeader: some View {
        HStack(spacing: 8) {
            segmentButton(title: "Repairs", tab: .repairs) {
                Image(systemName: "wrench.fill")
                    .font(.subheadline.weight(.bold))
            }
            segmentButton(title: "Growth", tab: .growth) {
                GrapeLeafIcon(size: 18, color: selection == .growth ? .white : .primary)
            }
        }
        .padding(4)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
    }

    private func segmentButton<Icon: View>(title: String, tab: Tab, @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { selection = tab }
        } label: {
            HStack(spacing: 6) {
                icon()
                Text(title)
                    .font(.headline.weight(.bold))
            }
            .foregroundStyle(selection == tab ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                selection == tab ? VineyardTheme.primary : Color.clear,
                in: .rect(cornerRadius: 9)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Repairs page

    private var repairsPage: some View {
        VStack(spacing: 0) {
            if !canCreate { PermissionRow().padding(.bottom, 6) }
            if repairButtons.isEmpty {
                EmptyButtonsState(canEdit: canEdit, showEditButtons: $showEditButtons)
                    .padding(.horizontal)
                    .padding(.top, 12)
                Spacer()
            } else {
                leftRightButtonGrid(buttons: repairButtons)
            }
        }
    }

    // MARK: - Growth page

    private var growthPage: some View {
        VStack(spacing: 10) {
            if !canCreate { PermissionRow() }
            growthStageBar
                .padding(.horizontal)

            if growthButtons.isEmpty {
                EmptyButtonsState(canEdit: canEdit, showEditButtons: $showEditButtons)
                    .padding(.horizontal)
                Spacer()
            } else {
                leftRightButtonGrid(buttons: growthButtons)
            }
        }
        .padding(.top, 4)
    }

    private var growthStageBar: some View {
        Button {
            guard canCreate else { return }
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
    }

    // MARK: - Left/Right grid

    private func leftRightButtonGrid(buttons: [ButtonConfig]) -> some View {
        let left = leftHalf(buttons)
        let right = rightHalf(buttons)
        let rowCount = max(left.count, right.count)
        return VStack(spacing: 8) {
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

            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 10) {
                    ForEach(left) { btn in
                        FillingActionTile(button: btn, canCreate: canCreate) {
                            handleButtonTap(button: btn, side: .left)
                        }
                    }
                    ForEach(0..<max(rowCount - left.count, 0), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 10) {
                    ForEach(right) { btn in
                        FillingActionTile(button: btn, canCreate: canCreate) {
                            handleButtonTap(button: btn, side: .right)
                        }
                    }
                    ForEach(0..<max(rowCount - right.count, 0), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .padding(.top, 6)
    }

    // MARK: - Actions

    private func handleButtonTap(button: ButtonConfig, side: PinSide) {
        guard canCreate else { return }
        let fix = locationService.freshLocation()
        guard let loc = fix.location else {
            showError("Location unavailable \u{2014} enable location services to drop a pin.")
            return
        }
        if let warning = staleOrLowAccuracyWarning(for: fix.quality) {
            showError(warning)
            return
        }
        let raw = loc.coordinate
        let resolved = PinContextResolver.resolve(coordinate: raw, store: store, tracking: tracking)
        let attachment = liveAttachment(raw: raw, resolved: resolved, side: side)
        let coord = attachment.snappedCoordinate ?? raw
        let proceed = {
            createRepairPin(
                button: button,
                side: side,
                coord: coord,
                resolved: resolved,
                attachment: attachment
            )
        }
        if let dup = checkDuplicate(at: coord, resolved: resolved, attachment: attachment, side: side, mode: button.mode) {
            recordDuplicateWarningShown(dup)
            duplicateWarning = DuplicateWarning(
                existing: dup.pin,
                distance: dup.distance,
                radius: dup.radius,
                proceed: proceed
            )
            return
        }
        proceed()
    }

    private func createRepairPin(
        button: ButtonConfig,
        side: PinSide,
        coord: CLLocationCoordinate2D,
        resolved: PinContextResolver.Resolved,
        attachment: PinAttachmentResolver.Attachment
    ) {
        let heading = locationService.heading?.trueHeading ?? 0
        let pin = store.createPinFromButton(
            button: button,
            coordinate: coord,
            heading: heading,
            side: side,
            paddockId: resolved.paddockId,
            rowNumber: resolved.rowNumber,
            createdBy: auth.userName,
            createdByUserId: auth.userId,
            attachment: attachment
        )
        print(PinContextResolver.diagnostic(coordinate: coord, side: side, mode: .repairs, resolved: resolved, store: store, tracking: tracking))
        guard let createdPin = pin else {
            showError("Could not create pin \u{2014} no vineyard selected.")
            return
        }
        let subtitle = PinAttachmentFormatter.toastSubtitle(attachment: attachment, fallbackSide: side, heading: heading)
        showPinToast(title: "\(button.name) pin dropped", subtitle: subtitle)
        if store.settings.autoPhotoPrompt {
            pendingPhotoPinId = createdPin.id
            showAutoPhotoConfirm = true
        }
    }

    private func handleGrowthStageSelected(_ stage: GrowthStage) {
        guard canCreate else { return }
        let fix = locationService.freshLocation()
        guard let loc = fix.location else {
            showError("Location unavailable \u{2014} enable location services to drop a pin.")
            return
        }
        if let warning = staleOrLowAccuracyWarning(for: fix.quality) {
            showError(warning)
            return
        }
        let raw = loc.coordinate
        let resolved = PinContextResolver.resolve(coordinate: raw, store: store, tracking: tracking)
        let attachment = liveAttachment(raw: raw, resolved: resolved, side: .right)
        let coord = attachment.snappedCoordinate ?? raw
        let proceed = {
            createGrowthPin(
                stage: stage,
                coord: coord,
                resolved: resolved,
                attachment: attachment
            )
        }
        if let dup = checkDuplicate(at: coord, resolved: resolved, attachment: attachment, side: .right, mode: .growth) {
            recordDuplicateWarningShown(dup)
            duplicateWarning = DuplicateWarning(
                existing: dup.pin,
                distance: dup.distance,
                radius: dup.radius,
                proceed: proceed
            )
            return
        }
        proceed()
    }

    private func createGrowthPin(
        stage: GrowthStage,
        coord: CLLocationCoordinate2D,
        resolved: PinContextResolver.Resolved,
        attachment: PinAttachmentResolver.Attachment
    ) {
        let heading = locationService.heading?.trueHeading ?? 0
        let pin = store.createGrowthStagePin(
            stageCode: stage.code,
            stageDescription: stage.description,
            coordinate: coord,
            heading: heading,
            side: .right,
            paddockId: resolved.paddockId,
            rowNumber: resolved.rowNumber,
            createdBy: auth.userName,
            createdByUserId: auth.userId,
            attachment: attachment
        )
        print(PinContextResolver.diagnostic(coordinate: coord, side: .right, mode: .growth, resolved: resolved, store: store, tracking: tracking))
        guard let createdPin = pin else {
            showError("Could not create pin \u{2014} no vineyard selected.")
            return
        }
        let attached = PinAttachmentFormatter.attachmentSubtitle(attachment: attachment, heading: heading)
        let subtitle: String = {
            if let attached {
                return "EL \(stage.code) \u{2022} \(attached)"
            }
            return "EL \(stage.code) \u{2022} \(stage.description)"
        }()
        showPinToast(title: "Growth stage recorded", subtitle: subtitle)
        if store.settings.autoPhotoPrompt {
            pendingPhotoPinId = createdPin.id
            showAutoPhotoConfirm = true
        }
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

    /// Build a full attachment using the live trip lock + row geometry.
    /// Falls back to a side-only manual attachment when no confident
    /// lock or paddock geometry is available.
    private func liveAttachment(
        raw: CLLocationCoordinate2D,
        resolved: PinContextResolver.Resolved,
        side: PinSide
    ) -> PinAttachmentResolver.Attachment {
        let confident = tracking.isTracking && tracking.diagLockConfidence >= 0.6
        let drivingPath: Double? = tracking.diagLockedPath ?? tracking.currentRowNumber
        let paddock: Paddock? = resolved.paddockId.flatMap { id in
            store.paddocks.first(where: { $0.id == id })
        }
        let heading = locationService.heading?.trueHeading ?? 0
        return PinAttachmentResolver.resolveLive(
            rawCoordinate: raw,
            heading: heading,
            operatorSide: side,
            drivingPath: drivingPath,
            paddock: paddock,
            confident: confident
        )
    }

    private func checkDuplicate(
        at coord: CLLocationCoordinate2D,
        resolved: PinContextResolver.Resolved,
        attachment: PinAttachmentResolver.Attachment,
        side: PinSide,
        mode: PinMode
    ) -> (pin: VinePin, distance: Double, radius: Double)? {
        // Prefer the resolved actual vine row (pin_row_number) when the
        // attachment confidently snapped — that's what newer pins store.
        // Fall back to the legacy nearest-row resolution otherwise.
        let rowForDuplicate = attachment.pinRowNumber ?? resolved.rowNumber
        let sideForDuplicate = attachment.pinSide ?? side
        if let alongRow = PinDuplicateChecker.nearbyPinAlongRow(
            snappedCoordinate: coord,
            vineyardId: store.selectedVineyardId,
            paddockId: resolved.paddockId,
            rowNumber: rowForDuplicate,
            side: sideForDuplicate,
            mode: mode,
            in: store.pins,
            paddocks: store.paddocks
        ) {
            tracking.diagDuplicateRadiusMeters = PinDuplicateChecker.alongRowDuplicateMetres
            return (alongRow.pin, alongRow.distance, PinDuplicateChecker.alongRowDuplicateMetres)
        }
        let radius = PinDuplicateChecker.duplicateRadius(
            coordinate: coord,
            paddockId: resolved.paddockId,
            paddocks: store.paddocks
        )
        tracking.diagDuplicateRadiusMeters = radius
        guard let match = PinDuplicateChecker.nearbyPin(
            coordinate: coord,
            vineyardId: store.selectedVineyardId,
            paddockId: resolved.paddockId,
            radius: radius,
            in: store.pins
        ) else {
            tracking.diagDuplicateCheckResult = "no_duplicate_found"
            return nil
        }
        return (match.pin, match.distance, radius)
    }

    private func recordDuplicateWarningShown(
        _ dup: (pin: VinePin, distance: Double, radius: Double)
    ) {
        let title = dup.pin.buttonName.isEmpty ? "pin" : dup.pin.buttonName
        let status = dup.pin.isCompleted ? "completed" : "active"
        let dist = String(format: "%.2f", dup.distance)
        tracking.diagDuplicateRadiusMeters = dup.radius
        tracking.diagDuplicateCheckResult =
            "duplicate_warning_shown: \(title), \(dist)m, status=\(status)"
    }

    private func showPinToast(title: String, subtitle: String) {
        pinToast = PinDroppedToastInfo(title: title, subtitle: subtitle)
        errorMessage = nil
    }

    private func showError(_ message: String) {
        errorMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if errorMessage == message { errorMessage = nil }
        }
    }
}

// MARK: - Filling tile (uses contextual icon)

struct FillingActionTile: View {
    let button: ButtonConfig
    let canCreate: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.title2.weight(.semibold))
                Text(button.name)
                    .font(.headline.weight(.heavy))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

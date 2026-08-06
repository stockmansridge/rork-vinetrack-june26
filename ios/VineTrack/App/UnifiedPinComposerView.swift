import SwiftUI
import MapKit
import CoreLocation

/// Unified "Add Pin / Action" composer (sql/170) — an extension of the
/// existing pin workflow, not a separate issue system.
///
/// Location-first flow:
///  1. Choose how to add the pin: drop a pin manually / select a row /
///     select a block.
///  2. Pick the location using the chosen method (map tap with canonical row
///     snapping, block + row/quarter selection, or block only).
///  3. Swipeable Repair | Growth | Custom tabs; tap a type, then Save Pin.
///
/// Repair and Growth saves go through the existing local-first pin create
/// path (mode Repairs/Growth); Custom saves use the simplified
/// `create_custom_pin` RPC (mode ManualIssue) referencing the
/// vineyard-shared custom type. There is no Left/Right selection and no
/// category/priority/due-date/assignee/status controls anywhere in this
/// flow. The saved pin lands on the existing Pins map/list.
struct UnifiedPinComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(CustomPinTypeService.self) private var customPinService

    /// Called after a successful save so the caller can jump to the Pins tab.
    var onSaved: () -> Void = {}

    private enum Step { case method, location, type }

    @State private var step: Step = .method
    @State private var method: String = UnifiedPinContract.scopePoint

    // Location state.
    @State private var tappedCoordinate: CLLocationCoordinate2D?
    @State private var selectedPaddockId: UUID?
    @State private var selectedSegments: Set<ManualIssueSegment> = []

    // Type selection.
    @State private var selectedStandard: ButtonConfig?
    @State private var selectedCustom: CustomPinTypeRecord?
    @State private var showAddCustom = false
    @State private var newCustomName = ""

    @State private var validationMessage: String?
    @State private var isSaving = false

    private var selectedPaddock: Paddock? {
        store.paddocks.first { $0.id == selectedPaddockId }
    }

    private var hasSelectedType: Bool {
        selectedStandard != nil || selectedCustom != nil
    }

    var body: some View {
        Group {
            switch step {
            case .method: methodStep
            case .location: locationStep
            case .type: typeStep
            }
        }
        .background(VineyardTheme.appBackground)
        .navigationTitle("Add Pin / Action")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            customPinService.store = store
            if let vineyardId = store.selectedVineyardId {
                await customPinService.refresh(vineyardId: vineyardId)
            }
        }
        .alert("Add custom item", isPresented: $showAddCustom) {
            TextField("Custom item name", text: $newCustomName)
            Button("Add") { addCustomItem() }
            Button("Cancel", role: .cancel) { newCustomName = "" }
        } message: {
            Text("Shared with everyone in this vineyard.")
        }
    }

    // MARK: - Step 1: location method

    private var methodStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("How do you want to add the pin?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                methodCard(
                    title: "Drop a pin manually",
                    subtitle: "Tap a point on the map — no block selection needed",
                    icon: "mappin.and.ellipse",
                    color: VineyardTheme.primary,
                    scope: UnifiedPinContract.scopePoint
                )
                methodCard(
                    title: "Select a row",
                    subtitle: "Pick a block, then one or more rows or row sections",
                    icon: "rectangle.split.3x1",
                    color: VineyardTheme.leafGreen,
                    scope: UnifiedPinContract.scopeRow
                )
                methodCard(
                    title: "Select a block",
                    subtitle: "Flag a whole block",
                    icon: "square.dashed",
                    color: Color(red: 0.55, green: 0.4, blue: 0.24),
                    scope: UnifiedPinContract.scopeBlock
                )
            }
            .padding(.horizontal)
        }
    }

    private func methodCard(title: String, subtitle: String, icon: String, color: Color, scope: String) -> some View {
        Button {
            if method != scope {
                // Changing the method clears location state so no stale
                // snapping/segments survive.
                tappedCoordinate = nil
                selectedPaddockId = nil
                selectedSegments = []
            }
            method = scope
            validationMessage = nil
            step = .location
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(color, in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: location

    private var locationStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch method {
                case UnifiedPinContract.scopeRow:
                    blockPicker
                    rowGrid
                case UnifiedPinContract.scopeBlock:
                    blockPicker
                    if selectedPaddock != nil {
                        Label("The whole block will be flagged", systemImage: "square.dashed")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                default:
                    pointPicker
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    continueFromLocation()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(VineyardTheme.primary, in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") { step = .method }
            }
        }
    }

    private func continueFromLocation() {
        let error: String? = {
            switch method {
            case UnifiedPinContract.scopePoint:
                return tappedCoordinate == nil ? "Tap the map to place the pin." : nil
            case UnifiedPinContract.scopeRow:
                if selectedPaddockId == nil { return "Select the block that owns the rows." }
                if ManualIssueContract.canonicalSegments(Array(selectedSegments)).isEmpty {
                    return "Select at least one row."
                }
                return nil
            default:
                return selectedPaddockId == nil ? "Select a block." : nil
            }
        }()
        if let error {
            validationMessage = error
        } else {
            validationMessage = nil
            step = .type
        }
    }

    private var pointPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tap the map to place the pin")
                .font(.footnote)
                .foregroundStyle(.secondary)
            MapReader { proxy in
                Map(initialPosition: .region(initialRegion)) {
                    if let tappedCoordinate {
                        Annotation("", coordinate: tappedCoordinate) {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white, VineyardTheme.primary)
                        }
                    }
                }
                .mapStyle(.hybrid)
                .frame(height: 320)
                .clipShape(.rect(cornerRadius: 10))
                .onTapGesture { position in
                    if let coordinate = proxy.convert(position, from: .local) {
                        tappedCoordinate = coordinate
                        validationMessage = nil
                    }
                }
            }
            // Canonical snapping preview — the same resolution the save uses.
            if let tappedCoordinate {
                let attachment = resolvedAttachment(for: tappedCoordinate)
                let block = RowGuidance.paddock(for: tappedCoordinate, in: store.paddocks)
                if let block, attachment.snappedToRow, let row = attachment.pinRowNumber {
                    Label("\(block.name) · on row \(row)", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let block {
                    Label("\(block.name) · not attached to a row", systemImage: "mappin")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Pin placed outside mapped blocks", systemImage: "mappin")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var initialRegion: MKCoordinateRegion {
        if let tappedCoordinate {
            return MKCoordinateRegion(
                center: tappedCoordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
            )
        }
        if let paddock = selectedPaddock ?? store.paddocks.first(where: { !$0.polygonPoints.isEmpty }) {
            return MKCoordinateRegion(
                center: paddock.polygonPoints.centroid,
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
            )
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -34.9, longitude: 138.6),
            span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 40)
        )
    }

    private var blockPicker: some View {
        Picker("Block", selection: $selectedPaddockId) {
            Text("Select a block").tag(UUID?.none)
            ForEach(store.paddocks) { paddock in
                Text(paddock.name).tag(UUID?.some(paddock.id))
            }
        }
        .pickerStyle(.menu)
        .onChange(of: selectedPaddockId) { _, _ in
            selectedSegments = []
            validationMessage = nil
        }
    }

    @ViewBuilder
    private var rowGrid: some View {
        if let paddock = selectedPaddock {
            let rows = paddock.rows.sorted { $0.number < $1.number }
            if rows.isEmpty {
                Label("This block has no mapped rows — flag the whole block instead", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                if !selectedSegments.isEmpty {
                    Text(ManualIssueContract.rowSelectionSummary(Array(selectedSegments)))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(VineyardTheme.leafGreen)
                }
                ForEach(rows) { row in
                    rowLine(row)
                }
            }
        }
    }

    private func rowLine(_ row: PaddockRow) -> some View {
        HStack(spacing: 6) {
            Button {
                let all = (1...4).map { ManualIssueSegment(row: row.number, segment: $0) }
                if all.allSatisfy({ selectedSegments.contains($0) }) {
                    all.forEach { selectedSegments.remove($0) }
                } else {
                    all.forEach { selectedSegments.insert($0) }
                }
            } label: {
                Text("\(row.number)")
                    .font(.caption.weight(.semibold))
                    .frame(width: 34, height: 26)
                    .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            ForEach(1...4, id: \.self) { quarter in
                let segment = ManualIssueSegment(row: row.number, segment: quarter)
                let isSelected = selectedSegments.contains(segment)
                Button {
                    if isSelected {
                        selectedSegments.remove(segment)
                    } else {
                        selectedSegments.insert(segment)
                    }
                } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? VineyardTheme.leafGreen : Color(.tertiarySystemBackground))
                        .frame(height: 26)
                        .overlay {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Step 3: Repair | Growth | Custom

    @State private var tabSelection: Int = 0

    private var typeStep: some View {
        VStack(spacing: 0) {
            // Tappable + swipeable tabs, same ordering and wording as Android.
            HStack(spacing: 8) {
                ForEach(Array(UnifiedPinContract.tabs.enumerated()), id: \.offset) { index, title in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { tabSelection = index }
                    } label: {
                        Text(title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(tabSelection == index ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                tabSelection == index ? VineyardTheme.primary : Color.clear,
                                in: .rect(cornerRadius: 9)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.top, 8)

            TabView(selection: $tabSelection) {
                standardButtonsPage(mode: .repairs).tag(0)
                standardButtonsPage(mode: .growth).tag(1)
                customTypesPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.25), value: tabSelection)

            if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
            Button {
                Task { await save() }
            } label: {
                Group {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text("Save Pin").font(.headline)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    hasSelectedType ? VineyardTheme.primary : Color.gray.opacity(0.5),
                    in: .rect(cornerRadius: 12)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSaving || !hasSelectedType)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") { step = .location }
            }
        }
    }

    /// The EXISTING vineyard button catalogue — same stored identifiers,
    /// labels and colours as the Repairs/Growth launcher. Growth Stage
    /// buttons are excluded (they have their own authoring flow).
    private func composerButtons(mode: PinMode) -> [ButtonConfig] {
        let source = mode == .growth ? store.growthButtons : store.repairButtons
        var seen = Set<String>()
        return source
            .filter { !$0.isGrowthStageButton }
            .sorted { $0.index < $1.index }
            .filter { seen.insert("\($0.name)|\($0.color)").inserted }
    }

    private func standardButtonsPage(mode: PinMode) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(composerButtons(mode: mode)) { button in
                    let isSelected = selectedStandard?.id == button.id
                    Button {
                        selectedStandard = button
                        selectedCustom = nil
                        validationMessage = nil
                    } label: {
                        VStack(spacing: 6) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                            }
                            Text(button.name)
                                .font(.headline.weight(.heavy))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 74)
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
                                .stroke(isSelected ? Color.white : Color.black.opacity(0.10), lineWidth: isSelected ? 2 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
        }
    }

    private var customTypesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                let types = customPinService.activeTypes(vineyardId: store.selectedVineyardId)
                if types.isEmpty {
                    Text("No custom items yet — add one for actions the Repair and Growth buttons don't cover (e.g. Broken Wire, Large Divot, Check Irrigation).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(types) { type in
                    let isSelected = selectedCustom?.id == type.id
                    Button {
                        selectedCustom = type
                        selectedStandard = nil
                        validationMessage = nil
                    } label: {
                        HStack {
                            Text(type.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .background(
                            isSelected ? Color.orange : Color(.secondarySystemBackground),
                            in: .rect(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    newCustomName = ""
                    showAddCustom = true
                } label: {
                    Label("Add custom item", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VineyardTheme.primary)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 12)
        }
    }

    private func addCustomItem() {
        let name = newCustomName
        newCustomName = ""
        guard let vineyardId = store.selectedVineyardId else { return }
        Task {
            if let type = await customPinService.addType(name: name, vineyardId: vineyardId) {
                selectedCustom = type
                selectedStandard = nil
                validationMessage = nil
            } else if let message = customPinService.errorMessage {
                validationMessage = message
                customPinService.errorMessage = nil
            }
        }
    }

    // MARK: - Save

    /// Canonical side-less attachment for a manually dropped point: block by
    /// containment + nearest-row snapping. Resolved once; the same result
    /// feeds the preview label and the saved pin.
    private func resolvedAttachment(for coordinate: CLLocationCoordinate2D) -> PinAttachmentResolver.Attachment {
        let paddock = RowGuidance.paddock(for: coordinate, in: store.paddocks)
        let base = PinAttachmentResolver.resolveManual(
            coordinate: coordinate,
            operatorSide: .right, // resolver requires a side; stripped below
            paddock: paddock
        )
        // The unified composer records no Left/Right — strip the side while
        // keeping the row/snap geometry intact.
        return PinAttachmentResolver.Attachment(
            drivingRowNumber: base.drivingRowNumber,
            pinRowNumber: base.pinRowNumber,
            pinSide: nil,
            snappedCoordinate: base.snappedCoordinate,
            alongRowDistanceM: base.alongRowDistanceM,
            snappedToRow: base.snappedToRow
        )
    }

    /// Marker coordinate for the current method: original tap for point,
    /// mean of segment midpoints for rows (block centroid fallback), block
    /// centroid for block. The structured selection stays authoritative.
    private func markerCoordinate() -> (latitude: Double, longitude: Double)? {
        switch method {
        case UnifiedPinContract.scopePoint:
            guard let tappedCoordinate else { return nil }
            return (tappedCoordinate.latitude, tappedCoordinate.longitude)
        case UnifiedPinContract.scopeRow:
            guard let paddock = selectedPaddock else { return nil }
            var rowLines: [Int: (start: (latitude: Double, longitude: Double), end: (latitude: Double, longitude: Double))] = [:]
            for row in paddock.rows {
                rowLines[row.number] = (
                    start: (row.startPoint.latitude, row.startPoint.longitude),
                    end: (row.endPoint.latitude, row.endPoint.longitude)
                )
            }
            if let marker = ManualIssueContract.markerCoordinate(segments: Array(selectedSegments), rowLines: rowLines) {
                return marker
            }
            return ManualIssueContract.blockCentroid(points: paddock.polygonPoints.map { ($0.latitude, $0.longitude) })
        default:
            guard let paddock = selectedPaddock else { return nil }
            return ManualIssueContract.blockCentroid(points: paddock.polygonPoints.map { ($0.latitude, $0.longitude) })
        }
    }

    private func save() async {
        let marker = markerCoordinate()
        let canonical = ManualIssueContract.canonicalSegments(Array(selectedSegments))
        if let error = UnifiedPinContract.validationError(
            scope: method,
            hasSelectedType: hasSelectedType,
            latitude: marker?.latitude,
            longitude: marker?.longitude,
            paddockId: selectedPaddockId,
            segments: canonical
        ) {
            validationMessage = error
            return
        }
        guard let marker else {
            validationMessage = "A map location is required."
            return
        }
        isSaving = true
        defer { isSaving = false }
        customPinService.store = store

        let coordinate = CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude)
        // One-shot canonical placement for a manually dropped point; row and
        // block methods carry the explicit block with no speculated snapping.
        let attachment: PinAttachmentResolver.Attachment? =
            method == UnifiedPinContract.scopePoint ? resolvedAttachment(for: coordinate) : nil
        let containmentBlock: UUID? = method == UnifiedPinContract.scopePoint
            ? RowGuidance.paddock(for: coordinate, in: store.paddocks)?.id
            : selectedPaddockId
        let rowSegments = method == UnifiedPinContract.scopeRow ? canonical : nil

        if let button = selectedStandard {
            // Repair / Growth: the EXISTING pin create path stays
            // authoritative — never routed through a Manual Issue RPC.
            guard let pin = store.createPinFromButton(
                button: button,
                coordinate: coordinate,
                heading: nil,
                side: nil, // no Left/Right in the unified composer
                paddockId: containmentBlock,
                rowNumber: nil,
                createdBy: auth.userName,
                createdByUserId: auth.userId,
                attachment: attachment,
                locationScope: method
            ) else {
                validationMessage = "Could not create pin — no vineyard selected."
                return
            }
            if let rowSegments {
                // Structured ROW selection persists via set_pin_row_segments;
                // queued + retried until the pin insert reaches the server.
                await customPinService.queueRowSegments(pinId: pin.id, segments: rowSegments)
            }
            finishSave()
        } else if let type = selectedCustom {
            guard let vineyardId = store.selectedVineyardId else {
                validationMessage = "Could not create pin — no vineyard selected."
                return
            }
            let params = CustomPinCreateParams(
                id: UUID(),
                vineyardId: vineyardId,
                title: type.name,
                locationScope: method,
                customTypeId: type.id,
                paddockId: containmentBlock,
                notes: nil,
                latitude: marker.latitude,
                longitude: marker.longitude,
                snappedLatitude: attachment?.snappedCoordinate?.latitude,
                snappedLongitude: attachment?.snappedCoordinate?.longitude,
                drivingRowNumber: nil,
                pinRowNumber: attachment?.pinRowNumber.map(Double.init),
                alongRowDistanceM: attachment?.alongRowDistanceM,
                snappedToRow: attachment?.snappedToRow ?? false,
                clientUpdatedAt: ManualIssueTimestamp.now(),
                segments: rowSegments
            )
            let saved = await customPinService.createCustomPin(params)
            if saved {
                finishSave()
            } else if let message = customPinService.errorMessage {
                validationMessage = message
                customPinService.errorMessage = nil
            }
        }
    }

    private func finishSave() {
        dismiss()
        onSaved()
    }
}

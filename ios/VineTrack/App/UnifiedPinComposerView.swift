import SwiftUI
import MapKit
import CoreLocation

/// Unified "Manual Pin / Repair / Observation" composer (sql/170); an
/// extension of the existing pin workflow, not a separate issue system.
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
    // True once the user has explicitly picked a method — drives the
    // location-choice cards' selected state when stepping back.
    @State private var methodChosen = false

    // Location state.
    @State private var tappedCoordinate: CLLocationCoordinate2D?
    @State private var selectedPaddockId: UUID?
    @State private var selectedSegments: Set<ManualIssueSegment> = []

    // Type selection.
    @State private var selectedStandard: ButtonConfig?
    @State private var selectedCustom: CustomPinTypeRecord?
    // The Growth Stage launcher's exact E-L stage from the EXISTING picker.
    @State private var selectedGrowthStage: GrowthStage?
    @State private var showGrowthPicker = false
    @State private var showAddCustom = false
    @State private var newCustomName = ""

    @State private var validationMessage: String?
    @State private var isSaving = false

    private var selectedPaddock: Paddock? {
        store.paddocks.first { $0.id == selectedPaddockId }
    }

    private var hasSelectedType: Bool {
        selectedStandard != nil || selectedCustom != nil || selectedGrowthStage != nil
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
        .navigationTitle(UnifiedPinContract.quickActionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            customPinService.store = store
            if let vineyardId = store.selectedVineyardId {
                await customPinService.refresh(vineyardId: vineyardId)
            }
        }
        .sheet(isPresented: $showGrowthPicker) {
            // The EXISTING E-L growth-stage picker — same images, labels,
            // order and identifiers as the standard Growth pin workflow.
            // Cancelling changes nothing; no pin exists until Save Pin.
            GrowthStagePickerSheet { stage in
                selectedGrowthStage = stage
                selectedStandard = nil
                selectedCustom = nil
                validationMessage = nil
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
                    title: UnifiedPinContract.methodTitles[0],
                    subtitle: UnifiedPinContract.methodSubtitles[0],
                    icon: "mappin.and.ellipse",
                    color: VineyardTheme.primary,
                    scope: UnifiedPinContract.scopePoint
                )
                methodCard(
                    title: UnifiedPinContract.methodTitles[1],
                    subtitle: UnifiedPinContract.methodSubtitles[1],
                    icon: "rectangle.split.3x1",
                    color: VineyardTheme.leafGreen,
                    scope: UnifiedPinContract.scopeRow
                )
                methodCard(
                    title: UnifiedPinContract.methodTitles[2],
                    subtitle: UnifiedPinContract.methodSubtitles[2],
                    icon: "square.dashed",
                    color: VineyardTheme.earthBrown,
                    scope: UnifiedPinContract.scopeBlock
                )
            }
            .padding(.horizontal)
        }
    }

    /// One enlarged location-choice control — full-width, min height
    /// `UnifiedPinContract.methodButtonMinHeight` (≈ double the original card),
    /// with a clear burgundy selected state. Identical sizing on Android.
    private func methodCard(title: String, subtitle: String, icon: String, color: Color, scope: String) -> some View {
        let isSelected = methodChosen && method == scope
        return Button {
            if methodChosen && method != scope {
                // Changing the method clears location state so no stale
                // snapping/segments survive.
                tappedCoordinate = nil
                selectedPaddockId = nil
                selectedSegments = []
            }
            method = scope
            methodChosen = true
            validationMessage = nil
            step = .location
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(color, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(VineyardTheme.burgundy)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: UnifiedPinContract.methodButtonMinHeight, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? VineyardTheme.burgundy : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: location

    private var locationStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch method {
                case UnifiedPinContract.scopeRow:
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
                return tappedCoordinate == nil ? UnifiedPinContract.errorTapMap : nil
            case UnifiedPinContract.scopeRow:
                if ManualIssueContract.canonicalSegments(Array(selectedSegments)).isEmpty {
                    return UnifiedPinContract.errorSelectRow
                }
                if selectedPaddockId == nil { return UnifiedPinContract.errorRowBlock }
                return nil
            default:
                return selectedPaddockId == nil ? UnifiedPinContract.errorSelectBlock : nil
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

    /// One block with its mapped rows in the row-first selector.
    private struct RowBlockEntry: Identifiable {
        let paddock: Paddock
        let rows: [PaddockRow]
        var id: UUID { paddock.id }
    }

    /// Blocks that have mapped row geometry, sorted by name — the row-first
    /// selector lists every one of them under its block header so "Row 41"
    /// is never ambiguous across blocks.
    private var rowBlocks: [RowBlockEntry] {
        var entries: [RowBlockEntry] = []
        for paddock in store.paddocks {
            let rows = paddock.rows.sorted { $0.number < $1.number }
            if !rows.isEmpty {
                entries.append(RowBlockEntry(paddock: paddock, rows: rows))
            }
        }
        entries.sort { $0.paddock.name.lowercased() < $1.paddock.name.lowercased() }
        return entries
    }

    /// Row-first tap: the block is DERIVED from the tapped row's geometry;
    /// switching blocks starts a fresh selection.
    private func handleRowTap(blockId: UUID, tapped: Set<ManualIssueSegment>) {
        let result = UnifiedPinContract.applyRowTap(
            currentBlockId: selectedPaddockId,
            tappedBlockId: blockId,
            currentSegments: selectedSegments,
            tappedSegments: tapped
        )
        selectedPaddockId = result.blockId
        selectedSegments = result.segments
        validationMessage = nil
    }

    @ViewBuilder
    private var rowGrid: some View {
        let blocks = rowBlocks
        if blocks.isEmpty {
            Label("No mapped rows in this vineyard — use Select a block instead.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            if !selectedSegments.isEmpty, let selectedPaddock {
                Text(ManualIssueContract.rowSelectionSummary(Array(selectedSegments)))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(VineyardTheme.leafGreen)
                Text("Block: \(selectedPaddock.name) — detected from the selected row")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(blocks) { entry in
                blockRowSection(entry)
            }
        }
    }

    @ViewBuilder
    private func blockRowSection(_ entry: RowBlockEntry) -> some View {
        let inBlock = entry.paddock.id == selectedPaddockId
        Text(entry.paddock.name)
            .font(.footnote.weight(.bold))
            .foregroundStyle(inBlock && !selectedSegments.isEmpty ? VineyardTheme.leafGreen : Color.primary)
            .padding(.top, 6)
        ForEach(entry.rows) { row in
            rowLine(row, blockId: entry.paddock.id, inBlock: inBlock)
        }
    }

    private func rowLine(_ row: PaddockRow, blockId: UUID, inBlock: Bool) -> some View {
        HStack(spacing: 6) {
            let all = Set((1...4).map { ManualIssueSegment(row: row.number, segment: $0) })
            let wholeSelected = inBlock && all.isSubset(of: selectedSegments)
            Button {
                handleRowTap(blockId: blockId, tapped: all)
            } label: {
                Text("\(row.number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(wholeSelected ? Color.white : Color.primary)
                    .frame(width: 34, height: 26)
                    .background(
                        wholeSelected ? VineyardTheme.leafGreen : Color(.tertiarySystemBackground),
                        in: .rect(cornerRadius: 6)
                    )
            }
            .buttonStyle(.plain)
            ForEach(1...4, id: \.self) { quarter in
                let segment = ManualIssueSegment(row: row.number, segment: quarter)
                let isSelected = inBlock && selectedSegments.contains(segment)
                Button {
                    handleRowTap(blockId: blockId, tapped: [segment])
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
    /// labels and colours as the Repairs/Growth launcher. Growth Stage never
    /// appears here (dedupe by flag AND by name) — it has its own dedicated
    /// tile that opens the existing stage picker. Left/right launcher
    /// duplicates collapse to one tile each.
    private func composerButtons(mode: PinMode) -> [ButtonConfig] {
        let source = mode == .growth ? store.growthButtons : store.repairButtons
        var seen = Set<String>()
        return source
            .filter {
                !$0.isGrowthStageButton &&
                    $0.name.trimmingCharacters(in: .whitespaces)
                        .caseInsensitiveCompare(UnifiedPinContract.growthStageButton) != .orderedSame
            }
            .sorted { $0.index < $1.index }
            .filter { seen.insert(UnifiedPinContract.catalogueKey(name: $0.name, color: $0.color)).inserted }
    }

    /// The Growth tab's Growth Stage launcher — rendered exactly once, first,
    /// at the same tile size as the other Growth buttons. Opens the EXISTING
    /// E-L stage picker; the chosen stage saves as a normal Growth pin.
    private var growthStageTile: some View {
        Button {
            showGrowthPicker = true
        } label: {
            VStack(spacing: 6) {
                if selectedGrowthStage != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                }
                Text(UnifiedPinContract.growthStageButton)
                    .font(.headline.weight(.heavy))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                Text(selectedGrowthStage.map { "EL \($0.code)" } ?? "Pick the E-L stage")
                    .font(.caption2)
                    .opacity(0.9)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 74)
            .background(
                LinearGradient(
                    colors: [
                        Color.fromString(UnifiedPinContract.growthStagePinColor),
                        Color.fromString(UnifiedPinContract.growthStagePinColor).opacity(0.82)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: .rect(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selectedGrowthStage != nil ? Color.white : Color.black.opacity(0.10), lineWidth: selectedGrowthStage != nil ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func standardButtonsPage(mode: PinMode) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                if mode == .growth {
                    growthStageTile
                }
                ForEach(composerButtons(mode: mode)) { button in
                    let isSelected = selectedStandard?.id == button.id
                    Button {
                        selectedStandard = button
                        selectedCustom = nil
                        selectedGrowthStage = nil
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
                        selectedGrowthStage = nil
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
                selectedGrowthStage = nil
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

        if let stage = selectedGrowthStage {
            // Growth Stage: a normal Growth pin through the EXISTING
            // growth-stage create path, carrying the exact E-L identifier.
            guard let pin = store.createGrowthStagePin(
                stageCode: stage.code,
                stageDescription: stage.description,
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
                await customPinService.queueRowSegments(pinId: pin.id, segments: rowSegments)
            }
            finishSave()
        } else if let button = selectedStandard {
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

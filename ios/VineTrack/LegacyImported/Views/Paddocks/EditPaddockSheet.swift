import SwiftUI
import MapKit

struct EditPaddockSheet: View {
    let paddock: Paddock?
    @Environment(MigratedDataStore.self) private var store
    @Environment(PaddockSyncService.self) private var paddockSync
    @Environment(SystemAdminService.self) private var systemAdmin
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(\.dismiss) private var dismiss
    @State private var attemptedSafeRefetch: Bool = false
    @State private var isSafeRefetching: Bool = false
    @State private var lastSafeRefetchOutcome: String?
    @State private var name: String = ""
    @State private var polygonPoints: [CoordinatePoint] = []
    @State private var rowDirection: Double = 0
    @State private var rowCount: Int = 0
    @State private var rowWidth: Double = 2.5
    @State private var rowOffset: Double = 0
    @State private var rowStartNumber: Int = 1
    @State private var rowNumberAscending: Bool = true
    @State private var vineSpacing: Double = 1.0
    @State private var vineCountOverride: String = ""
    @State private var rowLengthOverride: String = ""
    @State private var flowPerEmitterText: String = ""
    @State private var emitterSpacingText: String = ""
    @State private var intermediatePostSpacingText: String = ""
    @State private var varietyAllocations: [PaddockVarietyAllocation] = []
    @State private var budburstDate: Date = Date()
    @State private var hasBudburstDate: Bool = false
    @State private var floweringDate: Date = Date()
    @State private var hasFloweringDate: Bool = false
    @State private var veraisonDate: Date = Date()
    @State private var hasVeraisonDate: Bool = false
    @State private var harvestDate: Date = Date()
    @State private var hasHarvestDate: Bool = false
    @State private var plantingYearText: String = ""
    @State private var calculationModeOverride: GDDCalculationMode? = nil
    @State private var resetModeOverride: GDDResetMode? = nil
    @State private var showAddVariety: Bool = false
    @State private var showBoundaryEditor: Bool = false
    @State private var showFullscreenRowConfig: Bool = false
    // Row-regeneration safety: warn before saving a row-layout change that
    // could mis-map historical pins attached to this block.
    @State private var showRowLayoutChangeConfirm: Bool = false
    @State private var varietySearch: String = ""
    @State private var isAddingCustomVariety: Bool = false
    @State private var customVarietyError: String?
    private let catalogRepository = SupabaseGrapeVarietyCatalogRepository()

    // Soil profile state — loaded from Supabase paddock_soil_profiles.
    // Edited via the shared SoilProfileEditorSheet so writes go through
    // the existing upsert RPC (matches what the Irrigation Advisor uses).
    @State private var soilProfile: BackendSoilProfile?
    @State private var isLoadingSoilProfile: Bool = false
    @State private var showSoilProfileEditor: Bool = false
    private let soilProfileRepository: any SoilProfileRepositoryProtocol = SupabaseSoilProfileRepository()

    // Danger Zone state — reference counts gate the visibility of
    // "Delete permanently"; archive is always available for an existing block.
    @State private var referenceCounts: PaddockReferenceCounts?
    @State private var isLoadingReferenceCounts: Bool = false
    @State private var referenceCountsError: String?
    @State private var showArchiveConfirm: Bool = false
    @State private var showPermanentDeleteConfirm: Bool = false
    @State private var permanentDeleteNameInput: String = ""
    @State private var isPerformingDestructiveAction: Bool = false
    @State private var destructiveActionError: String?
    private let paddockRepository: any PaddockSyncRepositoryProtocol = SupabasePaddockSyncRepository()

    private var isEditing: Bool { paddock != nil }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                boundarySection
                rowConfigSection
                if rowCount > 0 {
                    rowNumberingSection
                }
                vineSpacingSection
                phenologySection
                gddOverrideSection
                varietiesSection
                irrigationSection
                soilSection
                if polygonPoints.count > 2 && rowCount > 0 {
                    blockSummarySection
                }
                if isEditing && accessControl.canDeleteOperationalRecords {
                    dangerZoneSection
                }
            }
            .navigationTitle(isEditing ? "Edit Block" : "New Block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if hasRiskyRowLayoutChange {
                            showRowLayoutChangeConfirm = true
                        } else {
                            savePaddock()
                            dismiss()
                        }
                    }
                    .disabled(name.isEmpty)
                }
            }
            .sheet(isPresented: $showAddVariety) {
                addVarietyPickerSheet
            }
            .sheet(isPresented: $showSoilProfileEditor, onDismiss: {
                Task { await loadSoilProfile(force: true) }
            }) {
                if let pid = paddock?.id, let vid = store.selectedVineyardId {
                    SoilProfileEditorSheet(
                        vineyardId: vid,
                        paddockId: pid,
                        paddockName: name.isEmpty ? "Block" : name
                    ) { saved in
                        soilProfile = saved
                    }
                }
            }
            .fullScreenCover(isPresented: $showBoundaryEditor) {
                BoundaryMapEditor(
                    polygonPoints: $polygonPoints,
                    existingPaddocks: store.paddocks.filter { $0.id != paddock?.id && $0.polygonPoints.count > 2 }
                )
            }
            .fullScreenCover(isPresented: $showFullscreenRowConfig) {
                RowConfigMapOverlay(
                    rowDirection: $rowDirection,
                    rowCount: $rowCount,
                    rowWidth: $rowWidth,
                    rowOffset: $rowOffset,
                    rowStartNumber: $rowStartNumber,
                    rowNumberAscending: $rowNumberAscending,
                    polygonPoints: polygonPoints
                )
            }
            .onAppear {
                if let paddock {
                    name = paddock.name
                    polygonPoints = paddock.polygonPoints
                    rowDirection = paddock.rowDirection
                    rowCount = paddock.rows.count
                    rowWidth = paddock.rowWidth
                    rowOffset = paddock.rowOffset
                    vineSpacing = paddock.vineSpacing
                    if let override = paddock.vineCountOverride {
                        vineCountOverride = "\(override)"
                    }
                    if let rlOverride = paddock.rowLengthOverride {
                        rowLengthOverride = String(format: "%.0f", rlOverride)
                    }
                    if let flow = paddock.flowPerEmitter {
                        flowPerEmitterText = String(format: "%.1f", flow)
                    }
                    if let spacing = paddock.emitterSpacing {
                        emitterSpacingText = String(format: "%.2f", spacing)
                    }
                    if let postSpacing = paddock.intermediatePostSpacing {
                        intermediatePostSpacingText = String(format: "%.2f", postSpacing)
                    }
                    varietyAllocations = paddock.varietyAllocations
                    if let bd = paddock.budburstDate {
                        budburstDate = bd
                        hasBudburstDate = true
                    }
                    if let fd = paddock.floweringDate {
                        floweringDate = fd
                        hasFloweringDate = true
                    }
                    if let vd = paddock.veraisonDate {
                        veraisonDate = vd
                        hasVeraisonDate = true
                    }
                    if let hd = paddock.harvestDate {
                        harvestDate = hd
                        hasHarvestDate = true
                    }
                    calculationModeOverride = paddock.calculationModeOverride
                    resetModeOverride = paddock.resetModeOverride
                    if let py = paddock.plantingYear {
                        plantingYearText = "\(py)"
                    }
                    if let firstRow = paddock.rows.first, let lastRow = paddock.rows.last {
                        rowNumberAscending = lastRow.number >= firstRow.number
                        rowStartNumber = min(firstRow.number, lastRow.number)
                    }
                    Task { await loadSoilProfile() }
                    Task { await loadReferenceCounts() }
                }
            }
            .confirmationDialog(
                "Row layout changed",
                isPresented: $showRowLayoutChangeConfirm,
                titleVisibility: .visible
            ) {
                Button("Save changes anyway", role: .destructive) {
                    savePaddock()
                    dismiss()
                }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text(rowLayoutChangeMessage)
            }
            .confirmationDialog(
                archiveDialogTitle,
                isPresented: $showArchiveConfirm,
                titleVisibility: .visible
            ) {
                Button("Archive block", role: .destructive) { performArchive() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(archiveDialogMessage)
            }
            .alert(
                permanentDeleteDialogTitle,
                isPresented: $showPermanentDeleteConfirm
            ) {
                TextField("Type block name", text: $permanentDeleteNameInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Delete permanently", role: .destructive) {
                    performPermanentDelete()
                }
                .disabled(!permanentDeleteNameMatches)
                Button("Cancel", role: .cancel) {
                    permanentDeleteNameInput = ""
                }
            } message: {
                Text("This cannot be undone. Type \u{201C}\(paddock?.name ?? "")\u{201D} to confirm.")
            }
            .alert(
                "Action Failed",
                isPresented: Binding(
                    get: { destructiveActionError != nil },
                    set: { if !$0 { destructiveActionError = nil } }
                ),
                presenting: destructiveActionError
            ) { _ in
                Button("OK", role: .cancel) { destructiveActionError = nil }
            } message: { message in
                Text(message)
            }
        }
    }

    // MARK: - Danger Zone

    private var dangerZoneSection: some View {
        Section {
            if isLoadingReferenceCounts && referenceCounts == nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking linked records\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let counts = referenceCounts {
                if counts.isEmpty {
                    Label("No linked records — safe to delete permanently.", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Linked records found", systemImage: "link")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(counts.summaryLines.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("This block has linked records, so it cannot be permanently deleted. Archiving will remove it from active lists while keeping historical records intact.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
            } else if let err = referenceCountsError {
                Label("Couldn\u{2019}t check linked records (\(err)).", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button(role: .destructive) {
                showArchiveConfirm = true
            } label: {
                Label("Archive block", systemImage: "archivebox")
            }
            .disabled(isPerformingDestructiveAction)

            if let counts = referenceCounts, counts.isEmpty {
                Button(role: .destructive) {
                    permanentDeleteNameInput = ""
                    showPermanentDeleteConfirm = true
                } label: {
                    Label("Delete permanently", systemImage: "trash")
                }
                .disabled(isPerformingDestructiveAction)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text("Danger Zone")
            }
        } footer: {
            Text("Archive removes the block from active selectors but keeps its history. Permanent delete is only offered when no linked records remain.")
        }
    }

    private var archiveDialogTitle: String {
        "Archive \(paddock?.name ?? "block")?"
    }

    private var archiveDialogMessage: String {
        if let counts = referenceCounts, !counts.isEmpty {
            let preview = counts.summaryLines.prefix(4).joined(separator: ", ")
            return "This block has linked records (\(preview)). Archiving keeps it available for historical reports but hides it from active selectors."
        }
        return "Archiving keeps this block available for historical reports but hides it from active selectors."
    }

    private var permanentDeleteDialogTitle: String {
        "Delete \(paddock?.name ?? "block") permanently?"
    }

    private var permanentDeleteNameMatches: Bool {
        guard let name = paddock?.name else { return false }
        return permanentDeleteNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(name) == .orderedSame
    }

    private func loadReferenceCounts() async {
        guard let pid = paddock?.id else { return }
        isLoadingReferenceCounts = true
        defer { isLoadingReferenceCounts = false }
        do {
            let counts = try await paddockRepository.paddockReferenceCounts(id: pid)
            referenceCounts = counts
            referenceCountsError = nil
        } catch {
            referenceCountsError = error.localizedDescription
        }
    }

    private func performArchive() {
        guard let paddock else { return }
        isPerformingDestructiveAction = true
        store.deletePaddock(paddock.id)
        isPerformingDestructiveAction = false
        dismiss()
    }

    private func performPermanentDelete() {
        guard let paddock, permanentDeleteNameMatches else { return }
        isPerformingDestructiveAction = true
        Task {
            defer { isPerformingDestructiveAction = false }
            do {
                try await paddockRepository.hardDeletePaddock(id: paddock.id)
                store.applyRemotePaddockDelete(paddock.id)
                dismiss()
            } catch {
                destructiveActionError = error.localizedDescription
            }
        }
    }

    // MARK: - Soil profile

    private var soilSection: some View {
        Section {
            if paddock == nil {
                Text("Save this block first to set up its soil profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isLoadingSoilProfile && soilProfile == nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading soil profile\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let soil = soilProfile {
                soilProfileSummary(soil)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No soil profile set")
                        .font(.subheadline.weight(.semibold))
                    if isAustralianVineyard {
                        Text("Tip: Use \u{201C}Fetch from NSW SEED\u{201D} in the editor to estimate the soil profile from your block centroid, or set it manually.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Add a soil class, available water capacity and root depth so the Irrigation Advisor can produce soil-aware recommendations.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if paddock != nil {
                Button {
                    showSoilProfileEditor = true
                } label: {
                    Label(
                        soilProfile == nil ? "Add soil profile" : "Edit soil profile",
                        systemImage: soilProfile == nil ? "plus.circle" : "pencil.circle"
                    )
                    .foregroundStyle(VineyardTheme.info)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.down.right.fill")
                    .foregroundStyle(VineyardTheme.earthBrown)
                    .font(.caption)
                Text("Soil")
            }
        } footer: {
            Text("Soil information feeds the Irrigation Advisor. Manual edits set a manual override so NSW SEED won't silently overwrite your values.")
        }
    }

    @ViewBuilder
    private func soilProfileSummary(_ soil: BackendSoilProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Soil class") {
                Text(soilClassDisplay(soil)).foregroundStyle(.primary)
            }
            if let landscape = soil.soilLandscape, !landscape.isEmpty {
                LabeledContent("Soil landscape") { Text(landscape) }
            }
            if let code = soil.soilLandscapeCode, !code.isEmpty {
                LabeledContent("SALIS code") {
                    Text(code).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            if let asc = soil.australianSoilClassification, !asc.isEmpty {
                LabeledContent("Australian Soil Classification") { Text(asc) }
            }
            if let lsc = soil.landSoilCapability, !lsc.isEmpty {
                LabeledContent("Land and Soil Capability") {
                    if let n = soil.landSoilCapabilityClass {
                        Text("\(lsc) (class \(n))")
                    } else {
                        Text(lsc)
                    }
                }
            }
            if let awc = soil.availableWaterCapacityMmPerM, awc > 0 {
                LabeledContent("AWC") { Text(String(format: "%.0f mm/m", awc)) }
            }
            if let depth = soil.effectiveRootDepthM, depth > 0 {
                LabeledContent("Effective root depth") { Text(String(format: "%.2f m", depth)) }
            }
            if let depl = soil.managementAllowedDepletionPercent, depl > 0 {
                LabeledContent("Allowed depletion") { Text(String(format: "%.0f%%", depl)) }
            }
            if let rzc = soil.rootZoneCapacityMm {
                LabeledContent("Root-zone capacity") {
                    Text(String(format: "%.0f mm", rzc)).foregroundStyle(.secondary)
                }
            }
            if let raw = soil.readilyAvailableWaterMm {
                LabeledContent("Readily available water") {
                    Text(String(format: "%.0f mm", raw)).foregroundStyle(.secondary)
                }
            }
            HStack {
                if let conf = soil.confidence, !conf.isEmpty {
                    Text("Confidence: \(conf.capitalized)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if soil.isManualOverride {
                    Label("Manual override", systemImage: "pencil.tip")
                        .font(.caption2)
                        .foregroundStyle(VineyardTheme.info)
                } else if soil.source == "nsw_seed" {
                    Label("NSW SEED", systemImage: "square.stack.3d.down.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let notes = soil.manualNotes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func soilClassDisplay(_ soil: BackendSoilProfile) -> String {
        if let typed = soil.typedSoilClass { return typed.fallbackLabel }
        if let raw = soil.irrigationSoilClass, !raw.isEmpty { return raw }
        return "Unknown"
    }

    private var vineyardCountry: String {
        store.vineyards.first(where: { $0.id == store.selectedVineyardId })?.country ?? ""
    }

    private var isAustralianVineyard: Bool {
        let c = vineyardCountry.trimmingCharacters(in: .whitespaces).lowercased()
        return c == "au" || c == "aus" || c == "australia"
    }

    private func loadSoilProfile(force: Bool = false) async {
        guard let pid = paddock?.id else {
            soilProfile = nil
            return
        }
        if !force && soilProfile != nil { return }
        isLoadingSoilProfile = true
        defer { isLoadingSoilProfile = false }
        do {
            soilProfile = try await soilProfileRepository.fetchPaddockSoilProfile(paddockId: pid)
        } catch {
            soilProfile = nil
        }
    }

    private var nameSection: some View {
        Section("Block Name") {
            TextField("e.g. Block A", text: $name)
        }
    }

    private var boundarySection: some View {
        Section {
            Button {
                showBoundaryEditor = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Edit Boundary", systemImage: "pentagon")
                            .font(.body)
                        if polygonPoints.isEmpty {
                            Text("Tap to draw boundary on map")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(polygonPoints.count) boundary points set")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if !polygonPoints.isEmpty {
                Button("Clear Boundary", role: .destructive) {
                    polygonPoints.removeAll()
                }
                .font(.subheadline)
            }
        } header: {
            Text("Boundary")
        } footer: {
            Label("Tip: Draw block boundaries through the middle of the row gaps where possible. This helps VineTrack calculate row positions, block area and coverage more accurately.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var computedFirstRowNumber: Int {
        rowNumberAscending ? rowStartNumber : rowStartNumber + max(rowCount - 1, 0)
    }

    private var computedLastRowNumber: Int {
        rowNumberAscending ? rowStartNumber + max(rowCount - 1, 0) : rowStartNumber
    }

    private var rowConfigSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Direction")
                        .font(.subheadline)
                    Spacer()
                    Text("\(String(format: "%.1f", rowDirection))\u{00B0}")
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(VineyardTheme.info)
                }
                HStack(spacing: 12) {
                    Button {
                        rowDirection = max(0, rowDirection - 0.5)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(VineyardTheme.info)
                    }
                    .buttonStyle(.plain)

                    Slider(value: $rowDirection, in: 0...360, step: 0.5)

                    Button {
                        rowDirection = min(360, rowDirection + 0.5)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(VineyardTheme.info)
                    }
                    .buttonStyle(.plain)
                }
            }

            Stepper("Number of Rows: \(rowCount)", value: $rowCount, in: 0...500)

            VStack(alignment: .leading, spacing: 4) {
                Text("Row Width: \(rowWidth, specifier: "%.1f") m")
                    .font(.subheadline)
                Slider(value: $rowWidth, in: 0.0...4.0, step: 0.1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Shift Rows: \(rowOffset, specifier: "%.1f") m")
                        .font(.subheadline)
                    Spacer()
                    Button("Reset") { rowOffset = 0 }
                        .font(.caption)
                        .disabled(rowOffset == 0)
                }
                HStack(spacing: 12) {
                    Button {
                        rowOffset -= 0.5
                    } label: {
                        Image(systemName: "arrow.left.circle.fill")
                            .font(.title3)
                            .foregroundStyle(VineyardTheme.info)
                    }
                    .buttonStyle(.plain)

                    Slider(value: $rowOffset, in: -50...50, step: 0.25)

                    Button {
                        rowOffset += 0.5
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title3)
                            .foregroundStyle(VineyardTheme.info)
                    }
                    .buttonStyle(.plain)
                }
            }

            if polygonPoints.count > 2 {
                ZStack(alignment: .topTrailing) {
                    RowPreviewMapView(
                        polygonPoints: polygonPoints,
                        rowDirection: rowDirection,
                        rowCount: rowCount,
                        rowWidth: rowWidth,
                        rowOffset: rowOffset,
                        firstRowNumber: computedFirstRowNumber,
                        lastRowNumber: computedLastRowNumber,
                        showRowLabels: rowCount > 0
                    )
                    .frame(height: 300)
                    .clipShape(.rect(cornerRadius: 10))

                    Button {
                        showFullscreenRowConfig = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(8)
                }
            }
        } header: {
            Text("Row Configuration")
        } footer: {
            if polygonPoints.count > 2 && rowCount > 0 {
                Text("Green lines show row positions. Tap expand to configure on fullscreen map.")
            } else if polygonPoints.count < 3 {
                Text("Set a boundary first to preview rows on the map.")
            } else {
                Text("Set the compass direction, total number, and width of the rows.")
            }
        }
    }

    private var rowNumberingSection: some View {
        Section {
            Stepper("Start at: \(rowStartNumber)", value: $rowStartNumber, in: 1...9999)

            Picker("Row 1 Position", selection: $rowNumberAscending) {
                Label("Row \(rowStartNumber) on Left", systemImage: "arrow.right").tag(true)
                Label("Row \(rowStartNumber) on Right", systemImage: "arrow.left").tag(false)
            }
        } header: {
            Text("Row Numbering")
        } footer: {
            let lastNum: Int = rowStartNumber + max(rowCount - 1, 0)
            if rowNumberAscending {
                Text("Row \(rowStartNumber) (left) → Row \(lastNum) (right)")
            } else {
                Text("Row \(lastNum) (left) → Row \(rowStartNumber) (right)")
            }
        }
    }

    private var irrigationFlowPerEmitter: Double? {
        guard let val = Double(flowPerEmitterText), val > 0 else { return nil }
        return val
    }

    private var irrigationEmitterSpacing: Double? {
        guard let val = Double(emitterSpacingText), val > 0 else { return nil }
        return val
    }

    private var intermediatePostSpacingValue: Double? {
        guard let val = Double(intermediatePostSpacingText), val > 0 else { return nil }
        return val
    }

    private var irrigationSection: some View {
        Section {
            HStack {
                Text("Flow per Emitter")
                    .font(.subheadline)
                Spacer()
                TextField("0.0", text: $flowPerEmitterText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                Text("L/hr")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Emitter Spacing")
                    .font(.subheadline)
                Spacer()
                TextField("0.00", text: $emitterSpacingText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                Text("m")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Row Spacing")
                    .font(.subheadline)
                Spacer()
                if rowWidth > 0 {
                    Text(String(format: "%.2f", rowWidth))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not set")
                        .font(.subheadline.italic())
                        .foregroundStyle(.secondary)
                }
            }

            if let flow = irrigationFlowPerEmitter, let spacing = irrigationEmitterSpacing, rowWidth > 0 {
                let emittersPerHa = 10_000.0 / (rowWidth * spacing)
                let litresPerHaHr = emittersPerHa * flow
                let mlPerHaHr = litresPerHaHr / 1_000_000.0
                let mmHr = mlPerHaHr * 100.0

                Divider()

                HStack {
                    Label("Application Rate", systemImage: "ruler")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.teal)
                    Spacer()
                    Text(String(format: "%.2f mm/hr", mmHr))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.teal)
                }

                HStack {
                    Label("ML/ha/hr", systemImage: "drop.fill")
                        .font(.caption)
                        .foregroundStyle(VineyardTheme.info)
                    Spacer()
                    Text(String(format: "%.4f", mlPerHaHr))
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(VineyardTheme.info)
                }
            } else {
                Divider()
                HStack {
                    Label("Application Rate", systemImage: "ruler")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Not calculable")
                        .font(.subheadline.italic())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "drop.circle.fill")
                    .foregroundStyle(VineyardTheme.info)
                    .font(.caption)
                Text("Irrigation")
            }
        } footer: {
            Text("ML/ha/hr = (emitters per ha × flow) ÷ 1,000,000. mm/hr = ML/ha/hr × 100. Row spacing (\(String(format: "%.1f", rowWidth)) m) is used for the calculation.")
        }
    }

    private var phenologySection: some View {
        Section {
            Toggle(isOn: $hasBudburstDate) {
                Label { Text("Budburst Date Set") } icon: { GrapeLeafIcon(size: 16) }
            }
            if hasBudburstDate {
                DatePicker("Budburst", selection: $budburstDate, displayedComponents: .date)
            }

            Toggle(isOn: $hasFloweringDate) {
                Label("Flowering Date Set", systemImage: "camera.macro")
            }
            if hasFloweringDate {
                DatePicker("Flowering", selection: $floweringDate, displayedComponents: .date)
            }

            Toggle(isOn: $hasVeraisonDate) {
                Label("Veraison Date Set", systemImage: "circle.lefthalf.filled")
            }
            if hasVeraisonDate {
                DatePicker("Veraison", selection: $veraisonDate, displayedComponents: .date)
            }

            Toggle(isOn: $hasHarvestDate) {
                Label("Harvest Date Set", systemImage: "basket")
            }
            if hasHarvestDate {
                DatePicker("Harvest", selection: $harvestDate, displayedComponents: .date)
            }

            HStack {
                Label("Planting Year", systemImage: "calendar")
                Spacer()
                TextField("e.g. 2018", text: $plantingYearText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "calendar.circle.fill")
                    .foregroundStyle(VineyardTheme.leafGreen)
                    .font(.caption)
                Text("Phenology")
            }
        } footer: {
            Text("Set key phenology dates each season. Degree-day accumulation starts from the Reset Point selected below (budburst is typical for ripeness tracking).")
        }
    }

    private var gddOverrideSection: some View {
        let defaultMode = store.settings.calculationMode
        let defaultReset = store.settings.resetMode
        return Section {
            Picker(selection: $calculationModeOverride) {
                Text("Vineyard Default (\(defaultMode.shortName))").tag(GDDCalculationMode?.none)
                ForEach(GDDCalculationMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(Optional(mode))
                }
            } label: {
                Label("Calculation", systemImage: "thermometer.sun")
            }

            Picker(selection: $resetModeOverride) {
                Text("Vineyard Default (\(defaultReset.displayName))").tag(GDDResetMode?.none)
                ForEach(GDDResetMode.allCases, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.iconName).tag(Optional(mode))
                }
            } label: {
                Label("Reset Point", systemImage: "arrow.counterclockwise")
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Degree Days Override")
            }
        } footer: {
            Text("Leave on “Vineyard Default” to inherit from Vineyard Setup. Override per block if, for example, you want to track ripening from flowering on this block only.")
        }
    }

    private var availableVarieties: [GrapeVariety] {
        // NOTE: deliberately does NOT filter out varieties already present
        // in `varietyAllocations`. A block can carry the same variety more
        // than once (e.g. different clones/rootstocks of Pinot Noir), so
        // re-selecting an already-used variety must stay allowed. The only
        // dedupe here is on the master list itself (by display name) to
        // avoid showing the same master variety twice in the picker.
        let vineyardId = store.selectedVineyardId
        var seenNames = Set<String>()
        return store.grapeVarieties
            .filter { variety in
                if let vid = vineyardId, variety.vineyardId != vid { return false }
                let key = variety.name.lowercased()
                if seenNames.contains(key) { return false }
                seenNames.insert(key)
                return true
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var totalVarietyPercent: Double {
        varietyAllocations.reduce(0) { $0 + $1.percent }
    }

    private var showVarietyDiagnostics: Bool {
        systemAdmin.isSystemAdmin
            && systemAdmin.isEnabled(SystemFeatureFlagKey.showVarietyDiagnostics)
    }

    @ViewBuilder
    private func varietyDiagnostics(
        allocation: PaddockVarietyAllocation,
        resolved: PaddockVarietyResolver.Resolved
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("paddock.id     = \(paddock?.id.uuidString ?? "new")")
            Text("alloc.id       = \(allocation.id.uuidString)")
            Text("alloc.varietyId = \(allocation.varietyId.uuidString)")
            Text("alloc.name     = \(allocation.name ?? "<nil>")")
            Text("resolved.name  = \(resolved.displayName ?? "<nil>") via \(resolved.reason)")
            Text("master count   = \(store.grapeVarieties.count)")
            if let v = resolved.varietyId.flatMap({ id in store.grapeVarieties.first(where: { $0.id == id }) }) {
                Text("matched master id   = \(v.id.uuidString)")
                Text("matched master name = \(v.name)")
                Text("matched master key  = \(v.key ?? "<nil>")")
            }
            Text("last paddock sync = \(paddockSync.lastSyncDate?.ISO8601Format() ?? "<nil>")")
            if isSafeRefetching {
                Text("safe-refetch: in progress…")
            } else if let outcome = lastSafeRefetchOutcome {
                Text("safe-refetch: \(outcome)")
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.top, 2)
        .textSelection(.enabled)
    }

    private var varietiesSection: some View {
        Section {
            ForEach(varietyAllocations) { allocation in
                VStack(alignment: .leading, spacing: 8) {
                    let resolved = PaddockVarietyResolver.resolve(
                        allocation: allocation,
                        varieties: store.grapeVarieties
                    )
                    let variety = resolved.varietyId.flatMap { store.grapeVariety(for: $0) }
                    let nameSnapshot = allocation.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayName: String = resolved.displayName
                        ?? (nameSnapshot.flatMap { $0.isEmpty ? nil : $0 })
                        ?? "Unknown"
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName)
                                .font(.subheadline.weight(.semibold))
                            if let v = variety {
                                Text("Optimal: \(Int(v.optimalGDD)) GDD")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if displayName != "Unknown" {
                                Text("Not in master list — add in Settings → Grape Varieties")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        TextField("0", value: binding(for: allocation.id), format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        Text("%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            varietyAllocations.removeAll { $0.id == allocation.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Clone")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            TextField("Optional", text: cloneBinding(for: allocation.id))
                                .font(.subheadline)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                        }
                        HStack(spacing: 8) {
                            Text("Rootstock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .leading)
                            TextField("Optional", text: rootstockBinding(for: allocation.id))
                                .font(.subheadline)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                        }
                        Text("Optional reference only")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let paddock {
                        BlockRipenessChip(paddockId: paddock.id, varietyId: allocation.varietyId)
                    }
                    if showVarietyDiagnostics {
                        varietyDiagnostics(allocation: allocation, resolved: resolved)
                    }
                }
                .task {
                    // Safe repair fallback: if this allocation has no usable
                    // name snapshot AND the resolver can't find anything,
                    // force-refresh this paddock from Supabase once so we
                    // pick up any server-side canonicalisation that the
                    // local cache missed.
                    await maybeSafeRefetchPaddock(allocation: allocation)
                }
            }

            Button {
                showAddVariety = true
            } label: {
                Label("Add Variety", systemImage: "plus.circle")
                    .foregroundStyle(VineyardTheme.info)
            }
        } header: {
            HStack(spacing: 6) {
                GrapeLeafIcon(size: 14, color: VineyardTheme.leafGreen)
                Text("Grape Varieties")
                Spacer()
                if !varietyAllocations.isEmpty {
                    Text("Total: \(Int(totalVarietyPercent))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(abs(totalVarietyPercent - 100) < 0.5 ? VineyardTheme.leafGreen : .orange)
                }
            }
        } footer: {
            if varietyAllocations.isEmpty {
                Text("Add varieties planted in this block. Manage the master list in Settings → Vineyard Setup → Grape Varieties.")
            } else if abs(totalVarietyPercent - 100) >= 0.5 {
                Text("Percentages should total 100%. Currently: \(Int(totalVarietyPercent))%.")
                    .foregroundStyle(.orange)
            } else {
                Text("Percentages total 100%.")
            }
        }
    }

    private var filteredAvailableVarieties: [GrapeVariety] {
        let query = varietySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return availableVarieties }
        return availableVarieties.filter { v in
            v.name.localizedCaseInsensitiveContains(query)
        }
    }

    /// Built-in catalog entries that match the current search term but are
    /// not already in the vineyard's master list (so the user can pull a
    /// newly-shipped built-in into their picker without an admin step).
    private var matchingBuiltInSuggestions: [BuiltInGrapeVarietyCatalog.Entry] {
        let query = varietySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let masterKeys = Set(store.grapeVarieties.compactMap { $0.key })
        let masterCanonical = Set(store.grapeVarieties.map { BuiltInGrapeVarietyCatalog.canonical($0.name) })
        return BuiltInGrapeVarietyCatalog.entries.filter { e in
            if masterKeys.contains(e.key) { return false }
            if masterCanonical.contains(BuiltInGrapeVarietyCatalog.canonical(e.name)) { return false }
            if e.name.localizedCaseInsensitiveContains(query) { return true }
            return e.aliases.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var trimmedVarietySearch: String {
        varietySearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canOfferCustomAdd: Bool {
        let q = trimmedVarietySearch
        guard !q.isEmpty else { return false }
        if BuiltInGrapeVarietyCatalog.entry(matching: q) != nil { return false }
        let canonical = BuiltInGrapeVarietyCatalog.canonical(q)
        let alreadyInMaster = store.grapeVarieties.contains { BuiltInGrapeVarietyCatalog.canonical($0.name) == canonical }
        return !alreadyInMaster
    }

    @ViewBuilder
    private var addVarietyPickerSheet: some View {
        NavigationStack {
            List {
                if !filteredAvailableVarieties.isEmpty {
                    Section {
                        ForEach(filteredAvailableVarieties) { variety in
                            Button {
                                appendAllocation(for: variety)
                            } label: {
                                varietyPickerRow(
                                    title: variety.name,
                                    subtitle: "Optimal: \(Int(variety.optimalGDD)) GDD",
                                    systemImage: "plus.circle"
                                )
                            }
                        }
                    }
                }

                if !matchingBuiltInSuggestions.isEmpty {
                    Section("Add from catalogue") {
                        ForEach(matchingBuiltInSuggestions, id: \.key) { entry in
                            Button {
                                addBuiltInFromCatalog(entry: entry)
                            } label: {
                                varietyPickerRow(
                                    title: entry.name,
                                    subtitle: "Catalogue · Optimal: \(Int(entry.optimalGDD)) GDD",
                                    systemImage: "plus.circle.dashed"
                                )
                            }
                        }
                    }
                }

                if canOfferCustomAdd {
                    Section {
                        Button {
                            Task { await addCustomVariety(named: trimmedVarietySearch) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add “\(trimmedVarietySearch)” as custom variety")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(VineyardTheme.info)
                                    Text("Saved to this vineyard with a stable key for sync.")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isAddingCustomVariety {
                                    ProgressView()
                                } else {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(VineyardTheme.info)
                                }
                            }
                        }
                        .disabled(isAddingCustomVariety)
                    } footer: {
                        if let err = customVarietyError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        } else {
                            Text("Can't find it? Add it as a custom variety. It will sync to this vineyard on iOS and Lovable.")
                        }
                    }
                }

                if filteredAvailableVarieties.isEmpty && matchingBuiltInSuggestions.isEmpty && !canOfferCustomAdd {
                    Section {
                        Text(trimmedVarietySearch.isEmpty
                             ? "No varieties in your vineyard list yet. Search to add one from the catalogue or as a custom variety."
                             : "No matches.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add Variety")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $varietySearch, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search varieties")
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showAddVariety = false
                        varietySearch = ""
                        customVarietyError = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func varietyPickerRow(title: String, subtitle: String, systemImage: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: systemImage)
                .foregroundStyle(VineyardTheme.info)
        }
    }

    private func appendAllocation(for variety: GrapeVariety) {
        let remaining = max(0, 100 - totalVarietyPercent)
        let suggested = varietyAllocations.isEmpty ? 100.0 : remaining
        // Always stamp a stable key + name snapshot so the allocation
        // stays resolvable across devices, app resets, and id drift.
        let stableKey: String? = {
            if let k = variety.key, !k.isEmpty { return k }
            return BuiltInGrapeVarietyCatalog.entry(matching: variety.name)?.key
        }()
        varietyAllocations.append(
            PaddockVarietyAllocation(
                varietyId: variety.id,
                percent: suggested,
                name: variety.name,
                varietyKey: stableKey
            )
        )
        showAddVariety = false
        varietySearch = ""
        customVarietyError = nil
    }

    /// Pull a built-in catalog entry into the vineyard's master list
    /// (using its deterministic id + stable key) and immediately append
    /// it to this block's allocations.
    private func addBuiltInFromCatalog(entry: BuiltInGrapeVarietyCatalog.Entry) {
        guard let vid = store.selectedVineyardId else { return }
        let determinedId = GrapeVariety.deterministicID(vineyardId: vid, key: entry.key)
        if let existing = store.grapeVarieties.first(where: { $0.id == determinedId || $0.key == entry.key }) {
            appendAllocation(for: existing)
            return
        }
        let new = GrapeVariety(
            id: determinedId,
            vineyardId: vid,
            name: entry.name,
            optimalGDD: entry.optimalGDD,
            isBuiltIn: true,
            key: entry.key
        )
        store.addGrapeVariety(new)
        appendAllocation(for: new)
    }

    /// Create a vineyard-scoped custom variety via the shared catalogue
    /// RPC, mirror it into the local master list with the returned stable
    /// `custom:<vineyardId>:<slug>` key, then append the allocation.
    private func addCustomVariety(named raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAddingCustomVariety else { return }
        customVarietyError = nil
        isAddingCustomVariety = true
        defer { isAddingCustomVariety = false }

        guard let vid = store.selectedVineyardId else {
            // No vineyard selected — fall back to local-only add so the
            // user can keep working. Will reconcile on next sync.
            let new = GrapeVariety(name: trimmed, optimalGDD: 1400)
            store.addGrapeVariety(new)
            appendAllocation(for: new)
            return
        }

        do {
            let row = try await catalogRepository.upsertVineyardVariety(
                vineyardId: vid,
                key: nil,
                displayName: trimmed,
                optimalGDDOverride: nil,
                isActive: true
            )
            let new = GrapeVariety(
                vineyardId: vid,
                name: row.displayName,
                optimalGDD: row.optimalGDDOverride ?? 1400,
                isBuiltIn: false,
                key: row.varietyKey
            )
            store.addGrapeVariety(new)
            appendAllocation(for: new)
        } catch {
            // Degrade gracefully: add locally so the user isn't blocked.
            let new = GrapeVariety(name: trimmed, optimalGDD: 1400)
            store.addGrapeVariety(new)
            appendAllocation(for: new)
            customVarietyError = "Saved locally; couldn't reach catalogue server."
        }
    }

    /// Trigger a one-shot Supabase re-fetch of the current paddock when a
    /// variety allocation cannot be resolved locally and has no name
    /// snapshot to fall back on. Idempotent per sheet presentation.
    private func maybeSafeRefetchPaddock(
        allocation: PaddockVarietyAllocation
    ) async {
        guard !attemptedSafeRefetch else { return }
        guard let paddock else { return }
        let resolved = PaddockVarietyResolver.resolve(
            allocation: allocation,
            varieties: store.grapeVarieties
        )
        let nameMissing = (allocation.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard nameMissing, resolved.reason == "no-match" else { return }
        attemptedSafeRefetch = true
        isSafeRefetching = true
        let vineyardId = paddock.vineyardId
        let ok = await paddockSync.refreshPaddock(id: paddock.id, vineyardId: vineyardId)
        isSafeRefetching = false
        lastSafeRefetchOutcome = ok ? "applied server row" : "failed / no remote row"
        if ok, let refreshed = store.paddocks.first(where: { $0.id == paddock.id }) {
            // Replay onAppear's allocation hydration so the form reflects
            // the freshly pulled server data.
            varietyAllocations = refreshed.varietyAllocations
        }
    }

    private func binding(for allocationId: UUID) -> Binding<Double> {
        Binding(
            get: { varietyAllocations.first(where: { $0.id == allocationId })?.percent ?? 0 },
            set: { newValue in
                if let index = varietyAllocations.firstIndex(where: { $0.id == allocationId }) {
                    varietyAllocations[index].percent = newValue
                }
            }
        )
    }

    /// Text binding for the optional, reference-only clone field. Blank
    /// input stores nil so we never persist empty strings.
    private func cloneBinding(for allocationId: UUID) -> Binding<String> {
        Binding(
            get: { varietyAllocations.first(where: { $0.id == allocationId })?.clone ?? "" },
            set: { newValue in
                if let index = varietyAllocations.firstIndex(where: { $0.id == allocationId }) {
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    varietyAllocations[index].clone = trimmed.isEmpty ? nil : trimmed
                }
            }
        )
    }

    /// Text binding for the optional, reference-only rootstock field.
    private func rootstockBinding(for allocationId: UUID) -> Binding<String> {
        Binding(
            get: { varietyAllocations.first(where: { $0.id == allocationId })?.rootstock ?? "" },
            set: { newValue in
                if let index = varietyAllocations.firstIndex(where: { $0.id == allocationId }) {
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    varietyAllocations[index].rootstock = trimmed.isEmpty ? nil : trimmed
                }
            }
        )
    }

    private var vineSpacingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Vine Spacing: \(vineSpacing, specifier: "%.2f") m")
                    .font(.subheadline)
                Slider(value: $vineSpacing, in: 0.5...3.0, step: 0.05)
            }

            HStack {
                Text("Intermediate Post Spacing")
                    .font(.subheadline)
                Spacer()
                TextField("0.00", text: $intermediatePostSpacingText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                Text("m")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let spacing = intermediatePostSpacingValue, spacing > 0 {
                let total = paddock?.effectiveTotalRowLength ?? 0
                let rowCountValue = max(rowCount, 0)
                let rawPosts = Int(total / spacing)
                let posts = max(0, rawPosts - 2 * rowCountValue)
                if total > 0 {
                    HStack {
                        Label("Intermediate Posts", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.subheadline)
                            .foregroundStyle(VineyardTheme.earthBrown)
                        Spacer()
                        Text("\(posts)")
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .foregroundStyle(VineyardTheme.earthBrown)
                    }
                }
            }
        } header: {
            Text("Vine & Trellis Spacing")
        } footer: {
            Text("Vine Spacing is used to estimate vine count. Intermediate Post Spacing is the distance (m) between trellis posts inside a row, excluding the two end posts per row.")
        }
    }

    private var blockSummarySection: some View {
        let polygonCoords = polygonPoints.map { $0.coordinate }
        let lines = calculateRowLines(
            polygonCoords: polygonCoords,
            direction: rowDirection,
            count: max(rowCount, 0),
            width: rowWidth,
            offset: rowOffset
        )
        let mPerDegLat = 111_320.0
        let centroidLat = polygonPoints.isEmpty ? 0 : polygonPoints.map(\.latitude).reduce(0, +) / Double(polygonPoints.count)
        let mPerDegLon = 111_320.0 * cos(centroidLat * .pi / 180.0)
        let totalLength = lines.reduce(0.0) { total, line in
            let dLat = (line.end.latitude - line.start.latitude) * mPerDegLat
            let dLon = (line.end.longitude - line.start.longitude) * mPerDegLon
            return total + sqrt(dLat * dLat + dLon * dLon)
        }
        let effectiveRowLength = Double(rowLengthOverride) ?? totalLength
        let estimatedVines = vineSpacing > 0 ? Int(effectiveRowLength / vineSpacing) : 0
        let displayVines = Int(vineCountOverride) ?? estimatedVines

        return Section {
            HStack {
                Text("Calculated Row Length")
                    .font(.subheadline)
                Spacer()
                Text("\(String(format: "%.0f", totalLength)) m")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Estimated Vines")
                    .font(.subheadline)
                Spacer()
                Text("\(estimatedVines)")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(VineyardTheme.info)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Calculation Overrides")
                    .font(.subheadline.weight(.semibold))

                Label("Used for water usage & yield estimates only — does not affect trip path tracking.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Row Length")
                        .font(.subheadline)
                    Spacer()
                    TextField("\(String(format: "%.0f", totalLength))", text: $rowLengthOverride)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    Text("m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Vine Count")
                        .font(.subheadline)
                    Spacer()
                    TextField("\(estimatedVines)", text: $vineCountOverride)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                }

                if !rowLengthOverride.isEmpty || !vineCountOverride.isEmpty {
                    HStack {
                        Label("Manual override active", systemImage: "pencil.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Reset All") {
                            rowLengthOverride = ""
                            vineCountOverride = ""
                        }
                        .font(.caption)
                    }
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(VineyardTheme.info)
                    .font(.caption)
                Text("Block Summary")
            }
        } footer: {
            Text("Row length and vine count are auto-calculated from boundary geometry. Override values here for more accurate water usage and yield calculations — trip path tracking always uses the mapped row geometry.")
        }
    }

    // MARK: - Row-regeneration safety

    /// Number of historical pins on this block that hold row-attachment data
    /// (`rowNumber`, `pinRowNumber`, or `alongRowDistanceM`). These are the
    /// pins that a row-layout change could mis-map.
    private var affectedPinCount: Int {
        guard let pid = paddock?.id else { return 0 }
        return store.pins.filter { pin in
            pin.paddockId == pid &&
            (pin.rowNumber != nil || pin.pinRowNumber != nil || pin.alongRowDistanceM != nil)
        }.count
    }

    /// True when the row layout (count, start number, direction, spacing, or
    /// orientation) differs from the saved block. Used to decide whether the
    /// pin-safety warning is relevant.
    private var rowLayoutDidChange: Bool {
        guard let paddock else { return false }
        let originalCount = paddock.rows.count
        let originalStart: Int
        let originalAscending: Bool
        if let first = paddock.rows.first, let last = paddock.rows.last {
            originalStart = min(first.number, last.number)
            originalAscending = last.number >= first.number
        } else {
            originalStart = 1
            originalAscending = true
        }
        if rowCount != originalCount { return true }
        if rowStartNumber != originalStart { return true }
        if rowNumberAscending != originalAscending { return true }
        if abs(rowWidth - paddock.rowWidth) > 0.0001 { return true }
        if abs(rowOffset - paddock.rowOffset) > 0.0001 { return true }
        if abs(rowDirection - paddock.rowDirection) > 0.0001 { return true }
        return false
    }

    /// Only warn when editing an existing block, the layout changed, and there
    /// are pins that could be affected.
    private var hasRiskyRowLayoutChange: Bool {
        isEditing && rowLayoutDidChange && affectedPinCount > 0
    }

    private var rowLayoutChangeMessage: String {
        let count = affectedPinCount
        let pinText = count == 1 ? "1 existing pin" : "\(count) existing pins"
        return "Changing the row layout may affect \(pinText) attached to this block. Historical pins will keep their stored row number and distance, but may need to be reviewed or re-snapped."
    }

    private func savePaddock() {
        let polygonCoords = polygonPoints.map { $0.coordinate }
        let lines = calculateRowLines(
            polygonCoords: polygonCoords,
            direction: rowDirection,
            count: max(rowCount, 0),
            width: rowWidth,
            offset: rowOffset
        )

        let rows: [PaddockRow] = (0..<max(rowCount, 0)).map { index in
            let number: Int = rowNumberAscending ? rowStartNumber + index : rowStartNumber + (rowCount - 1 - index)
            let startCoord: CoordinatePoint
            let endCoord: CoordinatePoint
            if index < lines.count {
                startCoord = CoordinatePoint(coordinate: lines[index].start)
                endCoord = CoordinatePoint(coordinate: lines[index].end)
            } else {
                startCoord = CoordinatePoint(latitude: 0, longitude: 0)
                endCoord = CoordinatePoint(latitude: 0, longitude: 0)
            }
            return PaddockRow(
                number: number,
                startPoint: startCoord,
                endPoint: endCoord
            )
        }

        // Backfill name snapshots so allocations remain resolvable on
        // devices/portals where the managed grape-variety id list differs.
        let allocationsToSave = PaddockVarietyResolver.backfillNames(
            varietyAllocations,
            varieties: store.grapeVarieties
        )
        func parsedPlantingYear() -> Int? {
            let trimmed = plantingYearText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Strip non-digit chars so accidental whitespace or stray characters don’t
            // turn a valid year like "2018 " into nil.
            let digits = trimmed.filter { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }
        if var existing = paddock {
            existing.name = name
            existing.polygonPoints = polygonPoints
            existing.rowDirection = rowDirection
            existing.rows = rows
            existing.rowWidth = rowWidth
            existing.rowOffset = rowOffset
            existing.vineSpacing = vineSpacing
            existing.vineCountOverride = Int(vineCountOverride)
            existing.rowLengthOverride = Double(rowLengthOverride)
            existing.flowPerEmitter = irrigationFlowPerEmitter
            existing.emitterSpacing = irrigationEmitterSpacing
            existing.intermediatePostSpacing = intermediatePostSpacingValue
            existing.varietyAllocations = allocationsToSave
            existing.budburstDate = hasBudburstDate ? budburstDate : nil
            existing.floweringDate = hasFloweringDate ? floweringDate : nil
            existing.veraisonDate = hasVeraisonDate ? veraisonDate : nil
            existing.harvestDate = hasHarvestDate ? harvestDate : nil
            existing.plantingYear = parsedPlantingYear()
            existing.calculationModeOverride = calculationModeOverride
            existing.resetModeOverride = resetModeOverride
            store.updatePaddock(existing)
        } else {
            let newPaddock = Paddock(
                name: name,
                polygonPoints: polygonPoints,
                rows: rows,
                rowDirection: rowDirection,
                rowWidth: rowWidth,
                rowOffset: rowOffset,
                vineSpacing: vineSpacing,
                vineCountOverride: Int(vineCountOverride),
                rowLengthOverride: Double(rowLengthOverride),
                flowPerEmitter: irrigationFlowPerEmitter,
                emitterSpacing: irrigationEmitterSpacing,
                intermediatePostSpacing: intermediatePostSpacingValue,
                varietyAllocations: allocationsToSave,
                budburstDate: hasBudburstDate ? budburstDate : nil,
                floweringDate: hasFloweringDate ? floweringDate : nil,
                veraisonDate: hasVeraisonDate ? veraisonDate : nil,
                harvestDate: hasHarvestDate ? harvestDate : nil,
                plantingYear: parsedPlantingYear(),
                calculationModeOverride: calculationModeOverride,
                resetModeOverride: resetModeOverride
            )
            store.addPaddock(newPaddock)
        }
    }
}

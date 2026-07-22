import SwiftUI

/// Restored Maintenance Start Trip sheet styled to match the original app:
/// hero header, block selector card, tracking pattern grid, starting row /
/// direction options, operator field, and a prominent Start button.
///
/// Backend-neutral: uses `MigratedDataStore` and `TripTrackingService` only.
struct StartTripSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(TripTrackingService.self) private var tracking
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(VineyardTripFunctionService.self) private var tripFunctionService
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPaddockIds: Set<UUID> = []
    @State private var trackingPattern: TrackingPattern = .sequential
    /// Selected start path (e.g. 0.5, 1.5, … N+0.5). Path X.5 sits between rows X and X+1.
    /// Path 0.5 is before row 1; path (totalRows+0.5) is after the last row.
    @State private var startPath: Double = 0.5
    /// Direction selector for traversal. true = higher rows first (ascending),
    /// false = lower rows first (descending). Replaces the old "Reverse direction" toggle.
    @State private var directionHigherFirst: Bool = true
    @State private var personName: String = ""
    /// Vineyard machine selection for the new trip. Persists as
    /// `trips.machine_id` (preferred) plus `trips.tractor_id` for tractor-backed
    /// machines, so fuel cost estimates can be calculated downstream
    /// (TripCostService). Optional — if left unset, the trip continues without
    /// fuel costing.
    @State private var selectedMachineId: UUID?
    /// Optional engine-hour meter reading at trip start. Free text so it can be
    /// left blank; parsed to `Double` on start. Persists as
    /// `trips.start_engine_hours` for fuel allocation (Phase 3).
    @State private var startEngineHoursText: String = ""
    @State private var showPaddockPicker: Bool = false
    /// Stable selection key for the trip function:
    ///   - Built-in: the `TripFunction` raw value (e.g. "seeding").
    ///   - Custom:   "custom:<slug>" matching `vineyard_trip_functions.slug`.
    @State private var selectedFunctionKey: String = TripFunction.slashing.rawValue
    @State private var customTitle: String = ""
    @State private var showAddCustomFunction: Bool = false

    // Seeding Details (only used when selectedFunction == .seeding).
    @State private var seedingExpanded: Bool = false
    /// Independent enable/disable toggles for each seed box. A box's settings
    /// are only saved when its toggle is on. At least one box must be enabled
    /// to start a Seeding trip.
    @State private var useFrontBox: Bool = true
    @State private var useBackBox: Bool = true
    @State private var seedFrontMix: String = ""
    @State private var seedBackMix: String = ""
    @State private var seedFrontRate: String = ""
    @State private var seedBackRate: String = ""
    @State private var sowingDepth: String = ""
    @State private var seedFrontShutter: String = "3/4"
    @State private var seedFrontFlap: String = "1"
    @State private var seedFrontWheel: String = "N"
    @State private var seedFrontVolume: String = ""
    @State private var seedFrontGearbox: String = ""
    @State private var seedBackShutter: String = "Full"
    @State private var seedBackFlap: String = "3"
    @State private var seedBackWheel: String = "F"
    @State private var seedBackVolume: String = ""
    @State private var seedBackGearbox: String = ""
    @State private var mixLines: [SeedingMixLine] = []
    /// Short note shown after the operator copies setup from a previous
    /// seeding job, e.g. "Copied setup from Seeding — Block A — 6 May 2026".
    /// Cleared when the operator manually edits the form.
    @State private var copiedFromNote: String?
    /// Set to true when the operator taps Copy and no previous seeding job
    /// with details was found, so we can show a friendly inline message.
    @State private var copyMissing: Bool = false
    /// True when a previous seeding trip exists but has no genuinely useful
    /// operator-entered values (only default shutter/flap/wheel etc.).
    @State private var copyFoundButEmpty: Bool = false
    /// Multi-line, human-readable diagnostic explaining the last copy attempt.
    /// Populated every time the operator taps "Copy from previous seeding
    /// job" so we can debug lookup failures in the field.
    @State private var copyDiagnostics: String?
    /// Toggle to expose the raw diagnostic block below the copy button.
    @State private var showCopyDiagnostics: Bool = false

    private var selectedPaddocks: [Paddock] {
        store.paddocks
            .filter { selectedPaddockIds.contains($0.id) }
            .sorted(by: Self.rowOrderSort)
    }

    /// Sort blocks by lowest row number first, then by name. Blocks without
    /// row geometry fall to the end (compared by name).
    static func rowOrderSort(_ a: Paddock, _ b: Paddock) -> Bool {
        let aMin = a.rows.map(\.number).min()
        let bMin = b.rows.map(\.number).min()
        switch (aMin, bMin) {
        case let (l?, r?):
            if l != r { return l < r }
            return a.name.lowercased() < b.name.lowercased()
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.name.lowercased() < b.name.lowercased()
        }
    }

    /// Display string for a block's row range, e.g. "Rows 1–24" or
    /// "Rows not configured" if no row geometry exists.
    static func rowRangeLabel(for paddock: Paddock) -> String {
        let numbers = paddock.rows.map(\.number)
        guard let lo = numbers.min(), let hi = numbers.max() else {
            return "Rows not configured"
        }
        if lo == hi { return "Row \(lo)" }
        return "Rows \(lo)–\(hi)"
    }

    /// Single-paddock convenience used for row guidance / starting row UI.
    /// Only non-nil when exactly one block is selected.
    private var singleSelectedPaddock: Paddock? {
        guard selectedPaddocks.count == 1 else { return nil }
        return selectedPaddocks.first
    }

    /// Whether any selected block has row geometry. Used to gate the
    /// row-guidance sections.
    private var hasAnyRowGeometry: Bool {
        selectedPaddocks.contains { !$0.rows.isEmpty }
    }

    /// Combined total row count across every selected block. This drives the
    /// global path range for multi-block trips.
    private var combinedTotalRows: Int {
        selectedPaddocks.reduce(0) { $0 + $1.rows.count }
    }

    /// Sorted, de-duplicated list of actual row numbers contributed by the
    /// selection. Preserves each paddock's real `row.number` values so the
    /// Start Path selector reflects the real vineyard numbering (e.g. a single
    /// block with rows 69–108 shows paths 68.5–108.5, not 0.5–40.5).
    private var selectedRowNumbers: [Int] {
        var set = Set<Int>()
        for paddock in selectedPaddocks {
            for row in paddock.rows { set.insert(row.number) }
        }
        return set.sorted()
    }

    /// Smallest actual row number in the selection (defaults to 1 if none).
    private var minSelectedRow: Int {
        selectedRowNumbers.first ?? 1
    }

    /// Largest actual row number in the selection (defaults to 0 if none).
    private var maxSelectedRow: Int {
        selectedRowNumbers.last ?? 0
    }

    /// Available start paths across the full selection. For each actual row
    /// number N we contribute paths N-0.5 (before/between) and N+0.5 (after).
    /// Path X.5 sits between rows X and X+1; path (minRow-0.5) is before the
    /// first row; path (maxRow+0.5) is after the last row.
    private var availablePaths: [Double] {
        let numbers = selectedRowNumbers
        guard !numbers.isEmpty else { return [0.5] }
        var set = Set<Double>()
        for n in numbers {
            set.insert(Double(n) - 0.5)
            set.insert(Double(n) + 0.5)
        }
        return set.sorted()
    }

    /// Combined row range label: "Rows 69–108".
    private var combinedRangeLabel: String {
        guard !selectedRowNumbers.isEmpty else { return "Rows not configured" }
        let lo = minSelectedRow
        let hi = maxSelectedRow
        if lo == hi { return "Row \(lo)" }
        return "Rows \(lo)–\(hi)"
    }

    private var combinedPathsLabel: String {
        guard let lo = availablePaths.first, let hi = availablePaths.last else { return "" }
        return "Paths \(formatPath(lo))–\(formatPath(hi))"
    }

    private var totalAreaHectares: Double {
        selectedPaddocks.reduce(0) { $0 + $1.areaHectares }
    }

    private var totalRowsAcrossSelection: Int {
        selectedPaddocks.reduce(0) { $0 + $1.rows.count }
    }

    private var totalVinesAcrossSelection: Int {
        selectedPaddocks.reduce(0) { $0 + $1.effectiveVineCount }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    heroHeader
                    blockSection
                    functionSection
                    if isSeedingSelected {
                        seedingDetailsSection
                    }
                    patternSection
                    if hasAnyRowGeometry, trackingPattern != .freeDrive {
                        directionSection
                        sequencePreviewSection
                    }
                    if trackingPattern == .freeDrive {
                        freeDriveInfoSection
                    }
                    machineSection
                    operatorSection
                    if let error = tracking.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                    startButton
                        .padding(.top, 4)
                    Spacer(minLength: 24)
                }
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Start Maintenance Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if personName.isEmpty, let name = auth.userName {
                    personName = name
                }
                if selectedMachineId == nil {
                    selectedMachineId = defaultMachineId
                }
                // Intentionally do NOT pre-select a block. Operators have
                // accidentally started trips in the wrong block when one
                // appears auto-selected. Force them to choose explicitly.
                clampStartPath()
                if let vineyardId = store.selectedVineyardId,
                   tripFunctionService.loadedVineyardId != vineyardId {
                    Task { await tripFunctionService.refresh(vineyardId: vineyardId) }
                }
            }
            .onChange(of: selectedPaddockIds) { _, _ in
                clampStartPath()
            }
            .sheet(isPresented: $showPaddockPicker) {
                MultiPaddockPickerSheet(selectedIds: $selectedPaddockIds)
            }
            .sheet(isPresented: $showAddCustomFunction) {
                AddCustomTripFunctionSheet { newFn in
                    selectedFunctionKey = "custom:\(newFn.slug)"
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Hero

    private var heroHeader: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(VineyardTheme.earthBrown.opacity(0.15))
                    .frame(width: 76, height: 76)
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(VineyardTheme.earthBrown)
            }
            VStack(spacing: 4) {
                Text("Maintenance Trip")
                    .font(.title2.bold())
                Text("Track a general vineyard trip with row guidance")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal)
    }

    // MARK: Block

    private var blockSection: some View {
        sectionContainer(title: "Block", icon: "square.grid.2x2.fill", tint: VineyardTheme.leafGreen) {
            Button {
                showPaddockPicker = true
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(VineyardTheme.leafGreen.opacity(0.15))
                            .frame(width: 44, height: 44)
                        GrapeLeafIcon(size: 22, color: VineyardTheme.leafGreen)
                    }
                    if let paddock = singleSelectedPaddock {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(paddock.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            blockMetaLine(for: paddock)
                        }
                    } else if !selectedPaddocks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(selectedPaddocks.count) blocks selected")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(selectedPaddocks.map(\.name).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No blocks selected")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Tap to choose one or more blocks (optional)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            if let paddock = singleSelectedPaddock, !paddock.rows.isEmpty {
                blockStatsRow(for: paddock)
            } else if selectedPaddocks.count > 1 {
                multiBlockStatsRow
            }
        }
    }

    private var multiBlockStatsRow: some View {
        HStack(spacing: 0) {
            statCell(value: "\(selectedPaddocks.count)", label: "Blocks")
            Divider().frame(height: 32)
            statCell(value: String(format: "%.2f", totalAreaHectares), label: "Hectares")
            Divider().frame(height: 32)
            statCell(value: "\(totalRowsAcrossSelection)", label: rowsStatLabel)
            Divider().frame(height: 32)
            statCell(value: "\(totalVinesAcrossSelection)", label: "Vines")
        }
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    /// Stat-cell label for the combined Rows column. Falls back to "Rows" when
    /// no row geometry is available across the selection.
    private var rowsStatLabel: String {
        guard !selectedRowNumbers.isEmpty else { return "Rows" }
        return Self.compactRowRangeLabel(selectedRowNumbers)
    }

    /// Build a compact row-range label from a sorted list of actual row numbers.
    /// Contiguous: "Rows 69\u{2013}108". Non-contiguous (small): "Rows 1\u{2013}14, 69\u{2013}108".
    /// Non-contiguous (many segments): collapse to overall span "Rows lo\u{2013}hi".
    static func compactRowRangeLabel(_ numbers: [Int]) -> String {
        guard let lo = numbers.first, let hi = numbers.last else { return "Rows" }
        // Build contiguous segments.
        var segments: [(Int, Int)] = []
        var segStart = lo
        var prev = lo
        for n in numbers.dropFirst() {
            if n == prev + 1 {
                prev = n
            } else {
                segments.append((segStart, prev))
                segStart = n
                prev = n
            }
        }
        segments.append((segStart, prev))
        if segments.count == 1 {
            return lo == hi ? "Row \(lo)" : "Rows \(lo)\u{2013}\(hi)"
        }
        if segments.count <= 2 {
            let parts = segments.map { $0.0 == $0.1 ? "\($0.0)" : "\($0.0)\u{2013}\($0.1)" }
            return "Rows " + parts.joined(separator: ", ")
        }
        return "Rows \(lo)\u{2013}\(hi)"
    }

    private func blockMetaLine(for paddock: Paddock) -> some View {
        let variety = paddock.varietyAllocations.first.map { _ in
            paddock.varietyAllocations.compactMap { allocationName($0) }.joined(separator: ", ")
        } ?? ""
        let rangeLabel = Self.rowRangeLabel(for: paddock)
        return HStack(spacing: 6) {
            Text(rangeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !variety.isEmpty {
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(variety)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func allocationName(_ allocation: PaddockVarietyAllocation) -> String? {
        let resolved = PaddockVarietyResolver.resolve(
            allocation: allocation,
            varieties: store.grapeVarieties
        )
        let trimmed = resolved.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private func blockStatsRow(for paddock: Paddock) -> some View {
        let nums = paddock.rows.map(\.number).sorted()
        let rowsLabel = nums.isEmpty ? "Rows" : Self.compactRowRangeLabel(nums)
        return HStack(spacing: 0) {
            statCell(value: "\(paddock.rows.count)", label: rowsLabel)
            Divider().frame(height: 32)
            statCell(value: String(format: "%.2f", paddock.areaHectares), label: "Hectares")
            Divider().frame(height: 32)
            statCell(value: "\(paddock.effectiveVineCount)", label: "Vines")
        }
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }

    // MARK: Start path & direction

    private var directionSection: some View {
        sectionContainer(title: "Start Path & Direction", icon: "arrow.up.arrow.down", tint: .blue) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                    Text(rowGuidanceHelperText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }

                Menu {
                    ForEach(availablePaths, id: \.self) { path in
                        Button {
                            startPath = path
                        } label: {
                            HStack {
                                Text(pathMenuLabel(path))
                                if abs(path - startPath) < 0.01 {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start path")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(pathMenuLabel(startPath))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Sequence direction")
                        .font(.subheadline.weight(.semibold))
                    Picker("Sequence direction", selection: $directionHigherFirst) {
                        Text("Higher to lower").tag(false)
                        Text("Lower to higher").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 12))
            }
        }
    }

    private var rowGuidanceHelperText: String {
        let n = combinedTotalRows
        guard n > 0 else { return "Row guidance unavailable for the selected blocks" }
        if selectedPaddocks.count > 1 {
            return "Row guidance follows all selected blocks (\(combinedRangeLabel) · \(combinedPathsLabel))"
        }
        return "Row guidance follows selected block (\(combinedRangeLabel) · \(combinedPathsLabel))"
    }

    private func pathMenuLabel(_ path: Double) -> String {
        let pathStr = formatPath(path)
        let lo = minSelectedRow
        let hi = maxSelectedRow
        if !selectedRowNumbers.isEmpty, path < Double(lo) {
            return "Path before row \(lo) — \(pathStr)"
        }
        if !selectedRowNumbers.isEmpty, path > Double(hi) {
            return "Path after row \(hi) — \(pathStr)"
        }
        let lower = Int(floor(path))
        let upper = lower + 1
        return "Between rows \(lower)–\(upper) — \(pathStr)"
    }

    private func formatPath(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func clampStartPath() {
        let paths = availablePaths
        guard let first = paths.first, let last = paths.last else { return }
        if startPath < first { startPath = first }
        if startPath > last { startPath = last }
        // Snap to nearest valid X.5
        let rounded = (startPath - 0.5).rounded() + 0.5
        if abs(rounded - startPath) > 0.01 {
            startPath = min(max(rounded, first), last)
        }
    }

    // MARK: Proposed sequence preview (all planned patterns)

    private var sequencePreviewSection: some View {
        sectionContainer(
            title: "Proposed Row Sequence",
            icon: "list.number",
            tint: .purple
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let note = patternPreviewNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let sequence = generatedSequence()
                if sequence.isEmpty {
                    Text("No sequence available for the current selection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 12))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                            Text(sequencePreviewText(sequence))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        Text("\(sequence.count) path\(sequence.count == 1 ? "" : "s") planned")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 12))
                }
            }
        }
    }

    private var patternPreviewNote: String? {
        switch trackingPattern {
        case .sequential:
            return "Sequential: walks every path one-by-one in the chosen direction."
        case .everySecondRow:
            return "Every Second Row: advances by +2 in the chosen direction, then wraps to cover the remaining same-parity paths."
        case .fiveThree:
            return "5/3 pattern: skips ahead 5, back 3, repeating from the chosen start."
        case .upAndBack:
            return "Up and Back: traverses then reverses, covering each path once."
        case .twoRowUpBack:
            return "Two Row Up & Back: pairs of rows, advancing then returning."
        case .custom:
            return "Custom pattern: generated from the chosen start and direction."
        case .freeDrive:
            return nil
        }
    }

    private func sequencePreviewText(_ sequence: [Double]) -> String {
        let maxItems = 10
        let preview = sequence.prefix(maxItems).map { formatPath($0) }
        let joined = preview.joined(separator: " → ")
        return sequence.count > maxItems ? joined + " → …" : joined
    }

    /// Generate the full traversal sequence for the current pattern, start path,
    /// and direction. For Every Second Row this is computed against the combined
    /// multi-block path range with parity-preserving wrap. Other patterns are
    /// generated by the existing engine in a local 1…N space and then offset
    /// back to the actual selection's row numbering so the produced paths line
    /// up with the user-visible Start Path values.
    private func generatedSequence() -> [Double] {
        let n = combinedTotalRows
        guard n > 0 else { return [] }
        if trackingPattern == .everySecondRow {
            return Self.everySecondRowSequence(
                paths: availablePaths,
                startPath: startPath,
                higherFirst: directionHigherFirst
            )
        }
        // Translate the chosen start path into the engine's local 1…N space.
        // Local startRow corresponds to (startPath - (minRow-1)) rounded.
        let offset = Double(minSelectedRow - 1)
        let localStartRow = max(1, min(Int((startPath - offset) + 0.5), n))
        let raw = trackingPattern.generateSequence(
            startRow: localStartRow,
            totalRows: n,
            reversed: !directionHigherFirst
        )
        // Shift back to actual row numbering.
        return raw.map { $0 + offset }
    }

    /// Every Second Row, parity-preserving sequence across the combined paths.
    /// - Direction lower-first: start, start-2, start-4, …, then wrap to highest
    ///   missed same-parity path and continue downward toward start+2.
    /// - Direction higher-first: start, start+2, start+4, …, then wrap to lowest
    ///   missed same-parity path and continue upward toward start-2.
    static func everySecondRowSequence(paths: [Double], startPath: Double, higherFirst: Bool) -> [Double] {
        guard !paths.isEmpty else { return [] }
        let sorted = paths.sorted()
        // Same-parity = even integer distance from startPath.
        let sameParity = sorted.filter { p in
            let diff = Int(round(p - startPath))
            return diff % 2 == 0
        }
        guard !sameParity.isEmpty else { return [] }
        if higherFirst {
            let firstRun = sameParity.filter { $0 >= startPath }.sorted()
            let wrap = sameParity.filter { $0 < startPath }.sorted()
            return firstRun + wrap
        } else {
            let firstRun = sameParity.filter { $0 <= startPath }.sorted(by: >)
            let wrap = sameParity.filter { $0 > startPath }.sorted(by: >)
            return firstRun + wrap
        }
    }

    // MARK: Free Drive info

    private var freeDriveInfoSection: some View {
        sectionContainer(title: "Free Drive", icon: "scribble.variable", tint: .teal) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.teal)
                    Text("No planned row sequence")
                        .font(.subheadline.weight(.semibold))
                }
                Text("Drive freely — the app detects the row/path you are in from GPS, ticks it off when covered, and keeps recording distance, pins and trip history. No wrong-row warnings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
        }
    }

    // MARK: Pattern

    private var patternSection: some View {
        sectionContainer(title: "Tracking Pattern", icon: "arrow.triangle.swap", tint: .purple) {
            VStack(spacing: 10) {
                ForEach(TrackingPattern.allCases) { pattern in
                    patternRow(pattern: pattern)
                }
            }
        }
    }

    private func patternRow(pattern: TrackingPattern) -> some View {
        let isSelected = trackingPattern == pattern
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                trackingPattern = pattern
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill((isSelected ? Color.purple : Color.secondary).opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: pattern.icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isSelected ? .purple : .secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(pattern.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(pattern.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.purple : Color.secondary.opacity(0.5))
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.purple.opacity(0.5) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Trip function

    private struct TripFunctionOption: Identifiable {
        let id: String
        let label: String
        let icon: String
        let isCustom: Bool
    }

    private var selectedBuiltinFunction: TripFunction? {
        TripFunction(rawValue: selectedFunctionKey)
    }

    private var selectedCustomFunction: VineyardTripFunction? {
        guard selectedFunctionKey.hasPrefix("custom:") else { return nil }
        let slug = String(selectedFunctionKey.dropFirst("custom:".count))
        return tripFunctionService.functions.first { $0.slug == slug && $0.isActive && $0.deletedAt == nil }
    }

    private var selectedFunctionLabel: String {
        if let b = selectedBuiltinFunction { return b.displayName }
        if let c = selectedCustomFunction { return c.label }
        return "Select function"
    }

    private var selectedFunctionIcon: String {
        selectedBuiltinFunction?.icon ?? "wrench.and.screwdriver"
    }

    private var isSeedingSelected: Bool {
        selectedBuiltinFunction == .seeding
    }

    private var isOtherSelected: Bool {
        selectedBuiltinFunction == .other
    }

    /// Combined, alphabetically sorted list of built-in and active custom
    /// trip functions for the current vineyard.
    private var allFunctionOptions: [TripFunctionOption] {
        var opts: [TripFunctionOption] = TripFunction.allCases
            .filter { !$0.isUndervineWeedingSubtype }
            .map {
                TripFunctionOption(id: $0.rawValue, label: $0.displayName, icon: $0.icon, isCustom: false)
            }
        for fn in tripFunctionService.activeSortedByLabel {
            opts.append(
                TripFunctionOption(
                    id: "custom:\(fn.slug)",
                    label: fn.label,
                    icon: "wrench.and.screwdriver",
                    isCustom: true
                )
            )
        }
        return opts.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var canManageTripFunctions: Bool {
        accessControl.canChangeSettings
    }

    /// Undervine weeding method subtypes shown as a dedicated section in the
    /// trip function picker.
    private var undervineSubtypeOptions: [TripFunctionOption] {
        TripFunction.undervineWeedingSubtypes.map {
            TripFunctionOption(id: $0.rawValue, label: $0.displayName, icon: $0.icon, isCustom: false)
        }
    }

    private var functionSection: some View {
        sectionContainer(title: "Trip Function", icon: "wrench.and.screwdriver", tint: VineyardTheme.earthBrown) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Menu {
                        let options = allFunctionOptions
                        let builtins = options.filter { !$0.isCustom }
                        let customs = options.filter { $0.isCustom }
                        if !builtins.isEmpty {
                            Section("Built-in") {
                                ForEach(builtins) { option in
                                    functionMenuButton(option)
                                }
                            }
                        }
                        Section("Undervine Weeding") {
                            ForEach(undervineSubtypeOptions) { option in
                                functionMenuButton(option)
                            }
                        }
                        if !customs.isEmpty {
                            Section("Custom") {
                                ForEach(customs) { option in
                                    functionMenuButton(option)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedFunctionIcon)
                                .foregroundStyle(VineyardTheme.earthBrown)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Function")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(selectedFunctionLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)

                    Button {
                        showAddCustomFunction = true
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                            Text("Add")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(canManageTripFunctions ? VineyardTheme.leafGreen : Color.secondary.opacity(0.5))
                        .frame(width: 60, height: 56)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canManageTripFunctions)
                    .accessibilityLabel("Add function")
                }

                Text(canManageTripFunctions
                     ? "Need another job type? Add or edit trip functions in Settings."
                     : "Ask an Owner or Manager to add trip functions in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                HStack(spacing: 12) {
                    Image(systemName: "text.cursor")
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    TextField(
                        isOtherSelected ? "Trip title (required)" : "Trip title (optional)",
                        text: $customTitle
                    )
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                }
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private func functionMenuButton(_ option: TripFunctionOption) -> some View {
        Button {
            selectedFunctionKey = option.id
        } label: {
            HStack {
                Image(systemName: option.icon)
                Text(option.label)
                if option.id == selectedFunctionKey {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    // MARK: Machine

    /// Vineyard machines available for job costing in the current vineyard.
    /// Filtered to active machines (`deleted_at` nil via the store) that are
    /// flagged `available_for_job_costing`.
    private var availableMachines: [VineyardMachine] {
        store.machines()
            .filter { $0.availableForJobCosting }
    }

    /// Most recently used machine from this vineyard's previous trips. Used as
    /// a low-risk default when the operator opens Start Trip. Only returns a
    /// machine that still exists in the available list.
    private var defaultMachineId: UUID? {
        let vineyardId = store.selectedVineyardId
        let availableIds = Set(availableMachines.map { $0.id })
        let pool = store.trips
            .filter { $0.vineyardId == vineyardId && $0.machineId != nil }
            .sorted { $0.startTime > $1.startTime }
        if let recent = pool.first(where: { availableIds.contains($0.machineId!) })?.machineId {
            return recent
        }
        // Only auto-default when exactly one machine exists to avoid guessing.
        if availableMachines.count == 1 {
            return availableMachines.first?.id
        }
        return nil
    }

    private var selectedMachine: VineyardMachine? {
        guard let id = selectedMachineId else { return nil }
        return availableMachines.first { $0.id == id }
    }

    private var selectedMachineLabel: String {
        if let m = selectedMachine { return m.displayName }
        return availableMachines.isEmpty ? "No vineyard machines configured" : "No machine selected"
    }

    private var machineSection: some View {
        sectionContainer(title: "Machine", icon: "car.fill", tint: .indigo) {
            VStack(spacing: 10) {
                Menu {
                    Button {
                        selectedMachineId = nil
                    } label: {
                        HStack {
                            Text("No machine")
                            if selectedMachineId == nil {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    if !availableMachines.isEmpty {
                        Divider()
                        ForEach(availableMachines) { machine in
                            Button {
                                selectedMachineId = machine.id
                            } label: {
                                HStack {
                                    Text("\(machine.displayName) · \(machine.machineType.displayName)")
                                    if selectedMachineId == machine.id {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "car.fill")
                            .foregroundStyle(.indigo)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Machine")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(selectedMachineLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(availableMachines.isEmpty)

                if availableMachines.isEmpty {
                    Text("Add vineyard machines in Equipment to enable fuel cost estimates.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else if selectedMachineId == nil {
                    Text("Optional — select a machine so fuel cost can be estimated.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                if selectedMachineId != nil {
                    HStack(spacing: 12) {
                        Image(systemName: "gauge.with.needle")
                            .foregroundStyle(.indigo)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start engine hours")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Optional — for accurate fuel use")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        TextField(lastKnownEngineHoursPlaceholder, text: $startEngineHoursText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 12))

                    if let last = lastKnownEngineHours {
                        Text("Last recorded: \(Self.engineHoursFormatter.string(from: NSNumber(value: last)) ?? "\(last)") hrs (from fuel log)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    static let engineHoursFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f
    }()

    /// Latest engine-hour reading recorded for the selected machine via the
    /// fuel log (newest fill with engine hours). Prefers the machine link and
    /// falls back to the legacy tractor link. Used as a hint only.
    private var lastKnownEngineHours: Double? {
        guard let machineId = selectedMachineId else { return nil }
        let legacyTractorId = selectedMachine?.legacyTractorId
        return store.tractorFuelLogs
            .filter {
                $0.engineHours != nil &&
                ($0.machineId == machineId || ($0.machineId == nil && legacyTractorId != nil && $0.tractorId == legacyTractorId))
            }
            .sorted { $0.fillDateTime > $1.fillDateTime }
            .first?.engineHours
    }

    private var lastKnownEngineHoursPlaceholder: String {
        if let last = lastKnownEngineHours {
            return Self.engineHoursFormatter.string(from: NSNumber(value: last)) ?? "hrs"
        }
        return "hrs"
    }

    // MARK: Operator

    private var operatorSection: some View {
        sectionContainer(title: "Operator", icon: "person.fill", tint: .orange) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 32)
                TextField("Name (optional)", text: $personName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
        }
    }

    // MARK: Start button

    private var canStartTrip: Bool {
        !selectedPaddockIds.isEmpty
    }

    private var startButton: some View {
        VStack(spacing: 6) {
            Button {
                handleStart()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                        .font(.headline)
                    Text("Start Trip")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canStartTrip ? Color.blue : Color.gray.opacity(0.4), in: .rect(cornerRadius: 14))
                .foregroundStyle(.white)
                .shadow(color: canStartTrip ? Color.blue.opacity(0.25) : .clear, radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(!canStartTrip)

            if !canStartTrip {
                Text("Select at least one block to start the trip.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    // MARK: Helpers

    @ViewBuilder
    private func sectionContainer<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            content()
        }
        .padding(.horizontal)
    }

    private func handleStart() {
        if isSeedingSelected, !useFrontBox, !useBackBox {
            tracking.errorMessage = "Enable at least one seed box for a Seeding trip."
            return
        }
        // Primary paddock = the only selected, or the first sorted when multiple.
        let primary: Paddock? = singleSelectedPaddock ?? selectedPaddocks.first
        let paddockName: String
        if selectedPaddocks.count > 1 {
            paddockName = selectedPaddocks.map(\.name).joined(separator: ", ")
        } else {
            paddockName = primary?.name ?? ""
        }

        // `tripTitle` is reserved for optional user-entered extra details.
        // It must remain nil when the operator hasn't typed anything — display
        // code resolves the friendly label from `tripFunction` (built-in or
        // `custom:<slug>`) instead. Never default the title to the function
        // name/label/code.
        let trimmedTitle = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle: String? = trimmedTitle.isEmpty ? nil : trimmedTitle

        // Resolve the legacy tractor link for backward compatibility: only
        // tractor-backed machines populate `tractor_id`; non-tractor machines
        // (ATV, side-by-side, etc.) leave it nil.
        let legacyTractorId = selectedMachine?.legacyTractorId

        tracking.startTrip(
            type: .maintenance,
            paddockId: primary?.id,
            paddockName: paddockName,
            trackingPattern: trackingPattern,
            personName: personName,
            tripFunction: selectedFunctionKey,
            tripTitle: resolvedTitle,
            machineId: selectedMachineId,
            tractorId: legacyTractorId,
            operatorUserId: auth.userId
        )

        // Persist the full multi-block selection on the active trip and apply
        // a row sequence generated against the combined multi-block path range.
        if var trip = tracking.activeTrip {
            trip.paddockIds = Array(selectedPaddockIds)

            // Phase 2 costing: record the signed-in user as the trip operator
            // when known. The operator category is resolved at cost time from
            // vineyard_members.operator_category_id (see TripCostService).
            if let userId = auth.userId {
                trip.operatorUserId = userId
            }

            // Phase 3 fuel allocation: optional start engine-hour reading.
            if selectedMachineId != nil,
               let hours = Double(startEngineHoursText.trimmingCharacters(in: .whitespaces)),
               hours >= 0 {
                trip.startEngineHours = hours
            }

            if isSeedingSelected {
                let details = buildSeedingDetails()
                // Always persist seeding details when the function is Seeding
                // (even if empty) so the operator's box toggle state is
                // available to "Copy from previous seeding job" on the next
                // trip. SeedingDetails.hasAnyValue still correctly gates the
                // Trip Detail display section.
                if details.frontBox != nil || details.backBox != nil || details.hasAnyValue {
                    trip.seedingDetails = details
                }
            }

            if hasAnyRowGeometry, trackingPattern != .freeDrive {
                let sequence = generatedSequence()
                if let first = sequence.first {
                    trip.rowSequence = sequence
                    trip.sequenceIndex = 0
                    trip.currentRowNumber = first
                    trip.nextRowNumber = sequence.dropFirst().first ?? first
                }
            } else if trackingPattern == .freeDrive {
                // Free Drive: explicitly clear any planned sequence so
                // active-trip UI hides planned-only chrome.
                trip.rowSequence = []
                trip.sequenceIndex = 0
            }
            store.updateTrip(trip)
        }

        if tracking.errorMessage == nil {
            dismiss()
        }
    }

    // MARK: Seeding Details

    private var seedingDetailsSection: some View {
        sectionContainer(title: "Seeding Details", icon: "leaf.circle.fill", tint: VineyardTheme.leafGreen) {
            VStack(spacing: 0) {
                DisclosureGroup(isExpanded: $seedingExpanded) {
                    VStack(spacing: 14) {
                        copyFromPreviousRow
                        boxToggleRow(title: "Use Front Box", isOn: $useFrontBox)
                        boxToggleRow(title: "Use Rear Box", isOn: $useBackBox)
                        if !useFrontBox && !useBackBox {
                            Label("Enable at least one seed box for a Seeding trip.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        seedingMainFields
                        if useFrontBox {
                            seedingBoxCard(
                                title: "Front Box",
                                shutter: $seedFrontShutter,
                                flap: $seedFrontFlap,
                                wheel: $seedFrontWheel,
                                volume: $seedFrontVolume,
                                gearbox: $seedFrontGearbox
                            )
                        }
                        if useBackBox {
                            seedingBoxCard(
                                title: "Rear Box",
                                shutter: $seedBackShutter,
                                flap: $seedBackFlap,
                                wheel: $seedBackWheel,
                                volume: $seedBackVolume,
                                gearbox: $seedBackGearbox
                            )
                        }
                        seedingMixLinesCard
                    }
                    .padding(.top, 12)
                } label: {
                    HStack(spacing: 8) {
                        Text("Optional details")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("All fields optional")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(VineyardTheme.leafGreen)
                .padding(14)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 12))
        }
    }

    // MARK: Copy-from-previous

    private var copyFromPreviousRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                applyPreviousSeedingSetup()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.on.doc.fill")
                        .foregroundStyle(VineyardTheme.leafGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copy from previous seeding job")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Reuse boxes, rates, depth and mix lines")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(VineyardTheme.leafGreen)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            if let note = copiedFromNote {
                Label(note, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VineyardTheme.leafGreen)
            } else if copyFoundButEmpty {
                Label("Previous seeding job found, but it has no useful saved setup.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if copyMissing {
                Label("No previous seeding setup found.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let diag = copyDiagnostics {
                DisclosureGroup(isExpanded: $showCopyDiagnostics) {
                    Text(diag)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(.rect(cornerRadius: 8))
                        .textSelection(.enabled)
                        .padding(.top, 4)
                } label: {
                    Label("Copy diagnostics", systemImage: "ladybug")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }
        }
    }

    /// Find the most recent seeding trip for the active vineyard that has
    /// non-empty `seedingDetails`, then copy its box toggles, box settings,
    /// sowing depth and mix lines into the form. Trip-specific fields
    /// (paddock, operator, start time, tracking pattern, coverage) are NOT
    /// copied. Works fully offline against locally persisted trips.
    private func applyPreviousSeedingSetup() {
        let lookup = findPreviousSeedingTrip()
        copyDiagnostics = lookup.diagnostics
        guard let trip = lookup.trip else {
            copyMissing = true
            copyFoundButEmpty = false
            copiedFromNote = nil
            showCopyDiagnostics = true
            #if DEBUG
            print("[StartTrip] copy-from-previous: no previous seeding trip found.\n\(lookup.diagnostics)")
            #endif
            return
        }
        let details = trip.seedingDetails ?? SeedingDetails()
        copyMissing = false

        // If the previous trip has no genuinely useful saved setup, surface a
        // friendlier message and skip the "Copied setup from…" note. We still
        // copy whatever values exist (toggles, defaults) so the form reflects
        // the lookup result, and we expand the diagnostics block so the
        // operator can see why nothing useful was copied.
        let isUseful = details.hasMeaningfulValue
        if !isUseful {
            copyFoundButEmpty = true
            showCopyDiagnostics = true
        } else {
            copyFoundButEmpty = false
        }

        // Front box: a non-nil box (even if all fields are empty) means the
        // operator had Use Front Box enabled on the previous trip, so honour
        // that toggle state when copying.
        if let f = details.frontBox {
            useFrontBox = true
            seedFrontMix = f.mixName ?? ""
            seedFrontRate = f.ratePerHa.map { trimNumber($0) } ?? ""
            if let s = f.shutterSlide, !s.isEmpty { seedFrontShutter = s }
            if let b = f.bottomFlap, !b.isEmpty { seedFrontFlap = b }
            if let w = f.meteringWheel, !w.isEmpty { seedFrontWheel = w }
            seedFrontVolume = f.seedVolumeKg.map { trimNumber($0) } ?? ""
            seedFrontGearbox = f.gearboxSetting.map { trimNumber($0) } ?? ""
        } else {
            useFrontBox = false
        }

        if let b = details.backBox {
            useBackBox = true
            seedBackMix = b.mixName ?? ""
            seedBackRate = b.ratePerHa.map { trimNumber($0) } ?? ""
            if let s = b.shutterSlide, !s.isEmpty { seedBackShutter = s }
            if let f = b.bottomFlap, !f.isEmpty { seedBackFlap = f }
            if let w = b.meteringWheel, !w.isEmpty { seedBackWheel = w }
            seedBackVolume = b.seedVolumeKg.map { trimNumber($0) } ?? ""
            seedBackGearbox = b.gearboxSetting.map { trimNumber($0) } ?? ""
        } else {
            useBackBox = false
        }

        // If neither box is recorded on the previous trip (e.g. very early
        // seeding records before this feature shipped), default to Front Box
        // enabled so the form is still usable after copy.
        if details.frontBox == nil && details.backBox == nil {
            useFrontBox = true
        }

        sowingDepth = details.sowingDepthCm.map { trimNumber($0) } ?? ""
        // Re-id copied mix lines so SwiftUI ForEach identity stays stable
        // and edits don't bleed into the source trip.
        mixLines = (details.mixLines ?? []).map { line in
            SeedingMixLine(
                id: UUID(),
                name: line.name,
                percentOfMix: line.percentOfMix,
                seedBox: line.seedBox,
                kgPerHa: line.kgPerHa,
                supplierManufacturer: line.supplierManufacturer
            )
        }

        copiedFromNote = isUseful ? describeCopiedTrip(trip) : nil
        seedingExpanded = true

        // Append a clear "applied to form" trace so the operator can
        // verify exactly which @State values landed in the visible form.
        // This makes it obvious when a field is blank because the source
        // trip didn't have it (e.g. seed_volume_kg = nil) versus a copy
        // bug. Surfaced inside the existing Copy Diagnostics block.
        var applied: [String] = []
        applied.append("")
        applied.append("--- applied to form ---")
        applied.append("useFrontBox = \(useFrontBox)")
        applied.append("useBackBox = \(useBackBox)")
        applied.append("seedFrontMix = \"\(seedFrontMix)\"")
        applied.append("seedFrontRate = \"\(seedFrontRate)\"")
        applied.append("seedFrontShutter = \"\(seedFrontShutter)\"")
        applied.append("seedFrontFlap = \"\(seedFrontFlap)\"")
        applied.append("seedFrontWheel = \"\(seedFrontWheel)\"")
        applied.append("seedFrontVolume = \"\(seedFrontVolume)\"")
        applied.append("seedFrontGearbox = \"\(seedFrontGearbox)\"")
        applied.append("seedBackMix = \"\(seedBackMix)\"")
        applied.append("seedBackRate = \"\(seedBackRate)\"")
        applied.append("seedBackShutter = \"\(seedBackShutter)\"")
        applied.append("seedBackFlap = \"\(seedBackFlap)\"")
        applied.append("seedBackWheel = \"\(seedBackWheel)\"")
        applied.append("seedBackVolume = \"\(seedBackVolume)\"")
        applied.append("seedBackGearbox = \"\(seedBackGearbox)\"")
        applied.append("sowingDepth = \"\(sowingDepth)\"")
        applied.append("mixLines.count = \(mixLines.count)")
        copyDiagnostics = (copyDiagnostics ?? "") + "\n" + applied.joined(separator: "\n")
    }

    /// Find the most recent seeding trip we can copy from. Preference order:
    /// 1) trips with populated `seedingDetails.hasAnyValue == true`
    /// 2) trips that were Seeding but have no/empty details (still gives the
    ///    operator the box toggles + a clear note, much better than silent
    ///    failure in the field).
    /// We also exclude any active/paused trip and the current draft trip so
    /// the operator can't "copy from themselves".
    /// Diagnostic-bearing lookup. Returns the trip we'd copy from (if any)
    /// plus a human-readable trace explaining the filter pipeline.
    private func findPreviousSeedingTrip() -> (trip: Trip?, diagnostics: String) {
        let vineyardId = store.selectedVineyardId
        let allTrips = store.trips
        var lines: [String] = []
        lines.append("vineyard = \(vineyardId?.uuidString ?? "nil")")
        lines.append("store.trips.count = \(allTrips.count)")

        let sameVineyard: [Trip]
        if let vid = vineyardId {
            sameVineyard = allTrips.filter { $0.vineyardId == vid }
        } else {
            sameVineyard = allTrips
        }
        lines.append("same-vineyard = \(sameVineyard.count)")

        // Surface the raw tripFunction distribution so we can confirm the
        // saved value matches what the filter expects.
        var fnCounts: [String: Int] = [:]
        for t in sameVineyard {
            let key = t.tripFunction ?? "<nil>"
            fnCounts[key, default: 0] += 1
        }
        if fnCounts.isEmpty {
            lines.append("trip-function distribution = (none)")
        } else {
            let pairs = fnCounts
                .sorted { $0.value > $1.value }
                .map { "\"\($0.key)\": \($0.value)" }
                .joined(separator: ", ")
            lines.append("trip-function distribution = { \(pairs) }")
        }

        let seedingTrips = sameVineyard.filter { trip in
            guard let raw = trip.tripFunction else { return false }
            return (raw == TripFunction.seeding.rawValue) || raw.lowercased().contains("seed")
        }
        lines.append("trip-function == seeding = \(seedingTrips.count)")

        let inactive = seedingTrips.filter { !$0.isActive && !$0.isPaused }
        lines.append("non-active seeding = \(inactive.count)")

        let withDetails = inactive.filter { $0.seedingDetails != nil }
        lines.append("with seedingDetails != nil = \(withDetails.count)")

        let withMeaningful = withDetails.filter { $0.seedingDetails?.hasAnyValue == true }
        lines.append("with seedingDetails.hasAnyValue = \(withMeaningful.count)")

        let withUseful = withDetails.filter { $0.seedingDetails?.hasMeaningfulValue == true }
        lines.append("with seedingDetails.hasMeaningfulValue = \(withUseful.count)")

        let sorted = inactive.sorted {
            ($0.endTime ?? $0.startTime) > ($1.endTime ?? $1.startTime)
        }

        let chosen: Trip?
        if let first = sorted.first(where: { $0.seedingDetails?.hasMeaningfulValue == true }) {
            chosen = first
            lines.append("selected = \(first.id.uuidString) (meaningful values)")
        } else if let first = sorted.first(where: { $0.seedingDetails?.hasAnyValue == true }) {
            chosen = first
            lines.append("selected = \(first.id.uuidString) (defaults only — no useful setup)")
        } else if let first = sorted.first {
            chosen = first
            lines.append("selected = \(first.id.uuidString) (fallback, no/empty details)")
        } else {
            chosen = nil
            if seedingTrips.isEmpty {
                lines.append("reason = no seeding trips found for this vineyard")
            } else if inactive.isEmpty {
                lines.append("reason = all seeding trips are still active/paused")
            } else {
                lines.append("reason = no eligible candidates after filters")
            }
        }

        if let chosen {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            let date = f.string(from: chosen.endTime ?? chosen.startTime)
            lines.append("selected.date = \(date)")
            lines.append("selected.paddock = \(chosen.paddockName.isEmpty ? "<none>" : chosen.paddockName)")
            lines.append("selected.tripFunction = \(chosen.tripFunction ?? "<nil>")")
            if let d = chosen.seedingDetails {
                lines.append("selected.hasMeaningfulValue = \(d.hasMeaningfulValue)")
                lines.append("selected.sowing_depth_cm = \(d.sowingDepthCm.map { String($0) } ?? "nil")")
                if let f = d.frontBox {
                    lines.append("selected.front.mix_name = \(quoteOrNil(f.mixName))")
                    lines.append("selected.front.rate_per_ha = \(f.ratePerHa.map { String($0) } ?? "nil")")
                    lines.append("selected.front.shutter_slide = \(quoteOrNil(f.shutterSlide))")
                    lines.append("selected.front.bottom_flap = \(quoteOrNil(f.bottomFlap))")
                    lines.append("selected.front.metering_wheel = \(quoteOrNil(f.meteringWheel))")
                    lines.append("selected.front.seed_volume_kg = \(f.seedVolumeKg.map { String($0) } ?? "nil")")
                    lines.append("selected.front.gearbox_setting = \(f.gearboxSetting.map { String($0) } ?? "nil")")
                    lines.append("selected.front.hasMeaningfulValue = \(f.hasMeaningfulValue)")
                } else {
                    lines.append("selected.front = nil")
                }
                if let b = d.backBox {
                    lines.append("selected.back.mix_name = \(quoteOrNil(b.mixName))")
                    lines.append("selected.back.rate_per_ha = \(b.ratePerHa.map { String($0) } ?? "nil")")
                    lines.append("selected.back.shutter_slide = \(quoteOrNil(b.shutterSlide))")
                    lines.append("selected.back.bottom_flap = \(quoteOrNil(b.bottomFlap))")
                    lines.append("selected.back.metering_wheel = \(quoteOrNil(b.meteringWheel))")
                    lines.append("selected.back.seed_volume_kg = \(b.seedVolumeKg.map { String($0) } ?? "nil")")
                    lines.append("selected.back.gearbox_setting = \(b.gearboxSetting.map { String($0) } ?? "nil")")
                    lines.append("selected.back.hasMeaningfulValue = \(b.hasMeaningfulValue)")
                } else {
                    lines.append("selected.back = nil")
                }
                let lineCount = d.mixLines?.count ?? 0
                lines.append("selected.mix_lines = \(lineCount)")
                if let ml = d.mixLines, !ml.isEmpty {
                    for (i, line) in ml.enumerated() {
                        let n = quoteOrNil(line.name)
                        let kg = line.kgPerHa.map { String($0) } ?? "nil"
                        lines.append("  mix_lines[\(i)] name=\(n) kg/ha=\(kg)")
                    }
                }
            } else {
                lines.append("selected.seedingDetails = nil")
            }
        }

        return (chosen, lines.joined(separator: "\n"))
    }

    private func quoteOrNil(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "nil" }
        return "\"\(s)\""
    }

    private func describeCopiedTrip(_ trip: Trip) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        let date = f.string(from: trip.endTime ?? trip.startTime)
        let block = trip.paddockName.trimmingCharacters(in: .whitespacesAndNewlines)
        if block.isEmpty {
            return "Copied setup from Seeding — \(date)"
        }
        return "Copied setup from Seeding — \(block) — \(date)"
    }

    private var seedingMainFields: some View {
        VStack(spacing: 10) {
            if useFrontBox {
                seedingTextField(label: "Seed/Fert mix — Front Box", text: $seedFrontMix, placeholder: "e.g. Ryecorn + Vetch")
                seedingNumericField(label: "Rate/ha — Front Box", text: $seedFrontRate, suffix: "kg/ha")
            }
            if useBackBox {
                seedingTextField(label: "Seed/Fert mix — Rear Box", text: $seedBackMix, placeholder: "e.g. Tic Beans")
                seedingNumericField(label: "Rate/ha — Rear Box", text: $seedBackRate, suffix: "kg/ha")
            }
            seedingNumericField(label: "Sowing depth", text: $sowingDepth, suffix: "cm")
        }
    }

    @ViewBuilder
    private func boxToggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(VineyardTheme.leafGreen)
            Toggle(title, isOn: isOn)
                .tint(VineyardTheme.leafGreen)
                .font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    @ViewBuilder
    private func seedingBoxCard(
        title: String,
        shutter: Binding<String>,
        flap: Binding<String>,
        wheel: Binding<String>,
        volume: Binding<String>,
        gearbox: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            seedingPicker(label: "Shutter Slide", selection: shutter, options: ["3/4", "Full"])
            seedingPicker(label: "Bottom Flap", selection: flap, options: ["1", "3"])
            seedingPicker(label: "Metering Wheel", selection: wheel, options: ["N", "F"])
            seedingNumericField(label: "Volume of Seed", text: volume, suffix: "kg")
            seedingNumericField(label: "Seed Rate Gearbox", text: gearbox, suffix: nil)
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var seedingMixLinesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Seed Mix Breakdown")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    mixLines.append(SeedingMixLine(seedBox: "Front"))
                } label: {
                    Label("Add line", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(VineyardTheme.leafGreen)
            }

            if mixLines.isEmpty {
                Text("Optional. Tap Add line to record seed components.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(mixLines.enumerated()), id: \.element.id) { idx, _ in
                    seedingMixLineRow(index: idx)
                }
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    /// Saved Inputs available for the current vineyard, filtered to the
    /// `seed` type. The seeding mix-line editor is only shown for Seeding
    /// trips so we don't surface fertiliser/compost/etc. here. Trip cost
    /// resolution still falls back to savedInputId / name match if the
    /// catalog row changes later.
    private var availableSeedInputs: [SavedInput] {
        let vineyardId = store.selectedVineyardId
        return store.savedInputs
            .filter { input in
                guard input.inputType == .seed else { return false }
                return vineyardId == nil || input.vineyardId == vineyardId
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Snapshot the picked Saved Input onto the mix line so trip costing
    /// can resolve cost-per-unit even if the catalog row changes later.
    /// Selecting "Manual entry" (`nil`) clears the snapshot but keeps any
    /// operator-entered text in `name` / `supplier` / `kg/ha`.
    private func applySavedInput(_ input: SavedInput?, toLineAt index: Int) {
        guard mixLines.indices.contains(index) else { return }
        if let input {
            mixLines[index].savedInputId = input.id
            mixLines[index].name = input.name
            mixLines[index].inputType = input.inputType.rawValue
            mixLines[index].unit = input.unit.rawValue
            mixLines[index].costPerUnit = input.costPerUnit
            if let supplier = input.supplier?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !supplier.isEmpty,
               (mixLines[index].supplierManufacturer ?? "").isEmpty {
                mixLines[index].supplierManufacturer = supplier
            }
        } else {
            mixLines[index].savedInputId = nil
            // Keep `name`, `inputType`, `unit`, `costPerUnit` so old records
            // / manual entries continue to render. Operator can clear name
            // by hand if desired.
        }
    }

    @ViewBuilder
    private func seedingMixLineRow(index: Int) -> some View {
        let bindingName = Binding<String>(
            get: { mixLines[index].name ?? "" },
            set: { mixLines[index].name = $0.isEmpty ? nil : $0 }
        )
        let bindingPercent = Binding<String>(
            get: { mixLines[index].percentOfMix.map { trimNumber($0) } ?? "" },
            set: { mixLines[index].percentOfMix = Double($0) }
        )
        let bindingBox = Binding<String>(
            get: { mixLines[index].seedBox ?? "Front" },
            set: { mixLines[index].seedBox = $0 }
        )
        let bindingKgHa = Binding<String>(
            get: { mixLines[index].kgPerHa.map { trimNumber($0) } ?? "" },
            set: { mixLines[index].kgPerHa = Double($0) }
        )
        let bindingSupplier = Binding<String>(
            get: { mixLines[index].supplierManufacturer ?? "" },
            set: { mixLines[index].supplierManufacturer = $0.isEmpty ? nil : $0 }
        )

        VStack(spacing: 8) {
            HStack {
                Text("Line \(index + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    mixLines.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            savedInputPickerRow(index: index)
            seedingTextField(label: "Name", text: bindingName, placeholder: "e.g. Ryecorn")
            seedingNumericField(label: "% of Mix", text: bindingPercent, suffix: "%")
            seedingPicker(label: "Seed Box", selection: bindingBox, options: ["Front", "Back"])
            seedingNumericField(label: "Kg/ha", text: bindingKgHa, suffix: "kg/ha")
            seedingTextField(label: "Supplier", text: bindingSupplier, placeholder: "Manufacturer")
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 8))
    }

    @ViewBuilder
    private func savedInputPickerRow(index: Int) -> some View {
        let inputs = availableSeedInputs
        let selectedId = mixLines[index].savedInputId
        let selectedInput = inputs.first { $0.id == selectedId }
        HStack(spacing: 10) {
            Text("Saved Input")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Menu {
                Button {
                    applySavedInput(nil, toLineAt: index)
                } label: {
                    if selectedId == nil {
                        Label("Manual entry", systemImage: "checkmark")
                    } else {
                        Text("Manual entry")
                    }
                }
                if !inputs.isEmpty {
                    Divider()
                    ForEach(inputs) { input in
                        Button {
                            applySavedInput(input, toLineAt: index)
                        } label: {
                            if input.id == selectedId {
                                Label(input.name, systemImage: "checkmark")
                            } else {
                                Text(input.name)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedInput?.name ?? "Manual entry")
                        .font(.subheadline)
                        .foregroundStyle(selectedInput == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        if inputs.isEmpty {
            Text("No saved seed inputs yet. Add them in Settings → Spray & Equipment → Saved Inputs.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func seedingTextField(label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private func seedingNumericField(label: String, text: Binding<String>, suffix: String?) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .font(.subheadline)
            if let suffix {
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func seedingPicker(label: String, selection: Binding<String>, options: [String]) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Picker(label, selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func trimNumber(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(value)
    }

    private func buildSeedingDetails() -> SeedingDetails {
        func trimmed(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        // Robust numeric parser: trims whitespace, strips common unit
        // suffixes (kg, kg/ha, cm) and stray non-numeric characters so
        // values like "20 kg" or "20kg/ha" still persist correctly.
        // Without this, `Double("20 kg")` returns nil and the operator's
        // entered Volume of Seed / Seed Rate Gearbox values are silently
        // dropped on save, which is why "Copy from previous" then shows
        // those fields blank on the next trip.
        func parseNumber(_ s: String) -> Double? {
            let trimmedRaw = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRaw.isEmpty else { return nil }
            if let direct = Double(trimmedRaw) { return direct }
            let cleaned = trimmedRaw
                .replacingOccurrences(of: ",", with: ".")
                .filter { $0.isNumber || $0 == "." || $0 == "-" }
            return Double(cleaned)
        }
        // Only persist box settings for boxes the operator actually used.
        // Disabled boxes are saved as nil so unused defaults don't pollute
        // the trip record. Enabled boxes are always saved (even if empty)
        // so the toggle state survives for "Copy from previous seeding job".
        let front: SeedingBox? = useFrontBox ? SeedingBox(
            mixName: trimmed(seedFrontMix),
            ratePerHa: parseNumber(seedFrontRate),
            shutterSlide: trimmed(seedFrontShutter),
            bottomFlap: trimmed(seedFrontFlap),
            meteringWheel: trimmed(seedFrontWheel),
            seedVolumeKg: parseNumber(seedFrontVolume),
            gearboxSetting: parseNumber(seedFrontGearbox)
        ) : nil
        let back: SeedingBox? = useBackBox ? SeedingBox(
            mixName: trimmed(seedBackMix),
            ratePerHa: parseNumber(seedBackRate),
            shutterSlide: trimmed(seedBackShutter),
            bottomFlap: trimmed(seedBackFlap),
            meteringWheel: trimmed(seedBackWheel),
            seedVolumeKg: parseNumber(seedBackVolume),
            gearboxSetting: parseNumber(seedBackGearbox)
        ) : nil
        let lines = mixLines.filter { $0.hasAnyValue }
        // Auto-calculate `percent_of_mix` for each mix line as a share
        // of the total kg/ha within the same seed box. Preserves any
        // value the operator entered manually — only fills blanks so
        // both the iOS PDF and Lovable trip report can render the
        // percentage column without the operator doing the maths.
        let calculated = Self.fillCalculatedPercentOfMix(in: lines)
        return SeedingDetails(
            frontBox: front,
            backBox: back,
            sowingDepthCm: parseNumber(sowingDepth),
            mixLines: calculated.isEmpty ? nil : calculated
        )
    }

    /// Returns `lines` with any missing `percentOfMix` populated from
    /// `kgPerHa` as a percentage of the total kg/ha for the same seed
    /// box. If a line already has an operator-entered percentage it is
    /// preserved unchanged. Lines without `kgPerHa`, or whose box has
    /// zero total kg/ha, are left blank.
    static func fillCalculatedPercentOfMix(in lines: [SeedingMixLine]) -> [SeedingMixLine] {
        guard !lines.isEmpty else { return lines }
        // Total kg/ha per box ("Front" / "Back" / nil).
        var totals: [String: Double] = [:]
        for line in lines {
            guard let kg = line.kgPerHa, kg > 0 else { continue }
            let key = (line.seedBox?.isEmpty == false ? line.seedBox! : "_unspecified")
            totals[key, default: 0] += kg
        }
        return lines.map { line in
            var updated = line
            if updated.percentOfMix == nil,
               let kg = updated.kgPerHa, kg > 0 {
                let key = (updated.seedBox?.isEmpty == false ? updated.seedBox! : "_unspecified")
                if let total = totals[key], total > 0 {
                    let pct = (kg / total) * 100.0
                    // Round to one decimal place so the report looks clean.
                    updated.percentOfMix = (pct * 10).rounded() / 10
                }
            }
            return updated
        }
    }
}

// MARK: - Multi Paddock Picker Sheet

private struct MultiPaddockPickerSheet: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedIds: Set<UUID>
    @State private var searchText: String = ""

    private var filtered: [Paddock] {
        let all = store.paddocks.sorted(by: StartTripSheet.rowOrderSort)
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedStandardContains(searchText) }
    }

    private var allSelected: Bool {
        !store.paddocks.isEmpty && selectedIds.count == store.paddocks.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.paddocks.isEmpty {
                    ContentUnavailableView {
                        Label("No Blocks", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Create blocks first to assign trips to specific blocks.")
                    }
                } else {
                    List {
                        Section {
                            Button {
                                if allSelected {
                                    selectedIds.removeAll()
                                } else {
                                    selectedIds = Set(store.paddocks.map(\.id))
                                }
                            } label: {
                                HStack {
                                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(allSelected ? AnyShapeStyle(.blue) : AnyShapeStyle(.secondary))
                                    Text(allSelected ? "Deselect All" : "Select All")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(selectedIds.count) of \(store.paddocks.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Section {
                            ForEach(filtered) { paddock in
                                let isSelected = selectedIds.contains(paddock.id)
                                Button {
                                    if isSelected {
                                        selectedIds.remove(paddock.id)
                                    } else {
                                        selectedIds.insert(paddock.id)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(isSelected ? AnyShapeStyle(.blue) : AnyShapeStyle(.tertiary))
                                        GrapeLeafIcon(size: 20, color: VineyardTheme.leafGreen)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(paddock.name)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            Text("\(StartTripSheet.rowRangeLabel(for: paddock)) · \(String(format: "%.2f", paddock.areaHectares)) ha")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $searchText, prompt: "Search blocks")
                }
            }
            .navigationTitle("Select Blocks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Active Trip Card (unchanged)

struct ActiveTripCard: View {
    @Environment(TripTrackingService.self) private var tracking
    @Environment(LocationService.self) private var locationService

    var body: some View {
        if let trip = tracking.activeTrip {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(tracking.isPaused ? Color.orange : VineyardTheme.leafGreen)
                        .frame(width: 10, height: 10)
                    Text(tracking.isPaused ? "Trip Paused" : "Trip Active")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if locationService.location == nil {
                        Label("No GPS", systemImage: "location.slash")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 2) {
                        Text("Tap to resume")
                            .font(.caption2.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    stat("Time", value: formatDuration(tracking.elapsedTime))
                    stat("Distance", value: formatDistance(tracking.currentDistance))
                    stat("Points", value: "\(trip.pathPoints.count)")
                }

                guidanceSection(trip: trip)

                HStack(spacing: 8) {
                    if tracking.isPaused {
                        Button {
                            tracking.resumeTrip()
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(VineyardTheme.leafGreen)
                    } else {
                        Button {
                            tracking.pauseTrip()
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button(role: .destructive) {
                        tracking.endTrip()
                    } label: {
                        Label("End", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private func guidanceSection(trip: Trip) -> some View {
        let paddockName: String? = tracking.currentPaddockName ?? (trip.paddockName.isEmpty ? nil : trip.paddockName)
        VStack(alignment: .leading, spacing: 4) {
            if let paddockName {
                Label { Text(paddockName) } icon: { GrapeLeafIcon(size: 12) }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if tracking.rowGuidanceAvailable, let row = tracking.currentRowNumber {
                HStack(spacing: 12) {
                    Label("Row " + formatRow(row), systemImage: "arrow.left.and.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                    if let dist = tracking.currentRowDistance {
                        Text("±\(Int(dist))m")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if tracking.rowsCoveredCount > 0 {
                        Text("\(tracking.rowsCoveredCount) covered")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if paddockName != nil {
                Text("Row guidance unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatRow(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func stat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters))m" }
        return String(format: "%.2fkm", meters / 1000)
    }
}

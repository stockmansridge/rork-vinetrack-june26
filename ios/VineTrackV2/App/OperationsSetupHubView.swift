import SwiftUI
import MapKit
import CoreLocation
import UniformTypeIdentifiers

struct VineyardSetupHubView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl

    @State private var showAddPaddock: Bool = false
    @State private var paddockToEdit: Paddock?
    @State private var selectedPaddockOnMap: Paddock? = nil

    @State private var latitudeText: String = ""
    @State private var longitudeText: String = ""
    @State private var elevationText: String = ""

    private enum LocationField: Hashable { case latitude, longitude, elevation }
    @FocusState private var focusedField: LocationField?
    @State private var calculationMode: GDDCalculationMode = .bedd
    @State private var resetMode: GDDResetMode = .budburst

    @State private var showGrowthStagesPicker: Bool = false
    @State private var weatherSummary: WeatherSummaryInfo = .empty

    @State private var showRepairButtons: Bool = false
    @State private var showRepairTemplates: Bool = false
    @State private var showGrowthButtons: Bool = false
    @State private var showGrowthTemplates: Bool = false

    @State private var shareURL: ShareURL?
    @State private var showImporter: Bool = false
    @State private var importSummary: PaddockJSONService.ImportSummary?
    @State private var importErrorMessage: String?

    @State private var blockSortOption: BlockSortOption = .rowNumber
    @State private var paddocksWithSoilProfile: Set<UUID> = []
    @State private var sharedCatalogCount: Int = 0
    private let soilProfileRepositoryForChecklist: any SoilProfileRepositoryProtocol = SupabaseSoilProfileRepository()
    private let vineyardRepositoryForLocation: any VineyardRepositoryProtocol = SupabaseVineyardRepository()

    private enum BlockSortOption: String, CaseIterable, Identifiable {
        case rowNumber
        case varietyAZ
        case rowCount
        case vineCount

        var id: String { rawValue }

        var label: String {
            switch self {
            case .rowNumber: return "Row Number"
            case .varietyAZ: return "Variety A\u{2013}Z"
            case .rowCount: return "Number of Rows"
            case .vineCount: return "Number of Vines"
            }
        }

        var symbol: String {
            switch self {
            case .rowNumber: return "number"
            case .varietyAZ: return "textformat"
            case .rowCount: return "square.grid.3x3"
            case .vineCount: return "leaf"
            }
        }
    }

    private var paddocks: [Paddock] { store.orderedPaddocks }

    private var sortedPaddocks: [Paddock] {
        let base = paddocks
        switch blockSortOption {
        case .rowNumber:
            return base.sorted { lhs, rhs in
                let l = lhs.rows.map { $0.number }.min() ?? Int.max
                let r = rhs.rows.map { $0.number }.min() ?? Int.max
                if l != r { return l < r }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .varietyAZ:
            return base.sorted { lhs, rhs in
                let l = dominantVarietyName(for: lhs)
                let r = dominantVarietyName(for: rhs)
                let cmp = l.localizedStandardCompare(r)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .rowCount:
            return base.sorted { lhs, rhs in
                if lhs.rows.count != rhs.rows.count { return lhs.rows.count > rhs.rows.count }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .vineCount:
            return base.sorted { lhs, rhs in
                if lhs.effectiveVineCount != rhs.effectiveVineCount {
                    return lhs.effectiveVineCount > rhs.effectiveVineCount
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func dominantVarietyName(for paddock: Paddock) -> String {
        guard let allocation = paddock.varietyAllocations.max(by: { $0.percent < $1.percent }) else {
            return "\u{FFFF}"
        }
        let resolved = PaddockVarietyResolver.resolve(
            allocation: allocation,
            varieties: store.grapeVarieties
        )
        let trimmed = resolved.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name = trimmed, !name.isEmpty { return name }
        return "\u{FFFF}"
    }

    private var currentVineyardVarieties: Int {
        guard let vid = store.selectedVineyardId else { return 0 }
        return store.grapeVarieties.filter { $0.vineyardId == vid }.count
    }

    /// Count for the master Grape Varieties card. Prefers the shared
    /// catalogue (active built-ins from Supabase via
    /// `SharedGrapeVarietyCatalogCache`) and falls back to the in-app
    /// built-in catalogue size when the shared cache hasn't loaded yet.
    private var masterVarietyCount: Int {
        if sharedCatalogCount > 0 { return sharedCatalogCount }
        return BuiltInGrapeVarietyCatalog.entries.count
    }

    /// Number of vineyard-scoped custom (non built-in) varieties for the
    /// currently selected vineyard. Used to surface custom varieties
    /// created via Supabase (e.g. by the Lovable web portal) on the
    /// Vineyard Setup card.
    private var customVarietyCount: Int {
        guard let vid = store.selectedVineyardId else { return 0 }
        return store.grapeVarieties.filter { $0.vineyardId == vid && !$0.isBuiltIn }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                vineyardMapSection
                blocksSection
                vineyardLocationSection
                varietiesSection
                exportImportSection
                buttonCustomizationSection
                growthStagesSection
                weatherDataSection
                regionUnitsSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Vineyard Setup")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            loadFromSettings()
            reloadWeatherSummary()
            Task { await loadPaddockSoilProfileIds() }
            Task { await loadSharedCatalogCount() }
        }
        .onChange(of: store.selectedVineyardId) { _, _ in
            reloadWeatherSummary()
            Task { await loadPaddockSoilProfileIds() }
            Task { await loadSharedCatalogCount() }
        }
        .sheet(isPresented: $showAddPaddock) {
            EditPaddockSheet(paddock: nil)
        }
        .sheet(item: $paddockToEdit) { paddock in
            EditPaddockSheet(paddock: paddock)
        }
        .sheet(item: $selectedPaddockOnMap) { paddock in
            EditPaddockSheet(paddock: paddock)
        }
        .sheet(isPresented: $showGrowthStagesPicker) {
            GrowthStageConfigSheet()
        }
        .sheet(isPresented: $showRepairButtons) {
            EditButtonsSheet(mode: .repairs)
        }
        .sheet(isPresented: $showRepairTemplates) {
            ButtonTemplateListView(mode: .repairs)
        }
        .sheet(isPresented: $showGrowthButtons) {
            EditButtonsSheet(mode: .growth)
        }
        .sheet(isPresented: $showGrowthTemplates) {
            ButtonTemplateListView(mode: .growth)
        }
        .sheet(item: $shareURL) { wrapper in
            ShareSheet(items: [wrapper.url])
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json, UTType(filenameExtension: "json") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .alert("Import Complete", isPresented: importSummaryBinding, presenting: importSummary) { _ in
            Button("OK", role: .cancel) { importSummary = nil }
        } message: { summary in
            var lines: [String] = [
                "Created: \(summary.created)",
                "Updated: \(summary.updated)",
                "Skipped: \(summary.skipped)"
            ]
            if !summary.errors.isEmpty {
                lines.append("")
                lines.append(contentsOf: summary.errors.prefix(5))
                if summary.errors.count > 5 {
                    lines.append("\u{2026}and \(summary.errors.count - 5) more")
                }
            }
            return Text(lines.joined(separator: "\n"))
        }
        .alert("Import Failed", isPresented: importErrorBinding, presenting: importErrorMessage) { _ in
            Button("OK", role: .cancel) { importErrorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Section helpers

    private func sectionHeader(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func cardBackground<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 14))
    }

    // MARK: - Vineyard Map

    private var vineyardMapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Vineyard Map", symbol: "map.fill", color: .blue)
            VineyardBlocksMiniMap(
                paddocks: paddocks,
                selectedPaddock: $selectedPaddockOnMap,
                onAddBlock: accessControl.canCreateOperationalRecords ? { showAddPaddock = true } : nil
            )
            .frame(height: 320)
            .clipShape(.rect(cornerRadius: 14))
            Text("Tap a block on the map to edit its settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Blocks list

    private var blocksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Blocks")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if paddocks.count > 1 {
                    Menu {
                        Picker("Sort by", selection: $blockSortOption) {
                            ForEach(BlockSortOption.allCases) { option in
                                Label(option.label, systemImage: option.symbol).tag(option)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.footnote.weight(.semibold))
                            Text(blockSortOption.label)
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.12), in: .capsule)
                    }
                }
            }

            cardBackground {
                if accessControl.canCreateOperationalRecords {
                    Button {
                        showAddPaddock = true
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.accentColor)
                                    .frame(width: 30, height: 30)
                                Image(systemName: "plus")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                            Text("Add Block")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    if !sortedPaddocks.isEmpty {
                        Divider().padding(.leading, 16)
                    }
                }
                ForEach(Array(sortedPaddocks.enumerated()), id: \.element.id) { idx, paddock in
                    Button {
                        paddockToEdit = paddock
                    } label: {
                        BlockSummaryRow(
                            paddock: paddock,
                            varieties: store.grapeVarieties,
                            hasSoilProfile: paddocksWithSoilProfile.contains(paddock.id)
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    if idx < sortedPaddocks.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }

            sectionFooter("Define block boundaries and row layouts for your vineyard.")
        }
    }

    // MARK: - Vineyard Location

    private var vineyardLocationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Vineyard Location", symbol: "location.north.fill", color: .blue)

            cardBackground {
                locationRow(icon: "location.north", iconColor: .primary, title: "Latitude") {
                    HStack(spacing: 4) {
                        TextField("-33.29527", text: $latitudeText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .font(.body.weight(.semibold))
                            .focused($focusedField, equals: .latitude)
                            .onSubmit { saveLatLon() }
                        Text("\u{00B0}").foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.leading, 56)
                locationRow(icon: "location.north", iconColor: .primary, title: "Longitude") {
                    HStack(spacing: 4) {
                        TextField("148.95614", text: $longitudeText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .font(.body.weight(.semibold))
                            .focused($focusedField, equals: .longitude)
                            .onSubmit { saveLatLon() }
                        Text("\u{00B0}").foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.leading, 56)
                locationRow(icon: "mountain.2.fill", iconColor: .primary, title: "Elevation") {
                    HStack(spacing: 4) {
                        TextField("0", text: $elevationText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .font(.body.weight(.semibold))
                            .focused($focusedField, equals: .elevation)
                            .onSubmit { saveElevation() }
                        Text("m").foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.leading, 56)
                locationRow(icon: "thermometer.sun.fill", iconColor: .blue, title: "Calculation") {
                    Picker("", selection: $calculationMode) {
                        ForEach(GDDCalculationMode.allCases, id: \.self) { mode in
                            Text(mode.shortName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: calculationMode) { _, newValue in
                        var s = store.settings
                        s.calculationMode = newValue
                        s.useBEDD = newValue == .bedd
                        store.updateSettings(s)
                    }
                }
                Divider().padding(.leading, 56)
                locationRow(icon: "arrow.uturn.backward.circle", iconColor: .blue, title: "Reset Point") {
                    Picker("", selection: $resetMode) {
                        ForEach(GDDResetMode.allCases, id: \.self) { mode in
                            Label(mode.displayName, systemImage: mode.iconName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: resetMode) { _, newValue in
                        var s = store.settings
                        s.resetMode = newValue
                        store.updateSettings(s)
                    }
                }
            }
            .onChange(of: focusedField) { oldValue, _ in
                switch oldValue {
                case .latitude, .longitude:
                    saveLatLon()
                case .elevation:
                    saveElevation()
                case .none:
                    break
                }
            }

            sectionFooter("Coordinates and elevation improve degree-day accuracy. Standard GDD is base 10\u{00B0}C. BEDD caps daily temps at 19\u{00B0}C, adds a diurnal-range bonus, and applies a day-length factor from latitude. Reset Point determines when accumulation starts each season (overridable per block).")
        }
    }

    private func locationRow<Trailing: View>(icon: String, iconColor: Color, title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
            Text(title)
                .font(.body)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Varieties

    private var varietiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Varieties")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)

            cardBackground {
                NavigationLink {
                    GrapeVarietyManagementView()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "leaf.circle")
                            .font(.title2)
                            .foregroundStyle(.primary)
                            .frame(width: 28, height: 28)
                        Text("Grape Varieties")
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(masterVarietyCount)")
                                .font(.body)
                                .foregroundStyle(.secondary)
                            if customVarietyCount > 0 {
                                Text("+ \(customVarietyCount) custom")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }

            sectionFooter("Master list of grape varieties and their optimal ripeness (Growing Degree Days). Used when assigning varieties to blocks.")
        }
    }

    // MARK: - Export / Import

    private var exportImportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export / Import")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)

            cardBackground {
                Button {
                    exportPaddocks()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28, height: 28)
                        Text("Export Blocks")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Text("\(paddocks.count) block\(paddocks.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .disabled(paddocks.isEmpty || !accessControl.canExport)

                Divider().padding(.leading, 16)

                Button {
                    showImporter = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28, height: 28)
                        Text("Import Blocks")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .disabled(!accessControl.canChangeSettings)
            }

            sectionFooter("Export your block data as JSON to share or back up. Import blocks from a previously exported file.")
        }
    }

    // MARK: - Button Customization

    private var buttonCustomizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Button Customization")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)

            cardBackground {
                buttonCustomizationRow(
                    title: "Repair Buttons",
                    icon: "wrench.and.screwdriver",
                    showsDots: true,
                    buttons: store.repairButtons
                ) {
                    if accessControl.canChangeSettings { showRepairButtons = true }
                }
                Divider().padding(.leading, 56)
                buttonCustomizationRow(
                    title: "Repair Templates",
                    icon: "square.on.square",
                    showsDots: false,
                    buttons: []
                ) { showRepairTemplates = true }
                Divider().padding(.leading, 56)
                buttonCustomizationRow(
                    title: "Growth Buttons",
                    icon: "leaf",
                    showsDots: true,
                    buttons: store.growthButtons
                ) {
                    if accessControl.canChangeSettings { showGrowthButtons = true }
                }
                Divider().padding(.leading, 56)
                buttonCustomizationRow(
                    title: "Growth Templates",
                    icon: "square.on.square",
                    showsDots: false,
                    buttons: []
                ) { showGrowthTemplates = true }
            }

            sectionFooter("Customize buttons directly or create templates to quickly switch between different button sets. Templates pair rows left and right.")
        }
    }

    private func buttonCustomizationRow(title: String, icon: String, showsDots: Bool, buttons: [ButtonConfig], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if showsDots {
                    HStack(spacing: 6) {
                        ForEach(Array(buttons.sorted { $0.index < $1.index }.prefix(4))) { btn in
                            Circle()
                                .fill(Color.fromString(btn.color))
                                .frame(width: 9, height: 9)
                        }
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Growth Stages

    private var growthStagesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Growth Stages")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)

            cardBackground {
                Button {
                    showGrowthStagesPicker = true
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "leaf.arrow.triangle.circlepath")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28, height: 28)
                        Text("E-L Growth Stages")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Text("\(store.settings.enabledGrowthStageCodes.count)/\(GrowthStage.allStages.count)")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor.opacity(0.7))
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)

                Divider().padding(.leading, 56)

                NavigationLink {
                    GrowthStageImagesSettingsView()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .frame(width: 28, height: 28)
                        Text("Growth Stage Images")
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }

            sectionFooter("Configure which E-L growth stages are available and manage reference images for visual confirmation.")
        }
    }

    // MARK: - Region & Units (drill-in)

    private var regionUnitsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Region", symbol: "globe", color: .teal)

            cardBackground {
                NavigationLink {
                    RegionUnitsSettingsView()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "ruler")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Region & Units")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(regionUnitsSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }

            sectionFooter("Set the country, currency, units, date format and terminology used to display and export records. These settings never change stored records. Owners and managers only.")
        }
    }

    private var regionUnitsSummary: String {
        let r = store.settings.regionSettings
        return [r.countryCode, r.currencyCode, r.area.abbreviation, r.dateStyle.rawValue].joined(separator: " \u{00B7} ")
    }

    // MARK: - Weather Data & Forecasting (drill-in)

    private var weatherDataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Weather", symbol: "cloud.sun.fill", color: .orange)

            cardBackground {
                NavigationLink {
                    WeatherDataSettingsView()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: weatherSummary.symbol)
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Weather Data & Forecasting")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(weatherSummary.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }

            sectionFooter("Manage forecast and local observation sources, station credentials and rainfall backfill from a single place.")
        }
    }

    private func reloadWeatherSummary() {
        guard let vid = store.selectedVineyardId else {
            weatherSummary = .empty
            return
        }
        let cfg = WeatherProviderStore.shared.config(for: vid)
        weatherSummary = WeatherSummaryInfo.from(config: cfg)
    }

    // MARK: - Settings IO

    private func loadFromSettings() {
        let s = store.settings
        latitudeText = s.vineyardLatitude.map { String(format: "%.5f", $0) } ?? ""
        longitudeText = s.vineyardLongitude.map { String(format: "%.5f", $0) } ?? ""
        elevationText = s.vineyardElevationMetres.map { String(format: "%.0f", $0) } ?? ""
        calculationMode = s.calculationMode
        resetMode = s.resetMode
    }

    private func saveLatLon() {
        // Guard against saving before a vineyard is selected — would persist under
        // a stray UUID key in SettingsRepository and silently disappear on next load.
        guard let vid = store.selectedVineyardId else { return }
        var s = store.settings
        s.vineyardId = vid
        s.vineyardLatitude = Double(latitudeText.trimmingCharacters(in: .whitespaces))
        s.vineyardLongitude = Double(longitudeText.trimmingCharacters(in: .whitespaces))
        store.updateSettings(s)
        pushLocationToBackend(vineyardId: vid, settings: s)
    }

    private func saveElevation() {
        guard let vid = store.selectedVineyardId else { return }
        var s = store.settings
        s.vineyardId = vid
        let trimmed = elevationText.trimmingCharacters(in: .whitespaces)
        // Strip any trailing unit suffix like "m" so values like "120m" still parse.
        let numeric = trimmed.replacingOccurrences(
            of: "[^0-9.\\-]",
            with: "",
            options: .regularExpression
        )
        s.vineyardElevationMetres = numeric.isEmpty ? nil : Double(numeric)
        store.updateSettings(s)
        pushLocationToBackend(vineyardId: vid, settings: s)
    }

    /// Persist the vineyard's lat/long/elevation/timezone to Supabase so other
    /// devices and the Lovable portal see the same values. Local AppSettings
    /// still acts as an offline cache via `SettingsRepository`.
    private func pushLocationToBackend(vineyardId: UUID, settings: AppSettings) {
        let repo = vineyardRepositoryForLocation
        let lat = settings.vineyardLatitude
        let lon = settings.vineyardLongitude
        let elev = settings.vineyardElevationMetres
        let tz = settings.timezone.isEmpty ? nil : settings.timezone
        Task.detached {
            _ = try? await repo.setVineyardLocation(
                vineyardId: vineyardId,
                latitude: lat,
                longitude: lon,
                elevationMetres: elev,
                timezone: tz
            )
        }
    }

    /// Loads the active built-in count from the shared grape-variety
    /// catalogue cache so the master Grape Varieties card reflects the
    /// real catalogue size (currently ~67 active built-ins) rather than
    /// only the vineyard-scoped selections.
    private func loadSharedCatalogCount() async {
        let cache = SharedGrapeVarietyCatalogCache.shared
        let cached = cache.loadCached()
        if !cached.isEmpty {
            sharedCatalogCount = cached.filter { $0.isActive }.count
        }
        let fresh = await cache.refresh()
        let active = fresh.filter { $0.isActive }.count
        if active > 0 {
            sharedCatalogCount = active
        }
    }

    private func loadPaddockSoilProfileIds() async {
        guard let vid = store.selectedVineyardId else {
            paddocksWithSoilProfile = []
            return
        }
        do {
            let rows = try await soilProfileRepositoryForChecklist.listVineyardSoilProfiles(vineyardId: vid)
            paddocksWithSoilProfile = Set(rows.compactMap { $0.paddockId })
        } catch {
            // Silent — checklist will show red cross for soil until reload.
        }
    }

    // MARK: - Import/Export

    private var importSummaryBinding: Binding<Bool> {
        Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })
    }
    private var importErrorBinding: Binding<Bool> {
        Binding(get: { importErrorMessage != nil }, set: { if !$0 { importErrorMessage = nil } })
    }

    private func exportPaddocks() {
        let data = PaddockJSONService.generateJSON(paddocks: paddocks, vineyardId: store.selectedVineyardId)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: Date())
        let vineyardName = store.selectedVineyard?.name ?? "Vineyard"
        let safeName = vineyardName.replacingOccurrences(of: " ", with: "_")
        let url = PaddockJSONService.saveJSONToTemp(data: data, fileName: "\(safeName)_blocks_\(dateString).json")
        shareURL = ShareURL(url: url)
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            importPaddocks(from: url)
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        }
    }

    private func importPaddocks(from url: URL) {
        guard let vineyardId = store.selectedVineyardId else {
            importErrorMessage = "Select a vineyard before importing."
            return
        }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            let existing = store.paddocks
            let result = try PaddockJSONService.parseJSON(data: data, vineyardId: vineyardId, existing: existing)
            let existingIds = Set(existing.map(\.id))
            for paddock in result.paddocks {
                if existingIds.contains(paddock.id) {
                    store.updatePaddock(paddock)
                } else {
                    store.addPaddock(paddock)
                }
            }
            importSummary = result.summary
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - Block Summary Row

private struct BlockSummaryRow: View {
    let paddock: Paddock
    let varieties: [GrapeVariety]
    let hasSoilProfile: Bool

    private var rowRange: String {
        let nums = paddock.rows.map { $0.number }.sorted()
        if let first = nums.first, let last = nums.last {
            if first == last {
                return "Row \(first)"
            }
            return "Row \(first) to Row \(last)"
        }
        return "No rows"
    }

    private var vinesText: String {
        let count = paddock.effectiveVineCount
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(paddock.name)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.accentColor)

            HStack(spacing: 8) {
                Text(rowRange)
                Text("\u{2022}")
                Text("\(paddock.rows.count) rows")
                Text("\u{2022}")
                Text("\(vinesText) vines")
            }
            .font(.subheadline)
            .foregroundStyle(Color.accentColor.opacity(0.75))

            if !irrigationSummary.isEmpty {
                Text(irrigationSummary)
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor.opacity(0.75))
            }

            BlockSetupChecklist(
                boundariesOk: boundariesComplete,
                rowsOk: rowsComplete,
                trellisOk: trellisComplete,
                varietiesOk: varietiesComplete,
                irrigationOk: irrigationComplete,
                soilOk: hasSoilProfile
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Checklist completion logic

    private var boundariesComplete: Bool {
        paddock.polygonPoints.count >= 3
    }

    private var rowsComplete: Bool {
        !paddock.rows.isEmpty
    }

    private var trellisComplete: Bool {
        // Row spacing is the irrigation-critical trellis value.
        paddock.rowWidth > 0
    }

    private var varietiesComplete: Bool {
        let allocations = paddock.varietyAllocations
        guard !allocations.isEmpty else { return false }
        let totalPercent = allocations.reduce(0.0) { $0 + $1.percent }
        guard abs(totalPercent - 100.0) < 0.5 else { return false }
        // Every allocation must resolve to a real variety (built-in or custom with stable key + name).
        for alloc in allocations {
            let resolved = PaddockVarietyResolver.resolve(allocation: alloc, varieties: varieties)
            guard resolved.isResolved else { return false }
            let name = resolved.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty || name.localizedCaseInsensitiveCompare("Unknown") == .orderedSame {
                return false
            }
        }
        return true
    }

    private var irrigationSummary: String {
        var parts: [String] = []
        if let flow = paddock.flowPerEmitter, flow > 0 {
            parts.append(String(format: "%.1f L/hr", flow))
        }
        if let mm = paddock.mmPerHour, mm > 0 {
            parts.append(String(format: "%.2f mm/hr", mm))
        }
        return parts.joined(separator: " \u{2022} ")
    }

    private var irrigationComplete: Bool {
        guard let mm = paddock.mmPerHour, mm > 0 else { return false }
        guard let flow = paddock.flowPerEmitter, flow > 0 else { return false }
        guard let spacing = paddock.emitterSpacing, spacing > 0 else { return false }
        return paddock.rowWidth > 0
    }
}

// MARK: - Setup Checklist

private struct BlockSetupChecklist: View {
    let boundariesOk: Bool
    let rowsOk: Bool
    let trellisOk: Bool
    let varietiesOk: Bool
    let irrigationOk: Bool
    let soilOk: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                item("Boundaries", ok: boundariesOk)
                item("Rows", ok: rowsOk)
                item("Trellis", ok: trellisOk)
            }
            HStack(spacing: 10) {
                item("Varieties", ok: varietiesOk)
                item("Irrigation", ok: irrigationOk)
                item("Soil", ok: soilOk)
            }
        }
        .padding(.top, 2)
    }

    private func item(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(ok ? Color.green : Color.red)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Mini Map

private struct VineyardBlocksMiniMap: View {
    let paddocks: [Paddock]
    @Binding var selectedPaddock: Paddock?
    var onAddBlock: (() -> Void)?

    @Environment(LocationService.self) private var locationService
    @State private var position: MapCameraPosition = .automatic
    @State private var hasSetInitialPosition: Bool = false
    @State private var showFullScreen: Bool = false

    private var blockColors: [UUID: Color] {
        let palette: [Color] = [.blue, .green, .orange, .purple, .red, .cyan, .mint, .indigo, .pink, .teal, .yellow, .brown]
        var map: [UUID: Color] = [:]
        for (i, paddock) in paddocks.enumerated() {
            map[paddock.id] = palette[i % palette.count]
        }
        return map
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Map(position: $position) {
                ForEach(paddocks) { paddock in
                    if paddock.polygonPoints.count > 2 {
                        let color = blockColors[paddock.id] ?? .blue
                        MapPolygon(coordinates: paddock.polygonPoints.map { $0.coordinate })
                            .foregroundStyle(color.opacity(0.30))
                            .stroke(color, lineWidth: 2.5)
                        Annotation("", coordinate: paddock.polygonPoints.centroid) {
                            Button { selectedPaddock = paddock } label: {
                                Text(paddock.name)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(color.opacity(0.9), in: .rect(cornerRadius: 8))
                                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                            }
                        }
                    }
                }
                UserAnnotation()
            }
            .mapStyle(.hybrid)

            VStack(spacing: 10) {
                if let onAddBlock {
                    Button {
                        onAddBlock()
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor, in: .circle)
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    }
                }
                Button {
                    // Layers placeholder - cycles map style if you want; here it's decorative
                } label: {
                    Image(systemName: "square.3.layers.3d")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.55), in: .circle)
                }
                Button {
                    showFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.55), in: .circle)
                }
            }
            .padding(10)
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenSetupBlocksMap(
                paddocks: paddocks,
                blockColors: blockColors,
                onSelectPaddock: { selectedPaddock = $0 }
            )
        }
        .onAppear { fitInitialPosition() }
        .onChange(of: locationService.location) { _, newLocation in
            if !hasSetInitialPosition,
               let loc = newLocation,
               paddocks.allSatisfy({ $0.polygonPoints.count < 3 }) {
                position = .camera(MapCamera(centerCoordinate: loc.coordinate, distance: 1000))
                hasSetInitialPosition = true
            }
        }
    }

    private func fitInitialPosition() {
        let blocksWithBounds = paddocks.filter { $0.polygonPoints.count > 2 }
        guard !blocksWithBounds.isEmpty else {
            if let loc = locationService.location {
                position = .camera(MapCamera(centerCoordinate: loc.coordinate, distance: 1000))
                hasSetInitialPosition = true
            }
            return
        }
        let allPoints = paddocks.flatMap { $0.polygonPoints }
        guard !allPoints.isEmpty else { return }
        let minLat = allPoints.map(\.latitude).min()!
        let maxLat = allPoints.map(\.latitude).max()!
        let minLon = allPoints.map(\.longitude).min()!
        let maxLon = allPoints.map(\.longitude).max()!
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.4 + 0.001,
            longitudeDelta: (maxLon - minLon) * 1.4 + 0.001
        )
        position = .region(MKCoordinateRegion(center: center, span: span))
        hasSetInitialPosition = true
    }
}

private struct FullScreenSetupBlocksMap: View {
    let paddocks: [Paddock]
    let blockColors: [UUID: Color]
    let onSelectPaddock: (Paddock) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                ForEach(paddocks) { paddock in
                    if paddock.polygonPoints.count > 2 {
                        let color = blockColors[paddock.id] ?? .blue
                        MapPolygon(coordinates: paddock.polygonPoints.map { $0.coordinate })
                            .foregroundStyle(color.opacity(0.25))
                            .stroke(color, lineWidth: 2.5)
                        Annotation("", coordinate: paddock.polygonPoints.centroid) {
                            Button {
                                onSelectPaddock(paddock)
                                dismiss()
                            } label: {
                                Text(paddock.name)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(color.opacity(0.9), in: .rect(cornerRadius: 8))
                                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                            }
                        }
                    }
                }
                UserAnnotation()
            }
            .mapStyle(.hybrid)
            .ignoresSafeArea()
            .navigationTitle("Blocks Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .onAppear { fitAllBlocks() }
        }
    }

    private func fitAllBlocks() {
        let allPoints = paddocks.flatMap { $0.polygonPoints }
        guard !allPoints.isEmpty else { return }
        let minLat = allPoints.map(\.latitude).min()!
        let maxLat = allPoints.map(\.latitude).max()!
        let minLon = allPoints.map(\.longitude).min()!
        let maxLon = allPoints.map(\.longitude).max()!
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.4 + 0.001,
            longitudeDelta: (maxLon - minLon) * 1.4 + 0.001
        )
        position = .region(MKCoordinateRegion(center: center, span: span))
    }
}

struct SprayEquipmentHubView: View {
    @Environment(BackendAccessControl.self) private var accessControl

    var body: some View {
        List {
            Section {
                NavigationLink {
                    SprayManagementSettingsView()
                } label: {
                    SettingsRow(
                        title: "Spray Management",
                        subtitle: "Presets and programs",
                        symbol: "drop.fill",
                        color: .teal
                    )
                }
                NavigationLink {
                    EquipmentManagementView()
                } label: {
                    SettingsRow(
                        title: "Equipment & Tractors",
                        subtitle: "Sprayers, tractors, fuel",
                        symbol: "wrench.and.screwdriver.fill",
                        color: VineyardTheme.earthBrown
                    )
                }
                NavigationLink {
                    ChemicalsManagementView()
                } label: {
                    SettingsRow(
                        title: "Chemicals",
                        subtitle: "Saved chemical library",
                        symbol: "flask.fill",
                        color: .purple
                    )
                }
                NavigationLink {
                    SavedInputsManagementView()
                } label: {
                    SettingsRow(
                        title: "Saved Inputs",
                        subtitle: "Seed, fertiliser & inputs library",
                        symbol: "leaf.fill",
                        color: VineyardTheme.leafGreen
                    )
                }
            } header: {
                SettingsSectionHeader(title: "Spray & Equipment", symbol: "drop.fill", color: .teal)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Spray & Equipment")
    }
}

struct TeamOperationsHubView: View {
    @Environment(MigratedDataStore.self) private var store

    var body: some View {
        List {
            Section {
                NavigationLink {
                    OperatorCategoriesView()
                } label: {
                    SettingsRow(
                        title: "Operator Categories",
                        subtitle: "\(currentVineyardOperatorCategories) categor\(currentVineyardOperatorCategories == 1 ? "y" : "ies")",
                        symbol: "person.badge.clock.fill",
                        color: .blue
                    )
                }
            } header: {
                SettingsSectionHeader(title: "Team Operations", symbol: "person.2.fill", color: .blue)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Team Operations")
    }

    private var currentVineyardOperatorCategories: Int {
        guard let vid = store.selectedVineyardId else { return 0 }
        return store.operatorCategories.filter { $0.vineyardId == vid }.count
    }
}

// MARK: - Weather summary helper

/// Compact summary of the active weather provider configuration for
/// the Vineyard Setup drill-in row. The full configuration UI lives
/// in WeatherDataSettingsView. This is purely a glanceable label so
/// users know which source is active without opening the screen.
private struct WeatherSummaryInfo {
    let symbol: String
    let detail: String

    static let empty = WeatherSummaryInfo(
        symbol: "cloud.sun.fill",
        detail: "Tap to configure forecast and local station sources."
    )

    static func from(config: WeatherProviderConfig) -> WeatherSummaryInfo {
        var parts: [String] = []

        switch config.forecastProvider {
        case .auto:
            if let name = config.willyWeatherLocationName, !name.isEmpty {
                parts.append("WillyWeather · \(name)")
            } else {
                parts.append("Auto forecast (Open-Meteo)")
            }
        case .willyWeather:
            if let name = config.willyWeatherLocationName, !name.isEmpty {
                parts.append("WillyWeather · \(name)")
            } else {
                parts.append("WillyWeather (no location)")
            }
        case .openMeteo:
            parts.append("Open-Meteo forecast")
        }

        switch config.localObservationProvider {
        case .none:
            break
        case .davis:
            if let name = config.davisStationName, !name.isEmpty {
                parts.append("Davis · \(name)")
            } else {
                parts.append("Davis WeatherLink")
            }
        case .wunderground:
            parts.append("Weather Underground PWS")
        }

        let symbol: String
        switch config.localObservationProvider {
        case .davis: symbol = "sensor.tag.radiowaves.forward.fill"
        case .wunderground: symbol = "antenna.radiowaves.left.and.right"
        case .none:
            symbol = config.forecastProvider == .willyWeather
                ? "sun.rain.fill"
                : "cloud.sun.fill"
        }

        let detail = parts.isEmpty
            ? "Tap to configure forecast and local station sources."
            : parts.joined(separator: " • ")

        return WeatherSummaryInfo(symbol: symbol, detail: detail)
    }
}

import SwiftUI
import CoreLocation

enum GrowthStageMode: String, CaseIterable {
    case same
    case perPaddock
}

struct SprayCalculatorView: View {
    @Environment(DataStore.self) private var store
    @Environment(TripTrackingService.self) private var trackingService
    @Environment(LocationService.self) private var locationService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessControl) private var accessControl

    @State private var selectedPaddockIds: Set<UUID> = []
    @State private var selectedEquipmentId: UUID?
    @State private var operationType: OperationType = .foliarSpray
    @State private var canopySize: CanopySize = .medium
    @State private var canopyDensity: CanopyDensity = .low
    @State private var chemicalLines: [ChemicalLine] = []
    @State private var calculationResult: SprayCalculationResult?
    @State private var showResults: Bool = false
    @State private var sprayName: String = ""
    @State private var notes: String = ""
    @State private var savedFeedback: Bool = false
    @State private var isPaddocksExpanded: Bool = true
    @State private var isEquipmentExpanded: Bool = true
    @State private var paddockPhenologyStages: [UUID: UUID] = [:]
    @State private var growthStageMode: GrowthStageMode = .same
    @State private var sharedGrowthStageId: UUID?
    @State private var sprayRateText: String = ""
    @State private var hasEditedSprayRate: Bool = false
    @State private var showStartConfirmation: Bool = false
    @State private var isSavingAndStarting: Bool = false
    @State private var showAddChemicalToList: Bool = false
    @State private var showAddEquipment: Bool = false
    @State private var weatherDataService = WeatherDataService()
    @State private var showCalculationSummary: Bool = false
    @State private var summaryJobStarted: Bool = false
    @State private var editingChemical: SavedChemical?
    @State private var scrollTarget: String?
    @State private var showWeatherMissingAlert: Bool = false
    @State private var showUCRInfo: Bool = false
    @State private var pendingStartParams: (Tractor?, String, String, TrackingPattern, StartDirection, String)?

    private var averageRowSpacing: Double {
        let selected = store.paddocks.filter { selectedPaddockIds.contains($0.id) }
        guard !selected.isEmpty else { return 2.8 }
        return selected.reduce(0) { $0 + $1.rowSpacingMetres } / Double(selected.count)
    }

    private var waterRateEntry: CanopyWaterRate.RateEntry {
        CanopyWaterRate.rate(size: canopySize, density: canopyDensity, rowSpacingMetres: averageRowSpacing, settings: store.settings.canopyWaterRates)
    }

    private var chosenSprayRate: Double {
        Double(sprayRateText) ?? waterRateEntry.litresPerHa
    }

    private var concentrationFactor: Double {
        guard chosenSprayRate > 0 else { return 1.0 }
        return waterRateEntry.litresPerHa / chosenSprayRate
    }

    private var formIsValid: Bool {
        !selectedPaddockIds.isEmpty && selectedEquipmentId != nil && !chemicalLines.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        sprayNameSection
                        operationTypeSection
                        paddockSelection
                        growthStageSection
                        equipmentSelection
                        waterRateSection
                        irrigationDataSection
                        chemicalLinesSection
                        notesSection
                        actionButtons

                        if showResults, let result = calculationResult {
                            ResultsCard(result: result)

                            if let costing = result.costingSummary, accessControl?.canViewFinancials ?? false {
                                CostingsCard(summary: costing)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: scrollTarget) { _, target in
                    if let target {
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                            scrollTarget = nil
                        }
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Spray Calculator")
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.success, trigger: savedFeedback)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }

            .sheet(isPresented: $showCalculationSummary, onDismiss: {
                if summaryJobStarted {
                    store.selectedTab = 2
                }
                dismiss()
            }) {
                if let result = calculationResult {
                    SprayCalculationSummarySheet(result: result, sprayName: sprayName, jobStarted: summaryJobStarted)
                }
            }
            .sheet(isPresented: $showAddChemicalToList) {
                EditSavedChemicalSheet(chemical: nil)
            }
            .sheet(item: $editingChemical) { chem in
                EditSavedChemicalSheet(chemical: chem)
            }
            .sheet(isPresented: $showAddEquipment) {
                AddSprayEquipmentSheet()
            }
            .sheet(isPresented: $showUCRInfo) {
                UCRInfoSheet()
            }
            .sheet(isPresented: $showStartConfirmation) {
                CalcStartJobSheet(
                    store: store,
                    selectedPaddockIds: selectedPaddockIds,
                    isSaving: $isSavingAndStarting,
                    onConfirm: { tractor, fansJets, gear, pattern, direction, operatorName in
                        Task { await saveAndStartJob(tractor: tractor, numberOfFansJets: fansJets, tractorGear: gear, trackingPattern: pattern, startDirection: direction, operatorName: operatorName) }
                    }
                )
                .presentationDetents([.large])
            }
            .alert("Weather Data Unavailable", isPresented: $showWeatherMissingAlert) {
                Button("Start Without Weather") {
                    if let params = pendingStartParams {
                        Task { await proceedWithoutWeather(tractor: params.0, numberOfFansJets: params.1, tractorGear: params.2, trackingPattern: params.3, startDirection: params.4, operatorName: params.5) }
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingStartParams = nil
                }
            } message: {
                Text(weatherDataService.errorMessage ?? "Could not fetch weather data. The spray record will be saved without weather conditions.")
            }
        }
    }

    // MARK: - Spray Name

    private var sprayNameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Spray Name", icon: "tag")
            TextField("e.g. Downy Mildew Spray #3", text: $sprayName)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
        }
    }

    // MARK: - Helpers

    private func phenologyStageName(for paddockId: UUID) -> String? {
        guard let stageId = paddockPhenologyStages[paddockId] else { return nil }
        return store.phenologyStages.first(where: { $0.id == stageId }).map { "\($0.name) (\($0.code))" }
    }

    // MARK: - Paddock Selection

    private var paddockSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    isPaddocksExpanded.toggle()
                }
            } label: {
                HStack {
                    PaddockSectionHeader(title: "Paddocks")
                    Spacer()
                    if !selectedPaddockIds.isEmpty {
                        Text("\(selectedPaddockIds.count) selected")
                            .font(.caption)
                            .foregroundStyle(VineyardTheme.olive)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isPaddocksExpanded ? 90 : 0))
                }
            }

            if isPaddocksExpanded {
                VStack(spacing: 0) {
                    ForEach(store.paddocks) { paddock in
                        let isSelected = selectedPaddockIds.contains(paddock.id)
                        VStack(spacing: 0) {
                            Button {
                                if isSelected {
                                    selectedPaddockIds.remove(paddock.id)
                                    paddockPhenologyStages.removeValue(forKey: paddock.id)
                                } else {
                                    selectedPaddockIds.insert(paddock.id)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.tertiary))
                                    Text(paddock.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(paddock.areaHectares, specifier: "%.2f") ha")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                            }

                            if paddock.id != store.paddocks.last?.id {
                                Divider().padding(.leading, 40)
                            }
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !selectedPaddockIds.isEmpty {
                let totalArea = store.paddocks.filter { selectedPaddockIds.contains($0.id) }.reduce(0) { $0 + $1.areaHectares }
                Text("Total: \(totalArea, specifier: "%.2f") ha selected")
                    .font(.caption)
                    .foregroundStyle(VineyardTheme.olive)
            }
        }
    }

    // MARK: - Growth Stage Section

    private var growthStageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Growth Stage", icon: "leaf.arrow.circlepath")

            if selectedPaddockIds.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Select paddocks above to assign growth stages")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
            } else {
                Picker("", selection: $growthStageMode) {
                    Text("Same for All").tag(GrowthStageMode.same)
                    Text("Per Paddock").tag(GrowthStageMode.perPaddock)
                }
                .pickerStyle(.segmented)
                .onChange(of: growthStageMode) { _, newMode in
                    if newMode == .same {
                        if let shared = sharedGrowthStageId {
                            for pid in selectedPaddockIds {
                                paddockPhenologyStages[pid] = shared
                            }
                        }
                    }
                }

                if growthStageMode == .same {
                    sameGrowthStageList
                } else {
                    perPaddockGrowthStageList
                }
            }
        }
    }

    private var sameGrowthStageList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("E-L Growth Stages")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Button {
                sharedGrowthStageId = nil
                for pid in selectedPaddockIds {
                    paddockPhenologyStages.removeValue(forKey: pid)
                }
            } label: {
                HStack {
                    Image(systemName: sharedGrowthStageId == nil ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(sharedGrowthStageId == nil ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.tertiary))
                    Text("Not Set")
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Divider().padding(.leading, 40)

            ForEach(store.phenologyStages) { stage in
                let isSelected = sharedGrowthStageId == stage.id
                Button {
                    sharedGrowthStageId = stage.id
                    for pid in selectedPaddockIds {
                        paddockPhenologyStages[pid] = stage.id
                    }
                } label: {
                    HStack {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isSelected ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.tertiary))
                        Text(stage.code)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 56, alignment: .leading)
                        Text(stage.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                if stage.id != store.phenologyStages.last?.id {
                    Divider().padding(.leading, 40)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    private var perPaddockGrowthStageList: some View {
        let selectedPaddocks = store.paddocks.filter { selectedPaddockIds.contains($0.id) }
        return VStack(spacing: 0) {
            ForEach(selectedPaddocks) { paddock in
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(paddock.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            if let stageName = phenologyStageName(for: paddock.id) {
                                Text(stageName)
                                    .font(.caption2)
                                    .foregroundStyle(VineyardTheme.leafGreen)
                            }
                        }
                        Spacer()
                        Menu {
                            Button("Not Set") {
                                paddockPhenologyStages.removeValue(forKey: paddock.id)
                            }
                            ForEach(store.phenologyStages) { stage in
                                Button("\(stage.code) – \(stage.name)") {
                                    paddockPhenologyStages[paddock.id] = stage.id
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if let stageId = paddockPhenologyStages[paddock.id],
                                   let stage = store.phenologyStages.first(where: { $0.id == stageId }) {
                                    Text(stage.code)
                                        .font(.caption.weight(.semibold))
                                } else {
                                    Text("Select")
                                        .font(.caption)
                                }
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                            }
                            .foregroundStyle(VineyardTheme.olive)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(VineyardTheme.olive.opacity(0.1))
                            .clipShape(.rect(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    if paddock.id != selectedPaddocks.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }

    // MARK: - Equipment Selection

    private var equipmentSelection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    isEquipmentExpanded.toggle()
                }
            } label: {
                HStack {
                    SectionHeader(title: "Equipment", icon: "wrench.and.screwdriver")
                    Spacer()
                    if let eqId = selectedEquipmentId, let eq = store.equipment.first(where: { $0.id == eqId }) {
                        Text(eq.name)
                            .font(.caption)
                            .foregroundStyle(VineyardTheme.olive)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isEquipmentExpanded ? 90 : 0))
                }
            }

            if isEquipmentExpanded {
                VStack(spacing: 0) {
                    if store.equipment.isEmpty {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.tertiary)
                            Text("No equipment configured")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }

                    ForEach(store.equipment) { item in
                        let isSelected = selectedEquipmentId == item.id
                        Button {
                            selectedEquipmentId = item.id
                        } label: {
                            HStack {
                                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(isSelected ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.tertiary))
                                Text(item.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(item.tankCapacityLitres, specifier: "%.0f") L")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }

                        if item.id != store.equipment.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
                .transition(.opacity.combined(with: .move(edge: .top)))

                Button {
                    showAddEquipment = true
                } label: {
                    Label("Add Equipment", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(VineyardTheme.olive)
                }
            }
        }
    }

    // MARK: - Operation Type

    private var operationTypeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Operation Type", icon: "gearshape.2")

            VStack(spacing: 0) {
                ForEach(OperationType.allCases, id: \.self) { type in
                    let isSelected = operationType == type
                    Button {
                        operationType = type
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(isSelected ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.tertiary))
                            Image(systemName: type.iconName)
                                .font(.subheadline)
                                .foregroundStyle(isSelected ? VineyardTheme.olive : .secondary)
                                .frame(width: 24)
                            Text(type.rawValue)
                                .foregroundStyle(.primary)
                            Spacer()
                            if !type.useConcentrationFactor {
                                Text("No CF")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(.tertiarySystemGroupedBackground))
                                    .clipShape(.rect(cornerRadius: 4))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }

                    if type != OperationType.allCases.last {
                        Divider().padding(.leading, 48)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 10))
        }
    }

    // MARK: - Water Rate

    private var waterRateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Calculated Water Rate", icon: "drop.fill")
            Text("Based on row widths & canopy status")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("VSP Canopy Size")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Button {
                            showUCRInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                        }
                    }
                    Picker("Canopy Size", selection: $canopySize) {
                        ForEach(CanopySize.allCases, id: \.self) { size in
                            Text(size.rawValue).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(canopySize.description)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let imageURL = canopySize.referenceImageURL {
                        HStack {
                            Spacer()
                            Color.clear
                                .frame(width: 100, height: 100)
                                .overlay {
                                    AsyncImage(url: imageURL) { phase in
                                        if let image = phase.image {
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                        } else if phase.error != nil {
                                            GrapeLeafIcon(size: 28)
                                                .foregroundStyle(.tertiary)
                                        } else {
                                            ProgressView()
                                        }
                                    }
                                    .allowsHitTesting(false)
                                }
                                .clipShape(.rect(cornerRadius: 8))
                            Spacer()
                        }
                        .padding(.top, 4)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Canopy Density")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("Canopy Density", selection: $canopyDensity) {
                        ForEach(CanopyDensity.allCases, id: \.self) { density in
                            Text(density.rawValue).tag(density)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Volume")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.0f", waterRateEntry.litresPerHa)) L/ha")
                            .font(.title3.bold())
                            .foregroundStyle(VineyardTheme.olive)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Per 100m row")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.0f", waterRateEntry.litresPer100m)) L")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
                .padding(12)
                .background(VineyardTheme.olive.opacity(0.08))
                .clipShape(.rect(cornerRadius: 10))

                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.caption2)
                    Text("Row spacing: \(String(format: "%.1f", averageRowSpacing))m")
                        .font(.caption)
                    if selectedPaddockIds.count > 1 {
                        Text("(avg of \(selectedPaddockIds.count) paddocks)")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.tertiary)

                if operationType.useConcentrationFactor {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Spray Rate & Concentration Factor")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Chosen Spray Rate (L/ha)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("L/ha", text: $sprayRateText)
                                    .keyboardType(.decimalPad)
                                    .font(.body.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(Color(.tertiarySystemGroupedBackground))
                                    .clipShape(.rect(cornerRadius: 8))
                                    .onChange(of: sprayRateText) { _, _ in
                                        hasEditedSprayRate = true
                                    }
                            }

                            VStack(alignment: .trailing, spacing: 4) {
                                Text("CF")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.2f", concentrationFactor))
                                    .font(.title2.bold())
                                    .foregroundStyle(concentrationFactor == 1.0 ? VineyardTheme.olive : .orange)
                            }
                            .frame(minWidth: 60)
                        }

                        if concentrationFactor != 1.0 {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle")
                                    .font(.caption2)
                                Text(concentrationFactor > 1.0
                                    ? "Concentrate: per 100L rates multiplied by \(String(format: "%.2f", concentrationFactor))×"
                                    : "Dilute: per 100L rates multiplied by \(String(format: "%.2f", concentrationFactor))×")
                                    .font(.caption)
                            }
                            .foregroundStyle(.orange)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                        Text("Concentration factor not applied for \(operationType.rawValue)")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 10))
        }
        .onChange(of: waterRateEntry.litresPerHa) { _, newValue in
            if !hasEditedSprayRate {
                sprayRateText = String(format: "%.0f", newValue)
            }
        }
        .onAppear {
            if sprayRateText.isEmpty {
                sprayRateText = String(format: "%.0f", waterRateEntry.litresPerHa)
            }
        }
    }

    // MARK: - Irrigation Data

    private var irrigationDataSection: some View {
        let selectedPaddocks = store.paddocks.filter { selectedPaddockIds.contains($0.id) }
        let paddocksWithIrrigation = selectedPaddocks.filter { $0.litresPerHaPerHour != nil }

        return Group {
            if !paddocksWithIrrigation.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Irrigation Data", icon: "drop.circle.fill")
                    Text("Based on dripper spacing & flow rates")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 0) {
                        ForEach(paddocksWithIrrigation) { paddock in
                            if let lPerHaHr = paddock.litresPerHaPerHour,
                               let mlPerHaHr = paddock.mlPerHaPerHour,
                               let mmHr = paddock.mmPerHour {
                                VStack(spacing: 8) {
                                    HStack {
                                        Text(paddock.name)
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                    }

                                    HStack(spacing: 16) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("L/ha/hr")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text(String(format: "%.0f", lPerHaHr))
                                                .font(.title3.bold())
                                                .foregroundStyle(.blue)
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("ML/ha/hr")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text(String(format: "%.4f", mlPerHaHr))
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.blue)
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("mm/hr")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            Text(String(format: "%.2f", mmHr))
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.teal)
                                        }

                                        Spacer()
                                    }
                                }
                                .padding(12)

                                if paddock.id != paddocksWithIrrigation.last?.id {
                                    Divider().padding(.leading, 12)
                                }
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 10))

                    if paddocksWithIrrigation.count > 1 {
                        let avgLPerHaHr = paddocksWithIrrigation.compactMap(\.litresPerHaPerHour).reduce(0, +) / Double(paddocksWithIrrigation.count)
                        let avgMlPerHaHr = avgLPerHaHr / 1_000_000.0
                        let avgMmHr = avgMlPerHaHr * 100.0

                        HStack(spacing: 16) {
                            Image(systemName: "chart.bar.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Average across \(paddocksWithIrrigation.count) blocks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(String(format: "%.0f", avgLPerHaHr)) L/ha/hr  \u{2022}  \(String(format: "%.4f", avgMlPerHaHr)) ML/ha/hr  \u{2022}  \(String(format: "%.2f", avgMmHr)) mm/hr")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.blue)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(.rect(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: - Chemical Lines

    private var chemicalLinesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Chemicals", icon: "flask")

            ForEach($chemicalLines) { $line in
                CalcChemicalLineCard(line: $line, chemicals: store.chemicals, onEdit: { chem in
                    editingChemical = chem
                }, scrollTarget: $scrollTarget) {
                    chemicalLines.removeAll { $0.id == line.id }
                }
            }

            Button {
                if let match = store.chemicals.lazy.compactMap({ chem -> (SavedChemical, ChemicalRate)? in
                    guard let rate = chem.rates.first else { return nil }
                    return (chem, rate)
                }).first {
                    chemicalLines.append(ChemicalLine(chemicalId: match.0.id, selectedRateId: match.1.id, basis: match.1.basis))
                } else if let firstChemical = store.chemicals.first {
                    chemicalLines.append(ChemicalLine(chemicalId: firstChemical.id, selectedRateId: UUID(), basis: .perHectare))
                }
            } label: {
                Label("Add Chemical", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(VineyardTheme.olive)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(VineyardTheme.olive.opacity(0.1))
                    .clipShape(.rect(cornerRadius: 10))
            }
            .disabled(store.chemicals.isEmpty)

            Button {
                showAddChemicalToList = true
            } label: {
                Label("Add New Chemical to List", systemImage: "flask.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(VineyardTheme.leafGreen)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(VineyardTheme.leafGreen.opacity(0.1))
                    .clipShape(.rect(cornerRadius: 10))
            }
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Notes", icon: "note.text")
            TextField("Add notes about this spray job...", text: $notes, axis: .vertical)
                .lineLimit(3...6)
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                showStartConfirmation = true
            } label: {
                Label("Create Spray Job & Start", systemImage: "play.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(VineyardTheme.olive)
            .disabled(!formIsValid || isSavingAndStarting)

            Button {
                saveForLater()
            } label: {
                Label("Create Job for Future Use", systemImage: "clock.badge.checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .tint(VineyardTheme.leafGreen)
            .disabled(!formIsValid)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: savedFeedback)
    }

    // MARK: - Calculation

    private func performCalculation(tractor: Tractor? = nil, duration: Double = 0) {
        guard let equipId = selectedEquipmentId,
              let equip = store.equipment.first(where: { $0.id == equipId }) else { return }

        let selectedPaddocks = store.paddocks.filter { selectedPaddockIds.contains($0.id) }

        calculationResult = SprayCalculator.calculate(
            selectedPaddocks: selectedPaddocks,
            waterRateLitresPerHectare: chosenSprayRate,
            tankCapacity: equip.tankCapacityLitres,
            chemicalLines: chemicalLines,
            chemicals: store.chemicals,
            concentrationFactor: concentrationFactor,
            operationType: operationType,
            tractor: tractor,
            jobDurationHours: duration,
            fuelCostPerLitre: store.seasonFuelCostPerLitre
        )
        withAnimation(.spring(duration: 0.4)) {
            showResults = true
        }
    }

    private func saveAndStartJob(tractor: Tractor?, numberOfFansJets: String = "", tractorGear: String = "", trackingPattern: TrackingPattern = .sequential, startDirection: StartDirection = .firstRow, operatorName: String = "") async {
        guard let equipId = selectedEquipmentId else { return }
        isSavingAndStarting = true

        let fallbackLocation = vineyardCentroidLocation
        await weatherDataService.fetchForStationOrNearest(
            stationId: store.settings.weatherStationId,
            location: locationService.location ?? fallbackLocation
        )
        let freshWeather: WeatherSnapshot?
        if let obs = weatherDataService.lastObservation {
            freshWeather = WeatherSnapshot(
                temperature: obs.temperature,
                windSpeed: obs.windSpeed,
                windDirection: obs.windDirection,
                humidity: obs.humidity
            )
        } else {
            freshWeather = nil
        }

        if freshWeather == nil {
            pendingStartParams = (tractor, numberOfFansJets, tractorGear, trackingPattern, startDirection, operatorName)
            isSavingAndStarting = false
            showWeatherMissingAlert = true
            return
        }

        performCalculation(tractor: tractor, duration: 0)

        let selectedPaddocks = store.paddocks.filter { selectedPaddockIds.contains($0.id) }
        var allRowNumbers: [Int] = []
        for paddock in selectedPaddocks {
            allRowNumbers.append(contentsOf: paddock.rows.map { $0.number })
        }
        allRowNumbers.sort()
        let globalFirst = allRowNumbers.first ?? 1
        let globalLast = allRowNumbers.last ?? 1
        let totalRows = globalLast - globalFirst + 1
        let sequence = trackingPattern.generateSequence(
            startRow: globalFirst,
            totalRows: totalRows,
            reversed: startDirection == .lastRow
        )
        let firstRow = sequence.first ?? 0.5
        let secondRow = sequence.count > 1 ? sequence[1] : firstRow
        let paddockNames = selectedPaddocks.map { $0.name }.joined(separator: ", ")

        let equip = store.equipment.first(where: { $0.id == equipId })
        let tankCount = calculationResult.map { $0.fullTankCount + ($0.lastTankLitres > 0 ? 1 : 0) } ?? 1

        let tripId = UUID()
        let trip = Trip(
            id: tripId,
            vineyardId: store.selectedVineyardId ?? UUID(),
            paddockId: selectedPaddocks.first?.id,
            paddockName: paddockNames,
            paddockIds: selectedPaddocks.map { $0.id },
            currentRowNumber: firstRow,
            nextRowNumber: secondRow,
            trackingPattern: trackingPattern,
            rowSequence: sequence,
            sequenceIndex: 0,
            personName: operatorName,
            totalTanks: tankCount
        )
        store.startTrip(trip)
        locationService.startUpdating()
        trackingService.startTracking()

        let phenologyEntries = selectedPaddockIds.map { pid in
            PaddockPhenologyEntry(paddockId: pid, phenologyStageId: paddockPhenologyStages[pid])
        }
        let application = SprayApplication(
            paddockIds: Array(selectedPaddockIds),
            equipmentId: equipId,
            chemicalLines: chemicalLines,
            waterRateLitresPerHectare: chosenSprayRate,
            operationType: operationType,
            sprayName: sprayName,
            notes: notes,
            weather: freshWeather,
            paddockPhenologyEntries: phenologyEntries,
            jobStartDate: Date(),
            jobEndDate: nil,
            jobDurationHours: nil,
            startWeather: freshWeather,
            numberOfFansJets: numberOfFansJets,
            tractorGear: tractorGear,
            trackingPattern: trackingPattern,
            startDirection: startDirection.rawValue,
            concentrationFactor: concentrationFactor
        )
        store.addSprayApplication(application, tripId: tripId, tractorName: tractor?.displayName ?? "")

        savedFeedback.toggle()
        isSavingAndStarting = false
        showStartConfirmation = false
        summaryJobStarted = true
        showCalculationSummary = true
    }

    private var vineyardCentroidLocation: CLLocation? {
        let selected = store.paddocks.filter { selectedPaddockIds.contains($0.id) }
        let allPoints = selected.flatMap { $0.polygonPoints }
        guard !allPoints.isEmpty else {
            let allPaddockPoints = store.paddocks.flatMap { $0.polygonPoints }
            guard !allPaddockPoints.isEmpty else { return nil }
            let lat = allPaddockPoints.map(\.latitude).reduce(0, +) / Double(allPaddockPoints.count)
            let lon = allPaddockPoints.map(\.longitude).reduce(0, +) / Double(allPaddockPoints.count)
            return CLLocation(latitude: lat, longitude: lon)
        }
        let lat = allPoints.map(\.latitude).reduce(0, +) / Double(allPoints.count)
        let lon = allPoints.map(\.longitude).reduce(0, +) / Double(allPoints.count)
        return CLLocation(latitude: lat, longitude: lon)
    }

    private func proceedWithoutWeather(tractor: Tractor?, numberOfFansJets: String, tractorGear: String, trackingPattern: TrackingPattern, startDirection: StartDirection, operatorName: String) async {
        isSavingAndStarting = true
        pendingStartParams = nil

        performCalculation(tractor: tractor, duration: 0)

        let selectedPaddocks = store.paddocks.filter { selectedPaddockIds.contains($0.id) }
        var allRowNumbers: [Int] = []
        for paddock in selectedPaddocks {
            allRowNumbers.append(contentsOf: paddock.rows.map { $0.number })
        }
        allRowNumbers.sort()
        let globalFirst = allRowNumbers.first ?? 1
        let globalLast = allRowNumbers.last ?? 1
        let totalRows = globalLast - globalFirst + 1
        let sequence = trackingPattern.generateSequence(
            startRow: globalFirst,
            totalRows: totalRows,
            reversed: startDirection == .lastRow
        )
        let firstRow = sequence.first ?? 0.5
        let secondRow = sequence.count > 1 ? sequence[1] : firstRow
        let paddockNames = selectedPaddocks.map { $0.name }.joined(separator: ", ")

        let equip = store.equipment.first(where: { $0.id == selectedEquipmentId })
        let tankCount = calculationResult.map { $0.fullTankCount + ($0.lastTankLitres > 0 ? 1 : 0) } ?? 1

        let tripId = UUID()
        let trip = Trip(
            id: tripId,
            vineyardId: store.selectedVineyardId ?? UUID(),
            paddockId: selectedPaddocks.first?.id,
            paddockName: paddockNames,
            paddockIds: selectedPaddocks.map { $0.id },
            currentRowNumber: firstRow,
            nextRowNumber: secondRow,
            trackingPattern: trackingPattern,
            rowSequence: sequence,
            sequenceIndex: 0,
            personName: operatorName,
            totalTanks: tankCount
        )
        store.startTrip(trip)
        locationService.startUpdating()
        trackingService.startTracking()

        let phenologyEntries = selectedPaddockIds.map { pid in
            PaddockPhenologyEntry(paddockId: pid, phenologyStageId: paddockPhenologyStages[pid])
        }
        let application = SprayApplication(
            paddockIds: Array(selectedPaddockIds),
            equipmentId: selectedEquipmentId ?? UUID(),
            chemicalLines: chemicalLines,
            waterRateLitresPerHectare: chosenSprayRate,
            operationType: operationType,
            sprayName: sprayName,
            notes: notes,
            weather: nil,
            paddockPhenologyEntries: phenologyEntries,
            jobStartDate: Date(),
            jobEndDate: nil,
            jobDurationHours: nil,
            startWeather: nil,
            numberOfFansJets: numberOfFansJets,
            tractorGear: tractorGear,
            trackingPattern: trackingPattern,
            startDirection: startDirection.rawValue,
            concentrationFactor: concentrationFactor
        )
        store.addSprayApplication(application, tripId: tripId, tractorName: tractor?.displayName ?? "")

        savedFeedback.toggle()
        isSavingAndStarting = false
        showStartConfirmation = false
        summaryJobStarted = true
        showCalculationSummary = true
    }

    private func saveForLater() {
        guard let equipId = selectedEquipmentId else { return }

        performCalculation()

        let selectedPaddocks = store.paddocks.filter { selectedPaddockIds.contains($0.id) }
        let paddockNames = selectedPaddocks.map { $0.name }.joined(separator: ", ")

        let placeholderTripId = UUID()
        let placeholderTrip = Trip(
            id: placeholderTripId,
            vineyardId: store.selectedVineyardId ?? UUID(),
            paddockId: selectedPaddocks.first?.id,
            paddockName: paddockNames,
            paddockIds: selectedPaddocks.map { $0.id },
            endTime: nil,
            isActive: false
        )
        store.startTrip(placeholderTrip)

        let phenologyEntries = selectedPaddockIds.map { pid in
            PaddockPhenologyEntry(paddockId: pid, phenologyStageId: paddockPhenologyStages[pid])
        }
        let application = SprayApplication(
            paddockIds: Array(selectedPaddockIds),
            equipmentId: equipId,
            chemicalLines: chemicalLines,
            waterRateLitresPerHectare: chosenSprayRate,
            operationType: operationType,
            sprayName: sprayName,
            notes: notes,
            weather: nil,
            paddockPhenologyEntries: phenologyEntries,
            jobStartDate: nil,
            jobEndDate: nil,
            jobDurationHours: nil,
            startWeather: nil,
            concentrationFactor: concentrationFactor
        )
        store.addSprayApplication(application, tripId: placeholderTripId)
        savedFeedback.toggle()
        summaryJobStarted = false
        showCalculationSummary = true
    }
}

// MARK: - Start Job Confirmation Sheet

struct CalcStartJobSheet: View {
    let store: DataStore
    let selectedPaddockIds: Set<UUID>
    @Binding var isSaving: Bool
    let onConfirm: (Tractor?, String, String, TrackingPattern, StartDirection, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthService.self) private var authService
    @State private var selectedTractorId: UUID?
    @State private var tractorGear: String = ""
    @State private var numberOfFansJets: String = ""
    @State private var selectedPattern: TrackingPattern = .sequential
    @State private var startDirection: StartDirection = .firstRow
    @State private var operatorName: String = ""

    private var selectedPaddocks: [Paddock] {
        store.paddocks.filter { selectedPaddockIds.contains($0.id) }
    }

    private var rowSequence: [Double] {
        var allRowNumbers: [Int] = []
        for paddock in selectedPaddocks {
            allRowNumbers.append(contentsOf: paddock.rows.map { $0.number })
        }
        allRowNumbers.sort()
        guard let globalFirst = allRowNumbers.first, let globalLast = allRowNumbers.last else { return [] }
        let totalRows = globalLast - globalFirst + 1
        return selectedPattern.generateSequence(
            startRow: globalFirst,
            totalRows: totalRows,
            reversed: startDirection == .lastRow
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(VineyardTheme.olive)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start Spray Job")
                                .font(.title3.bold())
                            Text("Confirm details before starting")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    calcOperatorField

                    Divider()

                    calcTractorSection

                    if selectedTractorId != nil {
                        calcTractorGearField
                    }

                    calcFansJetsField

                    if selectedTractorId != nil && store.seasonFuelCostPerLitre > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "fuelpump.circle.fill")
                                .font(.caption)
                                .foregroundStyle(VineyardTheme.olive)
                            Text("Season fuel price: $\(String(format: "%.2f", store.seasonFuelCostPerLitre))/L")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    calcPatternSection
                    calcStartDirectionSection

                    if !selectedPaddockIds.isEmpty && !rowSequence.isEmpty {
                        calcSequencePreviewSection
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "cloud.sun.fill")
                            .font(.subheadline)
                            .foregroundStyle(VineyardTheme.olive)
                        Text("Weather data will be captured automatically at start")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VineyardTheme.olive.opacity(0.06))
                    .clipShape(.rect(cornerRadius: 8))
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        let tractor = selectedTractorId.flatMap { tId in store.tractors.first(where: { $0.id == tId }) }
                        onConfirm(tractor, numberOfFansJets, tractorGear, selectedPattern, startDirection, operatorName.trimmingCharacters(in: .whitespacesAndNewlines))
                    } label: {
                        if isSaving {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .tint(.white)
                                Text("Fetching weather & starting...")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        } else {
                            Label("Start Job Now", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(VineyardTheme.olive)
                    .disabled(isSaving)

                    Button("Cancel") {
                        dismiss()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.bar)
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                operatorName = authService.userName
            }
        }
    }

    private var calcOperatorField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Operator", systemImage: "person.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            TextField("Operator name", text: $operatorName)
                .font(.body.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
        }
    }

    private var calcTractorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Select Tractor", systemImage: "truck.pickup.side.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                ForEach(store.tractors) { tractor in
                    let isSelected = selectedTractorId == tractor.id
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTractorId = tractor.id
                        }
                    } label: {
                        HStack {
                            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(isSelected ? AnyShapeStyle(VineyardTheme.olive) : AnyShapeStyle(.tertiary))
                            Text(tractor.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(String(format: "%.1f", tractor.fuelUsageLPerHour)) L/hr")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }

                    if tractor.id != store.tractors.last?.id {
                        Divider().padding(.leading, 40)
                    }
                }

                if store.tractors.isEmpty {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.tertiary)
                        Text("No tractors configured — add one in Settings → Equipment")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 10))
        }
    }

    private var calcTractorGearField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tractor Gear")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. 2nd Low", text: $tractorGear)
                .font(.body.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var calcFansJetsField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No. Fans/Jets")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. 8", text: $numberOfFansJets)
                .keyboardType(.numberPad)
                .font(.body.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
        }
    }

    private var calcPatternSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Track Pattern")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                ForEach([TrackingPattern.sequential, .everySecondRow, .fiveThree, .twoRowUpBack], id: \.id) { pattern in
                    let isSelected = selectedPattern == pattern
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedPattern = pattern
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: pattern.icon)
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(pattern.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(pattern.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }

                    if pattern.id != TrackingPattern.twoRowUpBack.id {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 10))
        }
    }

    private var calcStartDirectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start From")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                ForEach([StartDirection.firstRow, .lastRow], id: \.rawValue) { direction in
                    let isSelected = startDirection == direction
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            startDirection = direction
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: direction.icon)
                                .font(.title3)
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                .frame(width: 28)

                            Text(direction.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)

                            Spacer()

                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }

                    if direction == .firstRow {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 10))

            Text(startDirection == .firstRow
                 ? "Paths will go from lowest row to highest."
                 : "Paths will go from highest row to lowest.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var calcSequencePreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Path Sequence Preview")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(rowSequence.prefix(30).enumerated()), id: \.offset) { index, row in
                        SequenceChip(index: index, row: row)
                    }
                    if rowSequence.count > 30 {
                        Text("+\(rowSequence.count - 30)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 10))

            let seq = rowSequence
            let uniquePaths = Set(seq)
            Text("\(seq.count) paths across \(selectedPaddockIds.count) block\(selectedPaddockIds.count == 1 ? "" : "s"). \(uniquePaths.count) unique paths.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Chemical Line Card

struct CalcChemicalLineCard: View {
    @Binding var line: ChemicalLine
    let chemicals: [SavedChemical]
    var onEdit: ((SavedChemical) -> Void)?
    @Binding var scrollTarget: String?
    let onDelete: () -> Void

    private var selectedChemical: SavedChemical? {
        chemicals.first(where: { $0.id == line.chemicalId })
    }

    private var cardId: String {
        "chem-\(line.id.uuidString)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "flask.fill")
                    .foregroundStyle(VineyardTheme.leafGreen)
                    .font(.subheadline)
                Text(selectedChemical?.name ?? "Select Chemical")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let chem = selectedChemical,
                   let rate = chem.rates.first(where: { $0.id == line.selectedRateId }) {
                    Text(rate.basis == .perHectare ? "Per Ha" : "Per 100L")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(rate.basis == .perHectare ? VineyardTheme.olive.opacity(0.15) : Color.blue.opacity(0.15))
                        .foregroundStyle(rate.basis == .perHectare ? VineyardTheme.olive : .blue)
                        .clipShape(Capsule())
                }
                if let chem = selectedChemical {
                    Button {
                        onEdit?(chem)
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title3)
                            .foregroundStyle(VineyardTheme.olive)
                    }
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().padding(.leading, 14)

            VStack(alignment: .leading, spacing: 2) {
                Text("Chemical")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Chemical", selection: $line.chemicalId) {
                    ForEach(chemicals) { chem in
                        Text(chem.name).tag(chem.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: line.chemicalId) { _, newValue in
                    if let chem = chemicals.first(where: { $0.id == newValue }),
                       let firstRate = chem.rates.first {
                        line.selectedRateId = firstRate.id
                        line.basis = firstRate.basis
                    }
                    scrollTarget = cardId
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if let chem = selectedChemical {
                let haRates = chem.rates.filter { $0.basis == .perHectare }
                let per100LRates = chem.rates.filter { $0.basis == .per100Litres }

                Divider().padding(.leading, 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Rate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Rate", selection: $line.selectedRateId) {
                        if !haRates.isEmpty {
                            Section("Per Hectare") {
                                ForEach(haRates) { rate in
                                    Text("\(rate.label): \(String(format: "%.0f", chem.unit.fromBase(rate.value))) \(chem.unit.rawValue)/ha").tag(rate.id)
                                }
                            }
                        }
                        if !per100LRates.isEmpty {
                            Section("Per 100L Water") {
                                ForEach(per100LRates) { rate in
                                    Text("\(rate.label): \(String(format: "%.0f", chem.unit.fromBase(rate.value))) \(chem.unit.rawValue)/100L").tag(rate.id)
                                }
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .onChange(of: line.selectedRateId) { _, newRateId in
                        if let rate = chem.rates.first(where: { $0.id == newRateId }) {
                            line.basis = rate.basis
                        }
                        scrollTarget = cardId
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .id(cardId)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }
}

// MARK: - Results Card

struct ResultsCard: View {
    let result: SprayCalculationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Results")
                .font(.title2.bold())

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatCard(title: "Total Area", value: "\(String(format: "%.2f", result.totalAreaHectares)) ha", icon: "square.dashed", color: VineyardTheme.olive)
                StatCard(title: "Total Water", value: "\(String(format: "%.0f", result.totalWaterLitres)) L", icon: "drop.fill", color: .blue)
                StatCard(title: "Full Tanks", value: "\(result.fullTankCount)", icon: "fuelpump.fill", color: VineyardTheme.earthBrown)
                StatCard(title: "Last Tank", value: "\(String(format: "%.0f", result.lastTankLitres)) L", icon: "drop.halffull", color: .orange)
            }

            if result.concentrationFactor != 1.0 {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Concentration Factor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.2f", result.concentrationFactor))×")
                            .font(.headline)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(result.concentrationFactor > 1.0 ? "Concentrate" : "Dilute")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.15))
                        .clipShape(.rect(cornerRadius: 6))
                        .foregroundStyle(.orange)
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 10))
            }

            ForEach(result.chemicalResults) { chemResult in
                CalcChemicalResultCard(result: chemResult)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }
}

// MARK: - Chemical Result Card

struct CalcChemicalResultCard: View {
    let result: ChemicalCalculationResult
    @State private var showBreakdown: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "flask.fill")
                    .foregroundStyle(VineyardTheme.leafGreen)
                Text(result.chemicalName)
                    .font(.headline)
                Spacer()
                Text("\(result.unit.fromBase(result.totalAmountRequired), specifier: "%.1f") \(result.unit.rawValue)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VineyardTheme.olive)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Per full tank")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(result.unit.fromBase(result.amountPerFullTank), specifier: "%.1f") \(result.unit.rawValue)")
                        .font(.subheadline.weight(.medium))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last tank")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(result.unit.fromBase(result.amountInLastTank), specifier: "%.1f") \(result.unit.rawValue)")
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
                Text("\(String(format: "%.0f", result.unit.fromBase(result.selectedRate))) \(result.unit.rawValue)/\(result.basis == .perHectare ? "ha" : "100L")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                withAnimation(.spring(duration: 0.3)) {
                    showBreakdown.toggle()
                }
            } label: {
                HStack {
                    Text("Paddock Breakdown")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showBreakdown ? 90 : 0))
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            if showBreakdown {
                ForEach(result.paddockBreakdown) { breakdown in
                    HStack {
                        Text(breakdown.paddockName)
                            .font(.caption)
                        Spacer()
                        Text("\(breakdown.areaHectares, specifier: "%.2f") ha")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(result.unit.fromBase(breakdown.amountRequired), specifier: "%.1f") \(result.unit.rawValue)")
                            .font(.caption.weight(.medium))
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 10))
    }
}

// MARK: - Costings Card

struct CostingsCard: View {
    let summary: SprayCostingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.title3)
                    .foregroundStyle(VineyardTheme.vineRed)
                Text("Costings")
                    .font(.title2.bold())
            }

            ForEach(summary.chemicalCosts) { cost in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "flask.fill")
                            .foregroundStyle(VineyardTheme.leafGreen)
                            .font(.subheadline)
                        Text(cost.chemicalName)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("$\(String(format: "%.2f", cost.totalCost))")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(VineyardTheme.vineRed)
                    }

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Per \(cost.unit == .grams || cost.unit == .kilograms ? "g" : "mL")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("$\(String(format: "%.4f", cost.costPerBaseUnit))")
                                .font(.caption.weight(.medium))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Total used")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(String(format: "%.0f", cost.totalAmountBase)) \(cost.unit == .grams || cost.unit == .kilograms ? "g" : "mL")")
                                .font(.caption.weight(.medium))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Per hectare")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("$\(String(format: "%.2f", cost.costPerHectare))/ha")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(VineyardTheme.earthBrown)
                        }
                    }
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 8))
            }

            if let fuel = summary.fuelCost {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "fuelpump.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                        Text("Fuel — \(fuel.tractorName)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("$\(String(format: "%.2f", fuel.totalFuelCost))")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(VineyardTheme.vineRed)
                    }

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Usage")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(String(format: "%.1f", fuel.fuelUsageLPerHour)) L/hr")
                                .font(.caption.weight(.medium))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Duration")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(String(format: "%.1f", fuel.jobDurationHours)) hrs")
                                .font(.caption.weight(.medium))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Total fuel")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(String(format: "%.1f", fuel.totalFuelLitres)) L")
                                .font(.caption.weight(.medium))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Per hectare")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("$\(String(format: "%.2f", fuel.fuelCostPerHectare))/ha")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(VineyardTheme.earthBrown)
                        }
                    }
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: 8))
            }

            Divider()

            if !summary.chemicalCosts.isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Chemical Cost")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("$\(String(format: "%.2f", summary.totalChemicalCost))")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(VineyardTheme.vineRed)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Per Hectare")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("$\(String(format: "%.2f", summary.totalCostPerHectare))/ha")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(VineyardTheme.earthBrown)
                    }
                }
            }

            if summary.fuelCost != nil {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Fuel Cost")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("$\(String(format: "%.2f", summary.fuelCost?.totalFuelCost ?? 0))")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Per Hectare")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("$\(String(format: "%.2f", summary.fuelCost?.fuelCostPerHectare ?? 0))/ha")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(VineyardTheme.earthBrown)
                    }
                }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Grand Total")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("$\(String(format: "%.2f", summary.grandTotal))")
                        .font(.title.bold())
                        .foregroundStyle(VineyardTheme.vineRed)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Total per Hectare")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("$\(String(format: "%.2f", summary.grandTotalPerHectare))/ha")
                        .font(.title3.bold())
                        .foregroundStyle(VineyardTheme.earthBrown)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text("Based on \(String(format: "%.2f", summary.totalAreaHectares)) ha")
                    .font(.caption)
            }
            .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }
}

// MARK: - Phenology Picker

struct CalcPhenologyPickerSheet: View {
    let paddockId: UUID?
    let paddockName: String
    let stages: [PhenologyStage]
    let currentStageId: UUID?
    let onSelect: (UUID?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onSelect(nil)
                    } label: {
                        HStack {
                            Text("Not Set")
                                .foregroundStyle(.primary)
                            Spacer()
                            if currentStageId == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(VineyardTheme.olive)
                            }
                        }
                    }

                    ForEach(stages) { stage in
                        Button {
                            onSelect(stage.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stage.name)
                                        .foregroundStyle(.primary)
                                    Text("E-L \(stage.code)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if currentStageId == stage.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(VineyardTheme.olive)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Select the current growth stage")
                }
            }
            .navigationTitle(paddockName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onSelect(currentStageId)
                    }
                }
            }
        }
    }
}

// MARK: - Add Equipment Sheet

struct AddSprayEquipmentSheet: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var tankCapacityText: String = ""

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (Double(tankCapacityText) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Equipment Details") {
                    TextField("Name (e.g. Croplands Quantum)", text: $name)
                    HStack {
                        Text("Tank Capacity (L)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("e.g. 2000", text: $tankCapacityText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }
                }
            }
            .navigationTitle("Add Equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let item = SprayEquipmentItem(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            tankCapacityLitres: Double(tankCapacityText) ?? 0
                        )
                        store.addSprayEquipment(item)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}

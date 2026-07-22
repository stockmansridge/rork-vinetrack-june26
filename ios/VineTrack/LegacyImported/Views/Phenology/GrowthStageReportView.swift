import SwiftUI
import UIKit

struct GrowthStageReportView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @State private var selectedVintages: Set<Int> = []
    @State private var selectedPaddockId: UUID?
    @State private var sharePDFURL: SharePDFURL?
    @State private var isGeneratingPDF: Bool = false
    @State private var exportError: String?

    private struct SharePDFURL: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var fmt: RegionFormatter { store.settings.regionFormatter }
    private var seasonStartMonth: Int { store.settings.seasonStartMonth }
    private var seasonStartDay: Int { store.settings.seasonStartDay }
    private var tz: TimeZone { store.settings.resolvedTimeZone }
    private var seasonCalendar: Calendar { store.settings.resolvedCalendar }

    private var growthPins: [VinePin] {
        store.pins.filter { $0.growthStageCode != nil && $0.mode == .growth }
    }

    private var filteredPins: [VinePin] {
        var pins = growthPins
        if let paddockId = selectedPaddockId {
            pins = pins.filter { $0.paddockId == paddockId }
        }
        return pins
    }

    private var availableVintages: [Int] {
        let vintages = Set(filteredPins.map { vintageYear(for: $0.timestamp) })
        return vintages.sorted(by: >)
    }

    private var activeVintages: [Int] {
        if selectedVintages.isEmpty {
            return availableVintages
        }
        return availableVintages.filter { selectedVintages.contains($0) }
    }

    private var allStageCodes: [String] {
        let enabledCodes = store.settings.enabledGrowthStageCodes
        let usedCodes = Set(filteredPins.compactMap { $0.growthStageCode })
        let allCodes = Set(enabledCodes).union(usedCodes)
        return GrowthStage.allStages
            .map { $0.code }
            .filter { allCodes.contains($0) }
    }

    private func vintageYear(for date: Date) -> Int {
        let cal = seasonCalendar
        let month = cal.component(.month, from: date)
        let day = cal.component(.day, from: date)
        let year = cal.component(.year, from: date)

        if month > seasonStartMonth || (month == seasonStartMonth && day >= seasonStartDay) {
            return year + 1
        }
        return year
    }

    private func vintageRange(for vintage: Int) -> (start: Date, end: Date) {
        let cal = seasonCalendar
        let startComponents = DateComponents(year: vintage - 1, month: seasonStartMonth, day: seasonStartDay)
        let endComponents = DateComponents(year: vintage, month: seasonStartMonth, day: seasonStartDay)
        let start = cal.date(from: startComponents) ?? Date()
        let end = cal.date(byAdding: .day, value: -1, to: cal.date(from: endComponents) ?? Date()) ?? Date()
        return (start, end)
    }

    private func endOfDay(_ date: Date) -> Date {
        let cal = seasonCalendar
        if let result = cal.date(bySettingHour: 23, minute: 59, second: 59, of: date) {
            return result
        }
        return date
    }

    private func stageEntries(for vintage: Int) -> [String: [VinePin]] {
        let range = vintageRange(for: vintage)
        let rangeEnd = endOfDay(range.end)
        let pins = filteredPins.filter { $0.timestamp >= range.start && $0.timestamp <= rangeEnd }
        var result: [String: [VinePin]] = [:]
        for pin in pins {
            guard let code = pin.growthStageCode else { continue }
            result[code, default: []].append(pin)
        }
        for key in result.keys {
            result[key]?.sort { $0.timestamp < $1.timestamp }
        }
        return result
    }

    private let vintageColors: [Color] = [
        .blue, .green, .orange, .purple, .red, .teal, .pink, .indigo, .mint, .cyan
    ]

    private func colorForVintage(_ vintage: Int) -> Color {
        let sorted = activeVintages.sorted(by: >)
        guard let idx = sorted.firstIndex(of: vintage) else { return .primary }
        return vintageColors[idx % vintageColors.count]
    }

    var body: some View {
        Group {
            if growthPins.isEmpty {
                ContentUnavailableView {
                    Label { Text("No Growth Data") } icon: { GrapeLeafIcon(size: 44) }
                } description: {
                    Text("Drop growth stage pins from the Home tab to build your vintage report.")
                }
            } else if availableVintages.isEmpty {
                ContentUnavailableView {
                    Label { Text("No Matching Data") } icon: { GrapeLeafIcon(size: 44) }
                } description: {
                    Text("No growth stage entries found for the selected block.")
                }
            } else {
                List {
                    paddockFilterSection
                    vintageFilterSection
                    reportSection
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Export PDF")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if accessControl.canExport {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportPDF()
                    } label: {
                        if isGeneratingPDF {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(isGeneratingPDF || growthPins.isEmpty || availableVintages.isEmpty)
                }
            }
        }
        .sheet(item: $sharePDFURL) { url in
            ShareSheet(items: [url.url])
        }
        .alert("Export Failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func exportPDF() {
        guard !isGeneratingPDF else { return }
        isGeneratingPDF = true

        let vineyardName = store.selectedVineyard?.name ?? "Vineyard"
        let seasonMonth = seasonStartMonth
        let seasonDay = seasonStartDay
        let exportTimeZone = tz
        let exportDateFormat = store.settings.regionSettings.dateStyle.dateFormatTemplate
        let exportLocaleIdentifier = "en_\(store.settings.regionSettings.countryCode.uppercased())"

        let blocks: [GrowthStageReportPDFService.BlockReport] = {
            let paddocks: [Paddock] = {
                if let pid = selectedPaddockId, let p = store.paddocks.first(where: { $0.id == pid }) {
                    return [p]
                }
                return store.paddocks
            }()

            return paddocks.compactMap { paddock in
                let pinsForPaddock = filteredPins.filter { $0.paddockId == paddock.id }
                guard !pinsForPaddock.isEmpty else { return nil }

                let vintages = Set(pinsForPaddock.map { vintageYear(for: $0.timestamp) }).sorted(by: >)
                let usedCodes = Set(pinsForPaddock.compactMap { $0.growthStageCode })
                let stageCodes = GrowthStage.allStages.map { $0.code }.filter { usedCodes.contains($0) }

                var entries: [Int: [String: Date]] = [:]
                for vintage in vintages {
                    let range = vintageRange(for: vintage)
                    let rangeEnd = endOfDay(range.end)
                    let pins = pinsForPaddock.filter { $0.timestamp >= range.start && $0.timestamp <= rangeEnd }
                    var codeMap: [String: Date] = [:]
                    for pin in pins {
                        guard let code = pin.growthStageCode else { continue }
                        if let existing = codeMap[code] {
                            if pin.timestamp < existing { codeMap[code] = pin.timestamp }
                        } else {
                            codeMap[code] = pin.timestamp
                        }
                    }
                    entries[vintage] = codeMap
                }

                return GrowthStageReportPDFService.BlockReport(
                    blockName: paddock.name,
                    vintages: vintages,
                    stageCodes: stageCodes,
                    entries: entries
                )
            }
        }()

        guard !blocks.isEmpty else {
            isGeneratingPDF = false
            exportError = "No growth stage data available to export."
            return
        }

        let vintageColorMap: [Int: UIColor] = {
            var map: [Int: UIColor] = [:]
            let allVintagesSorted = Array(Set(blocks.flatMap { $0.vintages })).sorted(by: >)
            for (idx, vintage) in allVintagesSorted.enumerated() {
                map[vintage] = uiColor(for: idx)
            }
            return map
        }()

        Task.detached {
            let data = GrowthStageReportPDFService.generatePDF(
                blocks: blocks,
                vineyardName: vineyardName,
                seasonStartMonth: seasonMonth,
                seasonStartDay: seasonDay,
                vintageColors: vintageColorMap,
                logoData: nil,
                timeZone: exportTimeZone,
                dateFormat: exportDateFormat,
                localeIdentifier: exportLocaleIdentifier
            )
            let fileName = "GrowthStageReport_\(Date().formatted(.iso8601.year().month().day()))"
            let url = GrowthStageReportPDFService.savePDFToTemp(data: data, fileName: fileName)
            await MainActor.run {
                isGeneratingPDF = false
                sharePDFURL = SharePDFURL(url: url)
            }
        }
    }

    private func uiColor(for index: Int) -> UIColor {
        let palette: [UIColor] = [
            .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemRed,
            .systemTeal, .systemPink, .systemIndigo, .systemMint, .systemCyan
        ]
        return palette[index % palette.count]
    }

    private var paddockFilterSection: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    FilterChip(title: "All Blocks", isSelected: selectedPaddockId == nil) {
                        selectedPaddockId = nil
                    }
                    ForEach(store.paddocks) { paddock in
                        FilterChip(title: paddock.name, isSelected: selectedPaddockId == paddock.id) {
                            selectedPaddockId = selectedPaddockId == paddock.id ? nil : paddock.id
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("Block")
        }
    }

    private var vintageFilterSection: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    FilterChip(title: "All Vintages", isSelected: selectedVintages.isEmpty) {
                        selectedVintages = []
                    }
                    ForEach(availableVintages, id: \.self) { vintage in
                        Button {
                            if selectedVintages.contains(vintage) {
                                selectedVintages.remove(vintage)
                            } else {
                                selectedVintages.insert(vintage)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(colorForVintage(vintage))
                                    .frame(width: 10, height: 10)
                                Text("Vintage \(String(vintage))")
                                    .font(.subheadline.weight(.medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedVintages.contains(vintage) ? colorForVintage(vintage).opacity(0.15) : Color(.tertiarySystemBackground))
                            .foregroundStyle(selectedVintages.contains(vintage) ? colorForVintage(vintage) : .primary)
                            .clipShape(.capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .foregroundStyle(.purple)
                    .font(.caption)
                Text("Vintages")
            }
        } footer: {
            if let first = availableVintages.first {
                let range = vintageRange(for: first)
                Text("Vintage \(String(first)): \(fmt.formatDate(range.start)) \u{2013} \(fmt.formatDate(range.end))")
            }
        }
    }

    private var reportSection: some View {
        Section {
            ForEach(allStageCodes, id: \.self) { code in
                stageRow(for: code)
            }
        } header: {
            HStack(spacing: 6) {
                GrapeLeafIcon(size: 14, color: VineyardTheme.leafGreen)
                Text("E-L Growth Stages")
            }
        }
    }

    private func stageRow(for code: String) -> some View {
        let stage = GrowthStage.allStages.first { $0.code == code }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(code)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(VineyardTheme.leafGreen.gradient, in: .rect(cornerRadius: 6))

                if let stage {
                    Text(stage.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            ForEach(activeVintages, id: \.self) { vintage in
                vintageRow(for: code, vintage: vintage)
            }
        }
        .padding(.vertical, 4)
    }

    private func vintageRow(for code: String, vintage: Int) -> some View {
        let entries = stageEntries(for: vintage)
        let pins = entries[code] ?? []
        let color = colorForVintage(vintage)

        return Group {
            if !pins.isEmpty {
                ForEach(pins) { pin in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color)
                            .frame(width: 3, height: 20)

                        Text(String(vintage))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(color)
                            .frame(width: 38, alignment: .leading)

                        Text(fmt.formatDate(pin.timestamp))
                            .font(.caption.monospacedDigit())

                        Spacer()

                        if let paddockId = pin.paddockId,
                           let paddock = store.paddocks.first(where: { $0.id == paddockId }) {
                            Text(paddock.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.tertiarySystemFill), in: .capsule)
                        }
                    }
                }
            } else if selectedVintages.isEmpty || selectedVintages.contains(vintage) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.3))
                        .frame(width: 3, height: 20)

                    Text(String(vintage))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(color.opacity(0.4))
                        .frame(width: 38, alignment: .leading)

                    Text("\u{2014}")
                        .font(.caption)
                        .foregroundStyle(.quaternary)

                    Spacer()
                }
            }
        }
    }
}

import SwiftUI

nonisolated enum PlannedTankProgress: String, Sendable {
    case current = "Current"
    case next = "Next"
    case completed = "Completed"
}

/// Read-only presentation of the tank plan frozen into a linked Spray Record.
nonisolated struct TankMixPresentation: Sendable {
    let tanks: [SprayTank]
    let selectedTankNumber: Int?
    let activeTankNumber: Int?
    let nextTankNumber: Int?
    let completedTankNumbers: Set<Int>

    init(record: SprayRecord?, trip: Trip) {
        let sortedTanks = (record?.tanks ?? []).sorted {
            if $0.tankNumber == $1.tankNumber {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.tankNumber < $1.tankNumber
        }
        let plannedNumbers = Set(sortedTanks.map(\.tankNumber))
        let validSessions = trip.tankSessions.filter {
            $0.tankNumber > 0 && plannedNumbers.contains($0.tankNumber)
        }
        let completed = Set(validSessions.filter { $0.endTime != nil }.map(\.tankNumber))
        let active = validSessions
            .filter { $0.endTime == nil }
            .sorted {
                if $0.startTime == $1.startTime {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.startTime < $1.startTime
            }
            .last?.tankNumber
        let next = sortedTanks.first { !completed.contains($0.tankNumber) }?.tankNumber

        tanks = sortedTanks
        activeTankNumber = active
        nextTankNumber = next
        completedTankNumbers = completed
        selectedTankNumber = active ?? next ?? sortedTanks.last?.tankNumber
    }

    var isAvailable: Bool { !tanks.isEmpty }

    func progress(for tank: SprayTank) -> PlannedTankProgress? {
        if tank.tankNumber == activeTankNumber { return .current }
        if completedTankNumbers.contains(tank.tankNumber) { return .completed }
        if activeTankNumber == nil, tank.tankNumber == nextTankNumber { return .next }
        return nil
    }

    func isPartial(_ tank: SprayTank) -> Bool {
        guard tank.id == tanks.last?.id,
              let largestVolume = tanks.map(\.waterVolume).max(),
              largestVolume > 0 else { return false }
        return tank.waterVolume < largestVolume
    }
}

struct TankMixDetailsView: View {
    let record: SprayRecord?
    let trip: Trip

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTankNumber: Int?

    private let presentation: TankMixPresentation

    init(record: SprayRecord?, trip: Trip) {
        self.record = record
        self.trip = trip
        let presentation = TankMixPresentation(record: record, trip: trip)
        self.presentation = presentation
        _selectedTankNumber = State(initialValue: presentation.selectedTankNumber)
    }

    private var selectedTank: SprayTank? {
        presentation.tanks.first { $0.tankNumber == selectedTankNumber }
            ?? presentation.tanks.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let tank = selectedTank {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            tankSelector
                            tankHeading(tank)
                            plannedSummary(tank)
                            chemicalList(tank)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                    .presentationContentInteraction(.scrolls)
                } else {
                    ContentUnavailableView(
                        "Tank mix details unavailable on this device.",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Start Tank and End Tank remain available for this trip.")
                    )
                }
            }
            .navigationTitle("Tank Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var tankSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presentation.tanks) { tank in
                    Button {
                        selectedTankNumber = tank.tankNumber
                    } label: {
                        Text("Tank \(tank.tankNumber)")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(
                                selectedTankNumber == tank.tankNumber
                                    ? Color.accentColor
                                    : Color(.secondarySystemGroupedBackground)
                            )
                            .foregroundStyle(selectedTankNumber == tank.tankNumber ? .white : .primary)
                            .clipShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .contentMargins(.horizontal, 0)
    }

    private func tankHeading(_ tank: SprayTank) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tank \(tank.tankNumber) of \(presentation.tanks.count)")
                .font(.title2.weight(.bold))
            HStack(spacing: 8) {
                if let progress = presentation.progress(for: tank) {
                    statusBadge(progress.rawValue, color: color(for: progress))
                }
                if presentation.isPartial(tank) {
                    statusBadge("Partial tank", color: .orange)
                }
            }
            Text("Planned amounts")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(VineyardTheme.olive)
        }
    }

    private func plannedSummary(_ tank: SprayTank) -> some View {
        VStack(spacing: 0) {
            detailRow("Planned water", value: "\(Self.number(tank.waterVolume)) L")
            Divider()
            detailRow("Planned area", value: "\(Self.number(tank.areaPerTank)) ha")
            Divider()
            detailRow("Spray rate", value: "\(Self.number(tank.sprayRatePerHa)) L/ha")
            if abs(tank.effectiveConcentrationFactor - 1) > 0.000_001 {
                Divider()
                detailRow("Concentration", value: "\(Self.number(tank.effectiveConcentrationFactor))×")
            }
            if !tank.rowApplications.isEmpty {
                Divider()
                detailRow(
                    "Planned rows",
                    value: tank.rowApplications.map(\.rowRange).joined(separator: ", ")
                )
            }
        }
        .padding(.horizontal, 14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func chemicalList(_ tank: SprayTank) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Planned chemicals")
                .font(.headline)
            if tank.chemicals.isEmpty {
                Text("No planned chemicals stored for this tank.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tank.chemicals) { chemical in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(chemical.name.isEmpty ? "Unnamed chemical" : chemical.name)
                                .font(.body.weight(.semibold))
                            Spacer(minLength: 12)
                            Text("\(Self.number(chemical.displayVolume)) \(chemical.unitLabel)")
                                .font(.body.weight(.bold))
                                .monospacedDigit()
                        }
                        if chemical.reportedRateBaseValue > 0 {
                            Text("Application rate: \(chemical.reportedRateText(formatter: store.settings.regionFormatter))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 14))
                }
            }
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.semibold)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
        .padding(.vertical, 12)
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12))
            .clipShape(.capsule)
    }

    private func color(for progress: PlannedTankProgress) -> Color {
        switch progress {
        case .current: .cyan
        case .next: VineyardTheme.olive
        case .completed: .green
        }
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.grouping(.automatic).precision(.fractionLength(0...3)))
    }
}

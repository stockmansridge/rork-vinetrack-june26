import SwiftUI

struct GrowthStageBlockDetailView: View {
    @Environment(MigratedDataStore.self) private var store
    let blockName: String
    let currentEl: Double?
    let records: [GrowthStageRecord]
    let formatter: RegionFormatter

    @State private var isCapturing: Bool = false

    private let green = Color(red: 0.05, green: 0.34, blue: 0.21)
    private let milestones = [4, 12, 19, 27, 35]

    private var currentCode: String? {
        guard let currentEl, currentEl == currentEl.rounded() else { return nil }
        return "EL\(Int(currentEl))"
    }

    private var currentStage: GrowthStage? {
        GrowthStage.allStages.first { $0.code == currentCode }
    }

    private var currentRecord: GrowthStageRecord? {
        guard let currentCode else { return nil }
        return records.filter { "EL\($0.stageCode.filter(\.isNumber))" == currentCode }
            .max(by: { $0.observedAt < $1.observedAt })
    }

    private var firstDates: [String: Date] {
        var result: [String: Date] = [:]
        for record in records {
            let code = "EL\(record.stageCode.filter(\.isNumber))"
            if let previous = result[code] {
                result[code] = min(previous, record.observedAt)
            } else {
                result[code] = record.observedAt
            }
        }
        return result
    }

    private var seasonalStages: [GrowthStage] {
        let codes = Set(milestones.map { "EL\($0)" })
            .union(firstDates.keys)
            .union(currentCode.map { [$0] } ?? [])
        return GrowthStage.allStages.filter { codes.contains($0.code) }
    }

    private func shortDate(for code: String) -> String {
        guard let date = firstDates[code] else { return "—" }
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = store.settings.resolvedTimeZone
        dateFormatter.locale = Locale.current
        dateFormatter.setLocalizedDateFormatFromTemplate("dMMM")
        return dateFormatter.string(from: date)
    }

    private func name(for stage: GrowthStage) -> String {
        switch stage.code {
        case "EL4": return "Budburst"
        case "EL12": return "Shoots"
        case "EL19", "EL23": return "Flowering"
        case "EL27": return "Fruit Set"
        case "EL35": return "Veraison"
        default: return stage.description.components(separatedBy: ";").first ?? stage.description
        }
    }

    private func stageImage(_ stage: GrowthStage, size: CGFloat) -> some View {
        Color(.tertiarySystemGroupedBackground)
            .frame(width: size, height: size)
            .overlay {
                if let image = store.resolvedELStageImage(for: stage) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .allowsHitTesting(false)
                } else {
                    Image(systemName: "leaf.fill")
                        .font(.title2)
                        .foregroundStyle(green.opacity(0.6))
                }
            }
            .clipShape(.rect(cornerRadius: 11))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Growth Stage")
                        .font(.largeTitle.bold())
                    Text(blockName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                statusBar
                currentStageCard
                seasonalCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(blockName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isCapturing) {
            UnifiedPinComposerView(onSaved: { isCapturing = false })
        }
    }

    private var statusBar: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(milestones, id: \.self) { number in
                    let stage = GrowthStage.allStages.first { $0.code == "EL\(number)" }
                    VStack(spacing: 5) {
                        if let stage { stageImage(stage, size: 52) }
                        Text(stage.map(name(for:)) ?? "Stage")
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("E-L \(number)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 0) {
                ForEach(milestones, id: \.self) { number in
                    let isCurrent = currentCode == "EL\(number)" ||
                        (currentEl != nil && number == (milestones.last(where: { Double($0) <= (currentEl ?? 0) }) ?? -1))
                    Circle()
                        .fill(isCurrent ? green : (currentEl ?? 0) >= Double(number) ? green.opacity(0.16) : Color(.systemGray5))
                        .frame(width: isCurrent ? 20 : 13, height: isCurrent ? 20 : 13)
                        .overlay { Circle().strokeBorder(green, lineWidth: isCurrent ? 3 : 1) }
                        .frame(maxWidth: .infinity)
                    if number != milestones.last {
                        Rectangle()
                            .fill((currentEl ?? 0) >= Double(number) ? green : green.opacity(0.2))
                            .frame(height: 2)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, -12)
                    }
                }
            }
            .frame(height: 22)
            .accessibilityLabel(currentEl.map { "Current stage \(ELRipeness.formatEl($0))" } ?? "No current stage")
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    private var currentStageCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Current Growth Stage").font(.headline)
                Spacer()
                Button("Update Stage", systemImage: "chevron.right") { isCapturing = true }
                    .font(.subheadline.weight(.medium))
                    .tint(green)
            }
            if let currentEl {
                HStack(alignment: .top, spacing: 16) {
                    if let currentStage { stageImage(currentStage, size: 128) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(currentStage.map(name(for:)) ?? "Growth Stage")
                            .font(.title3.bold())
                        Text(ELRipeness.formatEl(currentEl))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        if let currentStage {
                            Text(currentStage.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let date = currentRecord?.observedAt {
                            Label("Recorded \(formatter.formatDate(date))", systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 5)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let notes = currentRecord?.notes, !notes.isEmpty {
                    Label(notes, systemImage: "note.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("No current stage", systemImage: "leaf", description: Text("No eligible recent observation for this block and vintage."))
            }
            Button { isCapturing = true } label: {
                Label("Capture Growth Stage", systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(green)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }

    private var seasonalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Seasonal Development").font(.headline)
                Spacer()
                NavigationLink {
                    GrowthStageHistoryView(blockName: blockName, records: records, formatter: formatter)
                } label: {
                    Label("View All", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                }
                .tint(green)
            }
            .padding(.horizontal, 16)
            if records.isEmpty {
                Text("No observations recorded for this block this vintage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 14) {
                            ForEach(seasonalStages) { stage in
                                VStack(spacing: 5) {
                                    stageImage(stage, size: 76)
                                        .padding(3)
                                        .overlay {
                                            if stage.code == currentCode {
                                                RoundedRectangle(cornerRadius: 14)
                                                    .strokeBorder(green, lineWidth: 2)
                                            }
                                        }
                                    Text(stage.code.replacingOccurrences(of: "EL", with: "E-L "))
                                        .font(.caption.weight(.semibold))
                                    Text(shortDate(for: stage.code))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 82)
                                .id(stage.code)
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .contentMargins(.horizontal, max(16, (geometry.size.width - 82) / 2))
                    .scrollIndicators(.hidden)
                    .onAppear {
                        if let currentCode { proxy.scrollTo(currentCode, anchor: .center) }
                    }
                    .onChange(of: currentCode) { _, newCode in
                        if let newCode {
                            withAnimation(.easeInOut) { proxy.scrollTo(newCode, anchor: .center) }
                        }
                    }
                }
            }
            .frame(height: 128)
        }
        .padding(.vertical, 16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }
}

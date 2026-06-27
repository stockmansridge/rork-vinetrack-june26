import SwiftUI

nonisolated enum PathStatus: Sendable {
    case completed
    case current
    case pending
    case skipped

    var icon: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .current: return "location.circle.fill"
        case .pending: return "circle"
        case .skipped: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .completed: return VineyardTheme.leafGreen
        case .current: return .blue
        case .pending: return .gray.opacity(0.4)
        case .skipped: return .red
        }
    }

    var label: String {
        switch self {
        case .completed: return "Complete"
        case .current: return "Current"
        case .pending: return "To Do"
        case .skipped: return "Skipped"
        }
    }
}

struct TripSummarySheet: View {
    let trip: Trip

    private var completedCount: Int {
        trip.rowSequence.filter { trip.completedPaths.contains($0) }.count
    }

    private var skippedCount: Int {
        trip.rowSequence.filter { trip.skippedPaths.contains($0) }.count
    }

    private var pendingCount: Int {
        trip.rowSequence.count - completedCount - skippedCount - 1
    }

    private var totalCount: Int {
        trip.rowSequence.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    functionHeader
                    patternHeader
                    summaryStats
                    if !trip.tankSessions.isEmpty {
                        tankSessionsList
                    }
                    pathList
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("Trip Summary")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemGroupedBackground))
        }
    }

    @ViewBuilder
    private var functionHeader: some View {
        let label = trip.displayFunctionLabel
        if !label.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(VineyardTheme.earthBrown)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Function")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var patternHeader: some View {
        if trip.trackingPattern == .everySecondRow,
           let startMidrow = trip.rowSequence.first {
            let lowerRow = Int(floor(startMidrow))
            let upperRow = lowerRow + 1
            let preview = trip.rowSequence.prefix(4).map { formatPath($0) }.joined(separator: " → ")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: trip.trackingPattern.icon)
                    Text("Pattern: \(trip.trackingPattern.title)")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VineyardTheme.leafGreen)
                Text("Started between rows \(lowerRow)–\(upperRow)")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                if !preview.isEmpty {
                    Text("Sequence: \(preview)\(trip.rowSequence.count > 4 ? " …" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        }
    }

    private var summaryStats: some View {
        HStack(spacing: 12) {
            StatBadge(count: completedCount, percentage: percentage(completedCount), label: "Done", color: VineyardTheme.leafGreen, icon: "checkmark.circle.fill")
            StatBadge(count: max(0, pendingCount), percentage: percentage(max(0, pendingCount)), label: "To Do", color: .gray, icon: "circle")
            StatBadge(count: skippedCount, percentage: percentage(skippedCount), label: "Skipped", color: .red, icon: "xmark.circle.fill")
        }
    }

    private var pathList: some View {
        VStack(spacing: 0) {
            ForEach(Array(trip.rowSequence.enumerated()), id: \.offset) { index, path in
                let status = statusForPath(path, at: index)
                HStack(spacing: 12) {
                    Image(systemName: status.icon)
                        .font(.title3)
                        .foregroundStyle(status.color)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Path \(formatPath(path))")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(status == .current ? Color.accentColor : .primary)
                        Text("Step \(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(status.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(status.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(status.color.opacity(0.12), in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if index < trip.rowSequence.count - 1 {
                    Divider()
                        .padding(.leading, 56)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func statusForPath(_ path: Double, at index: Int) -> PathStatus {
        if trip.completedPaths.contains(path) {
            return .completed
        }
        if trip.skippedPaths.contains(path) {
            return .skipped
        }
        if index == trip.sequenceIndex {
            return .current
        }
        return .pending
    }

    private func percentage(_ count: Int) -> String {
        guard totalCount > 0 else { return "0%" }
        let pct = Double(count) / Double(totalCount) * 100
        return String(format: "%.0f%%", pct)
    }

    private var tankSessionsList: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Tank Sessions", systemImage: "drop.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(VineyardTheme.leafGreen)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().padding(.leading, 16)

            ForEach(trip.tankSessions) { session in
                HStack(spacing: 12) {
                    Image(systemName: session.endTime != nil ? "checkmark.circle.fill" : "clock.fill")
                        .font(.title3)
                        .foregroundStyle(session.endTime != nil ? VineyardTheme.leafGreen : .orange)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tank \(session.tankNumber)")
                            .font(.subheadline.weight(.medium))
                        if !session.rowRange.isEmpty {
                            Text(session.rowRange)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let fillDur = session.fillDuration {
                            Label("Fill: \(formatFillDuration(fillDur))", systemImage: "drop.fill")
                                .font(.caption)
                                .foregroundStyle(.cyan)
                        }
                    }

                    Spacer()

                    if session.endTime != nil {
                        Text("Complete")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(VineyardTheme.leafGreen)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(VineyardTheme.leafGreen.opacity(0.12), in: Capsule())
                    } else {
                        Text("Active")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if session.id != trip.tankSessions.last?.id {
                    Divider().padding(.leading, 56)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
    }

    private func formatPath(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    private func formatFillDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(seconds, 0))
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }
}

struct StatBadge: View {
    let count: Int
    var percentage: String = ""
    let label: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text("\(count)")
                    .font(.system(.title2, design: .rounded, weight: .bold))
            }
            .foregroundStyle(color)

            Text(percentage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color.opacity(0.8))

            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 10))
    }
}

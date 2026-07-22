import SwiftUI

/// Admin-level audit/repair UI for trip `vineyard_id` integrity across every
/// vineyard the current user can access. Owner/Manager only.
struct AdminTripAuditView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(BackendAccessControl.self) private var accessControl
    @Bindable var service: TripAuditService
    @State private var autoRepair: Bool = true
    @State private var manualSheetTrip: TripAuditService.AuditTrip?

    init(service: TripAuditService) {
        self.service = service
    }

    var body: some View {
        Form {
            controlsSection
            summarySection
            categoriesSection
            problemsSection
        }
        .navigationTitle("Admin Trip Audit")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $manualSheetTrip) { trip in
            ManualReassignSheet(
                trip: trip,
                vineyards: service.nonDeletedVineyards,
                onConfirm: { vineyardId, paddockId in
                    Task {
                        _ = await service.manuallyReassign(
                            tripId: trip.id,
                            toVineyard: vineyardId,
                            paddockId: paddockId
                        )
                    }
                }
            )
        }
    }

    // MARK: - Sections

    private var controlsSection: some View {
        Section {
            Toggle("Auto-repair unambiguous trips", isOn: $autoRepair)
            Button {
                Task { await service.scan(autoRepair: autoRepair) }
            } label: {
                HStack {
                    Label(scanLabel, systemImage: "binoculars")
                    Spacer()
                    if isBusy { ProgressView() }
                }
            }
            .disabled(isBusy || !auth.isSignedIn)
        } header: {
            Text("Audit")
        } footer: {
            Text("Scans every trip you can see across every accessible vineyard. Auto-repair only runs when paddock IDs unambiguously resolve to a single non-deleted vineyard. Trips on deleted vineyards or with ambiguous paddocks need manual review.")
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        let r = service.lastResult
        if r.scanned > 0 || r.ranAt != nil {
            Section {
                LabeledContent("Scanned", value: "\(r.scanned)")
                LabeledContent("Already correct", value: "\(r.alreadyCorrect)")
                LabeledContent("Auto-repaired", value: "\(r.autoRepaired)")
                LabeledContent("Needing review", value: "\(r.needingReview)")
                LabeledContent("Deleted vineyard", value: "\(r.deletedVineyard)")
                if r.pushFailures > 0 {
                    LabeledContent("Push failures", value: "\(r.pushFailures)")
                        .foregroundStyle(.red)
                }
                if let err = service.errorMessage {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Summary")
            }
        }
    }

    @ViewBuilder
    private var categoriesSection: some View {
        let counts = service.lastResult.counts
        if !counts.isEmpty {
            Section {
                ForEach(TripAuditService.ProblemCategory.allCases, id: \.self) { cat in
                    if let n = counts[cat], n > 0 {
                        HStack {
                            Text(cat.label)
                            Spacer()
                            Text("\(n)").font(.callout.weight(.semibold).monospacedDigit())
                        }
                    }
                }
            } header: {
                Text("Problem categories")
            }
        }
    }

    @ViewBuilder
    private var problemsSection: some View {
        let problems = service.problemTrips
        if !problems.isEmpty {
            Section {
                ForEach(problems) { trip in
                    AuditTripRow(trip: trip) {
                        manualSheetTrip = trip
                    }
                }
            } header: {
                Text("Trips needing attention (\(problems.count))")
            }
        }
    }

    private var isBusy: Bool {
        switch service.status {
        case .scanning, .repairing: return true
        default: return false
        }
    }

    private var scanLabel: String {
        switch service.status {
        case .scanning: return "Scanning…"
        case .repairing: return "Repairing…"
        default: return service.lastResult.scanned > 0 ? "Re-scan all vineyards" : "Scan all vineyards"
        }
    }
}

// MARK: - Trip row

private struct AuditTripRow: View {
    let trip: TripAuditService.AuditTrip
    let onReassign: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if trip.currentVineyardDeleted {
                    badge("deleted vineyard", color: .red)
                }
            }
            HStack(spacing: 6) {
                ForEach(trip.problems, id: \.self) { p in
                    badge(p.label, color: color(for: p))
                }
            }
            if let p = trip.paddockName, !p.isEmpty {
                Text("Block: \(p)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let v = trip.currentVineyardName {
                Text("Current vineyard: \(v)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if trip.currentVineyardId == nil {
                Text("Current vineyard: (none)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let inferred = trip.inferredVineyardName, !trip.autoRepaired {
                Text("Suggested vineyard: \(inferred)")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let err = trip.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            HStack {
                Text(trip.id.uuidString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Reassign…", action: onReassign)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        if let title = trip.personName, !title.isEmpty { return title }
        if let p = trip.paddockName, !p.isEmpty { return p }
        return "Trip"
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func color(for p: TripAuditService.ProblemCategory) -> Color {
        switch p {
        case .nullVineyard, .unknownVineyard: return .red
        case .deletedVineyard: return .orange
        case .scalarPaddockMismatch, .paddockIdsMismatch: return .blue
        case .nameOnlyPaddock: return .purple
        case .unsafe: return .gray
        }
    }
}

// MARK: - Manual reassign sheet

private struct ManualReassignSheet: View {
    let trip: TripAuditService.AuditTrip
    let vineyards: [BackendVineyard]
    let onConfirm: (UUID, UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedVineyardId: UUID?
    @State private var keepPaddockId: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    if let p = trip.paddockName, !p.isEmpty {
                        LabeledContent("Block", value: p)
                    }
                    if let person = trip.personName, !person.isEmpty {
                        LabeledContent("Person", value: person)
                    }
                    if let pattern = trip.trackingPattern {
                        LabeledContent("Pattern", value: pattern)
                    }
                    if let start = trip.startTime {
                        LabeledContent("Started", value: start.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let cur = trip.currentVineyardName {
                        LabeledContent("Current vineyard", value: cur + (trip.currentVineyardDeleted ? " (deleted)" : ""))
                    }
                    LabeledContent("Trip ID", value: String(trip.id.uuidString.prefix(8)))
                        .font(.footnote.monospaced())
                }

                Section("Reassign to vineyard") {
                    ForEach(vineyards) { v in
                        Button {
                            selectedVineyardId = v.id
                        } label: {
                            HStack {
                                Text(v.name)
                                Spacer()
                                if selectedVineyardId == v.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if trip.paddockId != nil {
                    Section {
                        Toggle("Keep current paddock_id", isOn: $keepPaddockId)
                    } footer: {
                        Text("Turn off only if you know the existing paddock_id does not belong to the new vineyard.")
                    }
                }
            }
            .navigationTitle("Reassign trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") {
                        if let v = selectedVineyardId {
                            let pid: UUID? = keepPaddockId ? trip.paddockId : nil
                            onConfirm(v, pid)
                            dismiss()
                        }
                    }
                    .disabled(selectedVineyardId == nil)
                }
            }
        }
    }
}

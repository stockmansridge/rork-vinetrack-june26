import SwiftUI
import UIKit

/// Sync diagnostics for confirming multi-device sync status in the field
/// without needing Xcode or Supabase logs. Read-only — does not change sync logic.
struct SyncDiagnosticsView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(PinSyncService.self) private var pinSync
    @Environment(TripSyncService.self) private var tripSync
    @Environment(SprayRecordSyncService.self) private var sprayRecordSync
    @Environment(SavedSprayPresetSyncService.self) private var savedSprayPresetSync
    @Environment(SavedChemicalSyncService.self) private var savedChemicalSync
    @Environment(SavedInputSyncService.self) private var savedInputSync
    @Environment(TripCostAllocationSyncService.self) private var tripCostAllocationSync
    @Environment(WorkTaskSyncService.self) private var workTaskSync
    @Environment(WorkTaskLabourLineSyncService.self) private var workTaskLabourLineSync
    @Environment(WorkTaskPaddockSyncService.self) private var workTaskPaddockSync
    @Environment(GrowthStageRecordSyncService.self) private var growthStageRecordSync
    @Environment(SystemAdminService.self) private var systemAdmin
    @Environment(PaddockSyncService.self) private var paddockSync
    @Environment(PruningSyncService.self) private var pruningSync
    @Environment(FertiliserSyncService.self) private var fertiliserSync

    @State private var copyConfirmation: String?
    @State private var isSyncingAll: Bool = false
    @State private var isForceRepullingPaddocks: Bool = false
    @State private var lastPaddockForceRefresh: PaddockSyncService.ForceRefreshResult?
    @State private var lastPaddockForceRefreshAt: Date?
    @State private var isRepairingTrips: Bool = false
    @State private var lastRepairResult: TripSyncService.RepairResult?
    @State private var lastRepairAt: Date?
    @State private var auditService = TripAuditService()
    @State private var isAuditingTripSync: Bool = false
    @State private var lastTripSyncAudit: TripSyncService.AuditResult?
    @State private var isRepushingNames: Bool = false
    @State private var lastRepushNamesResult: TripSyncService.RepushNamesResult?
    @State private var lastRepushNamesAt: Date?
    @State private var isAuditingPinSync: Bool = false
    @State private var lastPinSyncAudit: PinSyncService.AuditResult?
    @State private var isRefreshingCatalog: Bool = false
    @State private var lastCatalogRefreshCount: Int?
    @State private var lastCatalogRefreshAt: Date?
    @State private var catalogVerification: GrapeVarietyCatalogVerification?
    @State private var catalogVerificationError: String?
    @State private var catalogSource: String = "cache"
    @State private var vineyardVarietyDiagnostics: VineyardGrapeVarietyDiagnostics?
    @State private var vineyardDiagnosticsError: String?
    @State private var isLoadingVarietyDiagnostics: Bool = false
    private let catalogRepository = SupabaseGrapeVarietyCatalogRepository()

    var body: some View {
        Form {
            contextSection
            entitiesSection
            actionsSection
            paddockForceRefreshSection
            grapeVarietyCatalogSection
            grapeVarietyDiagnosticsSection
            if systemAdmin.isEnabled(SystemFeatureFlagKey.showPinDiagnostics) {
                pinAuditSection
            }
            repairSection
            footerSection
        }
        .navigationTitle("Sync Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var contextSection: some View {
        Section {
            LabeledContent("Vineyard", value: store.selectedVineyard?.name ?? "—")
            LabeledContent("Vineyard ID", value: store.selectedVineyardId?.uuidString ?? "—")
                .font(.footnote.monospaced())
            LabeledContent("User ID", value: auth.userId?.uuidString ?? "—")
                .font(.footnote.monospaced())
            LabeledContent("Role", value: accessControl.currentRole?.rawValue.capitalized ?? "—")
            LabeledContent("Signed in", value: auth.isSignedIn ? "Yes" : "No")
            LabeledContent("Backend", value: SupabaseClientProvider.shared.isConfigured ? "Connected" : "Not configured")
        } header: {
            Text("Context")
        } footer: {
            Text("No tokens, secrets or emails are shown.")
        }
    }

    private var entitiesSection: some View {
        Section {
            ForEach(rows) { row in
                EntityDiagnosticRow(row: row)
            }
        } header: {
            Text("Entities")
        } footer: {
            Text("Local = rows currently loaded for the selected vineyard. Pending = local changes not yet pushed.")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await syncAll() }
            } label: {
                HStack {
                    Label(isSyncingAll ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if isSyncingAll { ProgressView() }
                }
            }
            .disabled(isSyncingAll || !auth.isSignedIn || store.selectedVineyardId == nil)

            Button {
                copyDiagnostics()
            } label: {
                Label("Copy sync diagnostics", systemImage: "doc.on.doc")
            }
            if let copyConfirmation {
                Text(copyConfirmation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Actions")
        }
    }

    @ViewBuilder
    private var paddockForceRefreshSection: some View {
        Section {
            Button {
                Task { await forceRepullPaddocks() }
            } label: {
                HStack {
                    Label(
                        isForceRepullingPaddocks ? "Refreshing blocks…" : "Force refresh blocks from server",
                        systemImage: "square.and.arrow.down.on.square"
                    )
                    Spacer()
                    if isForceRepullingPaddocks { ProgressView() }
                }
            }
            .disabled(isForceRepullingPaddocks || !auth.isSignedIn || store.selectedVineyardId == nil)

            if let result = lastPaddockForceRefresh {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last force refresh")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        metric("Pulled", value: "\(result.pulled)")
                        metric("Upserts", value: "\(result.appliedUpserts)", highlight: result.appliedUpserts > 0)
                        metric("Deletes", value: "\(result.appliedDeletes)", highlight: result.appliedDeletes > 0)
                    }
                    if let err = result.error, !err.isEmpty {
                        Text("Error: \(err)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                    if let at = lastPaddockForceRefreshAt {
                        Text("Ran: \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Block Force Refresh")
        } footer: {
            Text("Pulls every block for the selected vineyard from Supabase and overwrites the local cache, ignoring the local sync watermark. Use this after a server-side repair (e.g. grape variety canonicalisation) when local blocks still show stale data such as `Unknown` varieties. Local changes that were already pushed are unaffected; unpushed local edits to those blocks will be replaced by the server row.")
        }
    }

    @ViewBuilder
    private var grapeVarietyCatalogSection: some View {
        Section {
            Button {
                Task { await refreshSharedCatalog() }
            } label: {
                HStack {
                    Label(
                        isRefreshingCatalog ? "Refreshing catalogue\u{2026}" : "Refresh shared grape variety catalogue",
                        systemImage: "leaf.arrow.circlepath"
                    )
                    Spacer()
                    if isRefreshingCatalog { ProgressView() }
                }
            }
            .disabled(isRefreshingCatalog || !auth.isSignedIn)

            if let count = lastCatalogRefreshCount {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Entries: \(count)")
                        .font(.caption.monospacedDigit())
                    if let at = lastCatalogRefreshAt {
                        Text("Ran: \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Grape Variety Catalogue")
        } footer: {
            Text("Pulls the shared Supabase grape variety catalogue (built-ins + aliases) and caches it locally for offline use. Run this after the catalogue is updated server-side so pickers and resolvers (Pinot Gris / Grigio etc.) reflect the latest data without waiting for the next launch.")
        }
    }

    private func refreshSharedCatalog() async {
        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        let entries = await SharedGrapeVarietyCatalogCache.shared.refresh()
        lastCatalogRefreshCount = entries.count
        lastCatalogRefreshAt = Date()
        catalogSource = entries.isEmpty ? "offline fallback" : "Supabase"
        await loadVarietyDiagnostics()
    }

    @ViewBuilder
    private var grapeVarietyDiagnosticsSection: some View {
        if systemAdmin.isSystemAdmin && systemAdmin.isEnabled(SystemFeatureFlagKey.showVarietyDiagnostics) {
            Section {
                Button {
                    Task { await loadVarietyDiagnostics() }
                } label: {
                    HStack {
                        Label(
                            isLoadingVarietyDiagnostics ? "Loading\u{2026}" : "Refresh diagnostics",
                            systemImage: "chart.bar.doc.horizontal"
                        )
                        Spacer()
                        if isLoadingVarietyDiagnostics { ProgressView() }
                    }
                }
                .disabled(isLoadingVarietyDiagnostics || !auth.isSignedIn)

                if let v = catalogVerification {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shared grape variety catalogue")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 14) {
                            metric("Active built-in", value: "\(v.activeBuiltinCount)")
                            metric("Inactive built-in", value: "\(v.inactiveBuiltinCount)", highlight: v.inactiveBuiltinCount > 0)
                            metric("Aliases", value: "\(v.totalAliases)")
                        }
                        HStack(spacing: 14) {
                            metric("Pinot Gris", value: v.pinotGrisActive ? "active" : "inactive", highlight: !v.pinotGrisActive)
                            metric("Grigio→Gris", value: v.pinotGrigioResolvesToPinotGris ? "ok" : "miss", highlight: !v.pinotGrigioResolvesToPinotGris)
                        }
                        if let updated = v.lastUpdatedAt {
                            Text("Last catalogue update: \(updated.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let at = lastCatalogRefreshAt {
                            Text("Last cache refresh: \(at.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("Source: \(catalogSource)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let count = lastCatalogRefreshCount {
                            Text("Cached entries: \(count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } else if let err = catalogVerificationError {
                    Text("Catalogue: \(err)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                if let d = vineyardVarietyDiagnostics {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vineyard grape varieties")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 14) {
                            metric("Total", value: "\(d.vineyardVarietyCount)")
                            metric("Built-in", value: "\(d.builtinCount)")
                            metric("Custom", value: "\(d.customCount)", highlight: d.customCount > 0)
                        }
                        HStack(spacing: 14) {
                            metric("Archived", value: "\(d.archivedCount)", highlight: d.archivedCount > 0)
                            metric("Unresolved", value: "\(d.unresolvedAllocations)", highlight: d.unresolvedAllocations > 0)
                        }
                    }
                    .padding(.vertical, 2)
                } else if let err = vineyardDiagnosticsError {
                    Text("Vineyard: \(err)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Grape Variety Diagnostics")
            } footer: {
                Text("Counts come from Supabase via verify_grape_variety_catalog() and grape_variety_diagnostics(). Unresolved allocations require system admin and are 0 when all paddock variety_allocations rows have a catalog-resolvable varietyKey/name.")
            }
        }
    }

    private func loadVarietyDiagnostics() async {
        guard !isLoadingVarietyDiagnostics else { return }
        isLoadingVarietyDiagnostics = true
        defer { isLoadingVarietyDiagnostics = false }

        do {
            catalogVerification = try await catalogRepository.verifyCatalog()
            catalogVerificationError = nil
        } catch {
            catalogVerificationError = String(describing: error)
        }

        if let vineyardId = store.selectedVineyardId {
            do {
                vineyardVarietyDiagnostics = try await catalogRepository.fetchVineyardDiagnostics(vineyardId: vineyardId)
                vineyardDiagnosticsError = nil
            } catch {
                vineyardDiagnosticsError = String(describing: error)
            }
        } else {
            vineyardVarietyDiagnostics = nil
            vineyardDiagnosticsError = "No vineyard selected"
        }
    }

    private func forceRepullPaddocks() async {
        guard !isForceRepullingPaddocks, let vineyardId = store.selectedVineyardId else { return }
        isForceRepullingPaddocks = true
        defer { isForceRepullingPaddocks = false }
        let result = await paddockSync.forceRepullAllPaddocks(vineyardId: vineyardId)
        lastPaddockForceRefresh = result
        lastPaddockForceRefreshAt = Date()
    }

    private var pinAuditSection: some View {
        Section {
            Button {
                Task { await runPinSyncAudit() }
            } label: {
                HStack {
                    Label(isAuditingPinSync ? "Auditing pins…" : "Audit pin sync (selected vineyard)", systemImage: "checklist")
                    Spacer()
                    if isAuditingPinSync { ProgressView() }
                }
            }
            .disabled(isAuditingPinSync || !auth.isSignedIn || store.selectedVineyardId == nil)

            if let audit = lastPinSyncAudit {
                pinSyncAuditView(audit)
            }
        } header: {
            Text("Pin Audit")
        } footer: {
            Text("Compares local pins against Supabase for the selected vineyard. Shows local-only pins (not uploaded), remote-only pins (only in Supabase), orphan pins (wrong vineyard), and remote soft-deleted pins. Copy diagnostics to share full pin IDs with the portal team.")
        }
    }

    @ViewBuilder
    private func pinSyncAuditView(_ audit: PinSyncService.AuditResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last pin sync audit")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                metric("Local", value: "\(audit.localForVineyard)")
                metric("Remote active", value: "\(audit.remoteActive)")
                metric("Local-only", value: "\(audit.localOnlyIds.count)", highlight: !audit.localOnlyIds.isEmpty)
                metric("Remote-only", value: "\(audit.remoteOnlyIds.count)", highlight: !audit.remoteOnlyIds.isEmpty)
            }
            HStack(spacing: 14) {
                metric("All local", value: "\(audit.localAcrossAllVineyards)")
                metric("Orphans", value: "\(audit.localVineyardMismatch.count)", highlight: !audit.localVineyardMismatch.isEmpty)
                metric("Soft-deleted", value: "\(audit.remoteSoftDeleted)", highlight: audit.remoteSoftDeleted > 0)
                metric("Pending", value: "\(pinSync.pendingUpsertCount)", highlight: pinSync.pendingUpsertCount > 0)
            }
            if let err = audit.error, !err.isEmpty {
                Text("Error: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if !audit.localOnlyDetails.isEmpty {
                DisclosureGroup("Local-only pins — not in Supabase (\(audit.localOnlyDetails.count))") {
                    ForEach(audit.localOnlyDetails) { d in
                        localPinDetailRow(d)
                    }
                }
                .font(.footnote)
            }
            if !audit.orphanLocalDetails.isEmpty {
                DisclosureGroup("Orphan local pins — wrong vineyard (\(audit.orphanLocalDetails.count))") {
                    ForEach(audit.orphanLocalDetails) { d in
                        localPinDetailRow(d)
                    }
                }
                .font(.footnote)
            }
            if !audit.remoteSoftDeletedDetails.isEmpty {
                DisclosureGroup("Remote soft-deleted (\(audit.remoteSoftDeletedDetails.count))") {
                    ForEach(audit.remoteSoftDeletedDetails) { d in
                        remotePinDetailRow(d)
                    }
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func localPinDetailRow(_ d: PinSyncService.LocalPinDetail) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(d.title.isEmpty ? "(no title)" : d.title)
                    .font(.caption.weight(.semibold))
                Text(d.mode)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if d.isCompleted {
                    Text("completed").font(.caption2).foregroundStyle(.green)
                }
                if d.isPendingUpsert {
                    Text("pending").font(.caption2).foregroundStyle(.orange)
                }
                if d.isPendingDelete {
                    Text("pending-delete").font(.caption2).foregroundStyle(.red)
                }
            }
            Text("pin_id: \(d.id.uuidString)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("vineyard_id: \(d.localVineyardId.uuidString)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if let p = d.paddockId {
                Text("paddock: \(d.paddockName ?? "—") (\(p.uuidString))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("paddock: (none)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
            }
            if let code = d.growthStageCode, !code.isEmpty {
                Text("growth_stage: \(code)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("created: \(d.createdAt.formatted(date: .abbreviated, time: .shortened)) by \(d.createdBy ?? "—")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func remotePinDetailRow(_ d: PinSyncService.RemotePinDetail) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(d.title.isEmpty ? "(no title)" : d.title)
                    .font(.caption.weight(.semibold))
                if let mode = d.mode {
                    Text(mode).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("pin_id: \(d.id.uuidString)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let del = d.deletedAt {
                Text("deleted_at: \(del.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if let p = d.paddockId {
                Text("paddock_id: \(p.uuidString)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func runPinSyncAudit() async {
        guard !isAuditingPinSync, let vineyardId = store.selectedVineyardId else { return }
        isAuditingPinSync = true
        defer { isAuditingPinSync = false }
        let result = await pinSync.auditPinSync(vineyardId: vineyardId)
        lastPinSyncAudit = result
    }

    @ViewBuilder
    private var repairSection: some View {
        if canRepairTrips {
            Section {
                Button {
                    Task { await repairTripVineyardIds() }
                } label: {
                    HStack {
                        Label(isRepairingTrips ? "Repairing…" : "Repair trip vineyard IDs", systemImage: "wrench.and.screwdriver")
                        Spacer()
                        if isRepairingTrips { ProgressView() }
                    }
                }
                .disabled(isRepairingTrips || !auth.isSignedIn || store.selectedVineyardId == nil)

                if let result = lastRepairResult {
                    repairSummaryView(result)
                }

                NavigationLink {
                    AdminTripAuditView(service: auditService)
                } label: {
                    Label("Admin trip vineyard audit", systemImage: "binoculars")
                }

                Button {
                    Task { await repushTripNames() }
                } label: {
                    HStack {
                        Label(isRepushingNames ? "Repairing & pushing…" : "Repair & push local trips", systemImage: "text.badge.plus")
                        Spacer()
                        if isRepushingNames { ProgressView() }
                    }
                }
                .disabled(isRepushingNames || !auth.isSignedIn || store.selectedVineyardId == nil)

                if let result = lastRepushNamesResult {
                    repushNamesSummaryView(result)
                }

                Button {
                    Task { await runTripSyncAudit() }
                } label: {
                    HStack {
                        Label(isAuditingTripSync ? "Auditing…" : "Audit trip sync (selected vineyard)", systemImage: "checklist")
                        Spacer()
                        if isAuditingTripSync { ProgressView() }
                    }
                }
                .disabled(isAuditingTripSync || !auth.isSignedIn || store.selectedVineyardId == nil)

                if let audit = lastTripSyncAudit {
                    tripSyncAuditView(audit)
                }
            } header: {
                Text("Trip Repair")
            } footer: {
    Text("Quick repair fixes local trips for the selected vineyard. Repair & push local trips scans every local trip, safely repairs vineyard mismatches when paddocks resolve unambiguously, and pushes trip function/title plus vineyard/paddock data to Supabase. The Admin audit scans trips across every vineyard you can access (including deleted ones) and offers per-trip manual reassignment for cases that aren't safe to auto-repair.")
            }
        }
    }

    private var canRepairTrips: Bool {
        switch accessControl.currentRole {
        case .owner, .manager: return true
        default: return false
        }
    }

    @ViewBuilder
    private func repairSummaryView(_ result: TripSyncService.RepairResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last repair")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                metric("Scanned", value: "\(result.scanned)")
                metric("Repaired", value: "\(result.repaired)", highlight: result.repaired > 0)
                metric("Pushed", value: "\(result.pushed)", highlight: result.pushed > 0)
                metric("Skipped", value: "\(result.skipped.count)", highlight: !result.skipped.isEmpty)
            }
            if let err = result.syncError, !err.isEmpty {
                Text("Sync error: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if !result.skipped.isEmpty {
                DisclosureGroup("Skipped trips (\(result.skipped.count))") {
                    ForEach(Array(result.skipped.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.tripId.uuidString)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(item.reason)
                                .font(.caption2)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func tripSyncAuditView(_ audit: TripSyncService.AuditResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last trip sync audit")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                metric("Local", value: "\(audit.localForVineyard)")
                metric("Remote", value: "\(audit.remoteForVineyard)")
                metric("Local-only", value: "\(audit.localOnlyIds.count)", highlight: !audit.localOnlyIds.isEmpty)
                metric("Orphans", value: "\(audit.localVineyardMismatch.count)", highlight: !audit.localVineyardMismatch.isEmpty)
            }
            HStack(spacing: 14) {
                metric("All local", value: "\(audit.localAcrossAllVineyards)")
                metric("Pending", value: "\(tripSync.pendingUpsertCount)", highlight: tripSync.pendingUpsertCount > 0)
                metric("Soft-deleted", value: "\(audit.remoteSoftDeleted)")
                metric("Remote no-name", value: "\(audit.remoteMissingFunction)", highlight: audit.remoteMissingFunction > 0)
            }
            if let err = audit.error, !err.isEmpty {
                Text("Error: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if !audit.localOnlyDetails.isEmpty {
                DisclosureGroup("Local-only trips (\(audit.localOnlyDetails.count))") {
                    ForEach(audit.localOnlyDetails) { d in
                        localTripDetailRow(d)
                    }
                }
                .font(.footnote)
            }
            if !audit.orphanLocalDetails.isEmpty {
                DisclosureGroup("Orphan local trips — wrong vineyard (\(audit.orphanLocalDetails.count))") {
                    ForEach(audit.orphanLocalDetails) { d in
                        localTripDetailRow(d)
                    }
                }
                .font(.footnote)
            }
            if audit.remoteMissingFunction > 0 {
                Text("\(audit.remoteMissingFunction) remote trip(s) have no trip_function/trip_title. If iOS shows a label like \"Harrowing\" but Supabase shows blank, run sql/023_trips_function_title.sql on the database, then Sync now.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            tripFunctionDistributionView(audit)
        }
        .padding(.vertical, 4)
    }

    /// Ordered list of canonical TripFunction raw values. Anything outside this
    /// list (including `(none)` and `(unknown:*)`) is appended after.
    private static let canonicalFunctionOrder: [String] = TripFunction.allCases.map { $0.rawValue }

    private func orderedFunctionKeys(local: [String: Int], remote: [String: Int]) -> [String] {
        let union = Set(local.keys).union(remote.keys)
        var ordered: [String] = []
        for key in Self.canonicalFunctionOrder where union.contains(key) {
            ordered.append(key)
        }
        let extras = union.subtracting(ordered).sorted()
        ordered.append(contentsOf: extras)
        return ordered
    }

    private func functionDisplayName(_ key: String) -> String {
        if key == "(none)" { return "(no function)" }
        if key.hasPrefix("(unknown:") { return key }
        return TripFunction(rawValue: key)?.displayName ?? key
    }

    private struct FunctionDistributionRow: Identifiable {
        let id: String
        let display: String
        let local: Int
        let remote: Int
        var diff: Int { local - remote }
    }

    private func functionDistributionRows(_ audit: TripSyncService.AuditResult) -> [FunctionDistributionRow] {
        let keys = orderedFunctionKeys(
            local: audit.localFunctionCounts,
            remote: audit.remoteFunctionCounts
        )
        return keys.map { key in
            FunctionDistributionRow(
                id: key,
                display: functionDisplayName(key),
                local: audit.localFunctionCounts[key] ?? 0,
                remote: audit.remoteFunctionCounts[key] ?? 0
            )
        }
    }

    @ViewBuilder
    private func tripFunctionDistributionView(_ audit: TripSyncService.AuditResult) -> some View {
        if !audit.localFunctionCounts.isEmpty || !audit.remoteFunctionCounts.isEmpty {
            DisclosureGroup("Trip function distribution") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Function").font(.caption2.weight(.semibold))
                        Spacer()
                        Text("Local").font(.caption2.weight(.semibold)).frame(width: 50, alignment: .trailing)
                        Text("Remote").font(.caption2.weight(.semibold)).frame(width: 60, alignment: .trailing)
                        Text("Diff").font(.caption2.weight(.semibold)).frame(width: 50, alignment: .trailing)
                    }
                    .foregroundStyle(.secondary)
                    ForEach(functionDistributionRows(audit)) { row in
                        HStack {
                            Text(row.display)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text("\(row.local)").font(.caption.monospacedDigit()).frame(width: 50, alignment: .trailing)
                            Text("\(row.remote)").font(.caption.monospacedDigit()).frame(width: 60, alignment: .trailing)
                            Text(row.diff == 0 ? "0" : (row.diff > 0 ? "+\(row.diff)" : "\(row.diff)"))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(row.diff == 0 ? Color.secondary : Color.orange)
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .font(.footnote)
        }
    }

    @ViewBuilder
    private func localTripDetailRow(_ d: TripSyncService.LocalTripDetail) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(d.function ?? d.title ?? "(no name)")
                    .font(.caption.weight(.semibold))
                if let s = d.startTime {
                    Text(s.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let p = d.paddockName, !p.isEmpty {
                Text("paddocks: \(p)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("trip_id: \(d.id.uuidString)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text("vineyard_id: \(d.localVineyardId.uuidString)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if d.inferredFromPaddocks, let inferred = d.inferredVineyardId, inferred != d.localVineyardId {
                Text("→ paddocks resolve to: \(inferred.uuidString)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func runTripSyncAudit() async {
        guard !isAuditingTripSync, let vineyardId = store.selectedVineyardId else { return }
        isAuditingTripSync = true
        defer { isAuditingTripSync = false }
        let result = await tripSync.auditTripSync(vineyardId: vineyardId)
        lastTripSyncAudit = result
    }

    private func metric(_ label: String, value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(highlight ? Color.orange : .primary)
        }
    }

    @ViewBuilder
    private func repushNamesSummaryView(_ result: TripSyncService.RepushNamesResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last repair & push local trips")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                metric("Scanned", value: "\(result.scanned)")
                metric("With name", value: "\(result.withFunctionOrTitle)")
                metric("Repaired", value: "\(result.repairedFromPaddocks)", highlight: result.repairedFromPaddocks > 0)
                metric("Pushed", value: "\(result.pushed)", highlight: result.pushed > 0)
            }
            HStack(spacing: 14) {
                metric("Already OK", value: "\(result.alreadyAssigned)")
                metric("Marked", value: "\(result.markedForUpload)", highlight: result.markedForUpload > 0)
                metric("Skipped", value: "\(result.skipped.count)", highlight: !result.skipped.isEmpty)
            }
            if let err = result.error, !err.isEmpty {
                Text("Error: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if !result.skipped.isEmpty {
                DisclosureGroup("Skipped trips (\(result.skipped.count))") {
                    ForEach(Array(result.skipped.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.tripId.uuidString)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(item.reason)
                                .font(.caption2)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }

    private func repushTripNames() async {
        guard !isRepushingNames, let vineyardId = store.selectedVineyardId else { return }
        isRepushingNames = true
        defer { isRepushingNames = false }
        let result = await tripSync.repushTripNames(vineyardId: vineyardId)
        lastRepushNamesResult = result
        lastRepushNamesAt = Date()
    }

    private func repairTripVineyardIds() async {
        guard !isRepairingTrips, let vineyardId = store.selectedVineyardId else { return }
        isRepairingTrips = true
        defer { isRepairingTrips = false }
        let result = await tripSync.repairVineyardIds(selectedVineyardId: vineyardId)
        lastRepairResult = result
        lastRepairAt = Date()
    }

    private var footerSection: some View {
        Section {
            Text("Use these counters to confirm whether a record created on one device has reached Supabase and synced to other devices for the same vineyard. If pending counts stay above zero, tap Sync now and check again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Rows

    fileprivate struct DiagnosticRow: Identifiable {
        let id: String
        let title: String
        let icon: String
        let localCount: Int
        let pendingUpserts: Int
        let pendingDeletes: Int
        let lastSync: Date?
        let status: GenericSyncStatus
        let errorMessage: String?
    }

    fileprivate enum GenericSyncStatus: String {
        case idle, syncing, success, failure
    }

    private var rows: [DiagnosticRow] {
        let vineyardId = store.selectedVineyardId
        return [
            DiagnosticRow(
                id: "trips",
                title: "Trips",
                icon: "map",
                localCount: filteredCount(store.trips, vineyardId: vineyardId) { $0.vineyardId },
                pendingUpserts: tripSync.pendingUpsertCount,
                pendingDeletes: tripSync.pendingDeleteCount,
                lastSync: tripSync.lastSyncDate,
                status: status(tripSync.syncStatus),
                errorMessage: tripSync.errorMessage
            ),
            DiagnosticRow(
                id: "spray_records",
                title: "Spray Records",
                icon: "drop.fill",
                localCount: filteredCount(store.sprayRecords, vineyardId: vineyardId) { $0.vineyardId },
                pendingUpserts: sprayRecordSync.pendingUpsertCount,
                pendingDeletes: sprayRecordSync.pendingDeleteCount,
                lastSync: sprayRecordSync.lastSyncDate,
                status: statusM(sprayRecordSync.syncStatus),
                errorMessage: sprayRecordSync.errorMessage
            ),
            DiagnosticRow(
                id: "spray_presets",
                title: "Spray Presets / Programs",
                icon: "slider.horizontal.3",
                localCount: filteredCount(store.savedSprayPresets, vineyardId: vineyardId) { $0.vineyardId },
                pendingUpserts: savedSprayPresetSync.pendingUpsertCount,
                pendingDeletes: savedSprayPresetSync.pendingDeleteCount,
                lastSync: savedSprayPresetSync.lastSyncDate,
                status: statusMgmt(savedSprayPresetSync.syncStatus),
                errorMessage: savedSprayPresetSync.errorMessage
            ),
            DiagnosticRow(
                id: "pins",
                title: "Pins",
                icon: "mappin.and.ellipse",
                localCount: filteredCount(store.pins, vineyardId: vineyardId) { $0.vineyardId },
                pendingUpserts: pinSync.pendingUpsertCount,
                pendingDeletes: pinSync.pendingDeleteCount,
                lastSync: pinSync.lastSyncDate,
                status: status(pinSync.syncStatus),
                errorMessage: pinSync.errorMessage
            ),
            DiagnosticRow(
                id: "work_tasks",
                title: "Work Tasks",
                icon: "person.2.badge.gearshape.fill",
                localCount: filteredCount(store.workTasks, vineyardId: vineyardId) { $0.vineyardId },
                pendingUpserts: workTaskSync.pendingUpsertCount,
                pendingDeletes: workTaskSync.pendingDeleteCount,
                lastSync: workTaskSync.lastSyncDate,
                status: statusOps(workTaskSync.syncStatus),
                errorMessage: workTaskSync.errorMessage
            ),
            DiagnosticRow(
                id: "work_task_labour_lines",
                title: "Work Task Labour Lines",
                icon: "clock.badge.checkmark.fill",
                localCount: filteredCount(store.workTaskLabourLines, vineyardId: vineyardId) { $0.vineyardId },
                pendingUpserts: workTaskLabourLineSync.pendingUpsertCount,
                pendingDeletes: workTaskLabourLineSync.pendingDeleteCount,
                lastSync: workTaskLabourLineSync.lastSyncDate,
                status: statusOps(workTaskLabourLineSync.syncStatus),
                errorMessage: workTaskLabourLineSync.errorMessage
            ),
            DiagnosticRow(
                id: "work_task_paddocks",
                title: "Work Task Paddocks",
                icon: "square.grid.2x2",
                localCount: filteredCount(store.workTaskPaddocks, vineyardId: vineyardId) { $0.vineyardId },
                pendingUpserts: workTaskPaddockSync.pendingUpsertCount,
                pendingDeletes: workTaskPaddockSync.pendingDeleteCount,
                lastSync: workTaskPaddockSync.lastSyncDate,
                status: statusOps(workTaskPaddockSync.syncStatus),
                errorMessage: workTaskPaddockSync.errorMessage
            ),
            DiagnosticRow(
                id: "growth_stage_records",
                title: "Growth Stage Records",
                icon: "leaf.fill",
                localCount: filteredCount(growthStageRecordSync.records, vineyardId: vineyardId) { $0.vineyardId },
                pendingUpserts: growthStageRecordSync.pendingUpsertCount,
                pendingDeletes: growthStageRecordSync.pendingDeleteCount,
                lastSync: growthStageRecordSync.lastSyncDate,
                status: statusGrowthRecord(growthStageRecordSync.syncStatus),
                errorMessage: growthStageRecordSync.errorMessage
            ),
            DiagnosticRow(
                id: "chemicals",
                title: "Chemicals",
                icon: "flask.fill",
                localCount: filteredCount(store.savedChemicals, vineyardId: vineyardId) { $0.vineyardId },
                pendingUpserts: savedChemicalSync.pendingUpsertCount,
                pendingDeletes: savedChemicalSync.pendingDeleteCount,
                lastSync: savedChemicalSync.lastSyncDate,
                status: statusMgmt(savedChemicalSync.syncStatus),
                errorMessage: savedChemicalSync.errorMessage
            ),
            DiagnosticRow(
                id: "saved_inputs",
                title: "Saved Inputs",
                icon: "leaf.fill",
                localCount: filteredCount(store.savedInputs, vineyardId: vineyardId) { $0.vineyardId },
                pendingUpserts: savedInputSync.pendingUpsertCount,
                pendingDeletes: savedInputSync.pendingDeleteCount,
                lastSync: savedInputSync.lastSyncDate,
                status: statusMgmt(savedInputSync.syncStatus),
                errorMessage: savedInputSync.errorMessage
            ),
            DiagnosticRow(
                id: "trip_cost_allocations",
                title: "Cost Allocations",
                icon: "dollarsign.circle.fill",
                localCount: filteredCount(store.tripCostAllocations, vineyardId: vineyardId) { $0.vineyardId },
                pendingUpserts: tripCostAllocationSync.pendingUpsertCount,
                pendingDeletes: tripCostAllocationSync.pendingDeleteCount,
                lastSync: tripCostAllocationSync.lastSyncDate,
                status: statusMgmt(tripCostAllocationSync.syncStatus),
                errorMessage: tripCostAllocationSync.errorMessage
            ),
            DiagnosticRow(
                id: "pruning",
                title: "Pruning Tracker",
                icon: "scissors",
                localCount: filteredCount(PruningStore.shared.entries, vineyardId: vineyardId) { $0.vineyardId },
                pendingUpserts: pruningSync.pendingUpsertCount,
                pendingDeletes: pruningSync.pendingDeleteCount,
                lastSync: pruningSync.lastSyncDate,
                status: statusMgmt(pruningSync.syncStatus),
                errorMessage: pruningSync.errorMessage
            ),
            DiagnosticRow(
                id: "fertiliser",
                title: "Fertiliser Records",
                icon: "leaf.circle.fill",
                localCount: filteredCount(FertiliserStore.shared.records, vineyardId: vineyardId) { $0.vineyardId },
                pendingUpserts: fertiliserSync.pendingUpsertCount,
                pendingDeletes: fertiliserSync.pendingDeleteCount,
                lastSync: fertiliserSync.lastSyncDate,
                status: statusMgmt(fertiliserSync.syncStatus),
                errorMessage: fertiliserSync.errorMessage
            )
        ]
    }

    private func filteredCount<T>(_ items: [T], vineyardId: UUID?, _ keyPath: (T) -> UUID?) -> Int {
        guard let vineyardId else { return items.count }
        return items.reduce(0) { $0 + (keyPath($1) == vineyardId ? 1 : 0) }
    }

    private func status(_ s: PinSyncService.Status) -> GenericSyncStatus {
        switch s { case .idle: .idle; case .syncing: .syncing; case .success: .success; case .failure: .failure }
    }
    private func status(_ s: TripSyncService.Status) -> GenericSyncStatus {
        switch s { case .idle: .idle; case .syncing: .syncing; case .success: .success; case .failure: .failure }
    }
    private func statusM(_ s: SprayRecordSyncService.Status) -> GenericSyncStatus {
        switch s { case .idle: .idle; case .syncing: .syncing; case .success: .success; case .failure: .failure }
    }
    private func statusMgmt(_ s: ManagementSyncStatus) -> GenericSyncStatus {
        switch s { case .idle: .idle; case .syncing: .syncing; case .success: .success; case .failure: .failure }
    }
    private func statusOps(_ s: OperationsSyncStatus) -> GenericSyncStatus {
        switch s { case .idle: .idle; case .syncing: .syncing; case .success: .success; case .failure: .failure }
    }
    private func statusGrowthRecord(_ s: GrowthStageRecordSyncService.Status) -> GenericSyncStatus {
        switch s { case .idle: .idle; case .syncing: .syncing; case .success: .success; case .failure: .failure }
    }

    // MARK: - Actions

    private func syncAll() async {
        guard !isSyncingAll else { return }
        isSyncingAll = true
        defer { isSyncingAll = false }
        await pinSync.syncPinsForSelectedVineyard()
        await tripSync.syncTripsForSelectedVineyard()
        await sprayRecordSync.syncSprayRecordsForSelectedVineyard()
        await savedSprayPresetSync.syncForSelectedVineyard()
        await savedChemicalSync.syncForSelectedVineyard()
        await savedInputSync.syncForSelectedVineyard()
        await workTaskSync.syncForSelectedVineyard()
        await workTaskLabourLineSync.syncForSelectedVineyard()
        await workTaskPaddockSync.syncForSelectedVineyard()
        await growthStageRecordSync.syncForSelectedVineyard()
        await pruningSync.syncForSelectedVineyard()
        await fertiliserSync.syncForSelectedVineyard()
    }

    private func copyDiagnostics() {
        let text = diagnosticsText()
        UIPasteboard.general.string = text
        copyConfirmation = "Copied to clipboard."
        Task {
            try? await Task.sleep(for: .seconds(2))
            copyConfirmation = nil
        }
    }

    private func diagnosticsText() -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        var lines: [String] = []
        lines.append("Sync Diagnostics")
        lines.append("Time: \(df.string(from: Date()))")
        lines.append("")
        lines.append("Context")
        lines.append("Vineyard: \(store.selectedVineyard?.name ?? "—")")
        lines.append("Vineyard ID: \(store.selectedVineyardId?.uuidString ?? "—")")
        lines.append("User ID: \(auth.userId?.uuidString ?? "—")")
        lines.append("Role: \(accessControl.currentRole?.rawValue ?? "—")")
        lines.append("Signed in: \(auth.isSignedIn ? "yes" : "no")")
        lines.append("Backend: \(SupabaseClientProvider.shared.isConfigured ? "connected" : "not_configured")")
        lines.append("")
        lines.append("Entities")
        for r in rows {
            lines.append("- \(r.title)")
            lines.append("  local: \(r.localCount)")
            lines.append("  pending_upserts: \(r.pendingUpserts)")
            lines.append("  pending_deletes: \(r.pendingDeletes)")
            lines.append("  last_sync: \(r.lastSync.map { df.string(from: $0) } ?? "never")")
            lines.append("  status: \(r.status.rawValue)")
            if let err = r.errorMessage, !err.isEmpty {
                lines.append("  last_error: \(err)")
            }
        }
        lines.append("")
        lines.append("Sync running: \(isSyncingAll ? "yes" : "no")")
        if let result = lastRepairResult {
            lines.append("")
            lines.append("Trip Vineyard ID Repair")
            if let at = lastRepairAt {
                lines.append("  ran_at: \(df.string(from: at))")
            }
            lines.append("  scanned: \(result.scanned)")
            lines.append("  already_correct: \(result.alreadyCorrect)")
            lines.append("  repaired: \(result.repaired)")
            lines.append("  pushed: \(result.pushed)")
            lines.append("  skipped: \(result.skipped.count)")
            for item in result.skipped {
                lines.append("    - \(item.tripId.uuidString): \(item.reason)")
            }
            if let err = result.syncError, !err.isEmpty {
                lines.append("  sync_error: \(err)")
            }
        }
        if let result = lastRepushNamesResult {
            lines.append("")
            lines.append("Repair & Push Local Trips")
            if let at = lastRepushNamesAt {
                lines.append("  ran_at: \(df.string(from: at))")
            }
            lines.append("  scanned: \(result.scanned)")
            lines.append("  with_function_or_title: \(result.withFunctionOrTitle)")
            lines.append("  already_assigned: \(result.alreadyAssigned)")
            lines.append("  repaired_from_paddocks: \(result.repairedFromPaddocks)")
            lines.append("  marked_for_upload: \(result.markedForUpload)")
            lines.append("  pushed: \(result.pushed)")
            lines.append("  skipped: \(result.skipped.count)")
            for item in result.skipped {
                lines.append("    - \(item.tripId.uuidString): \(item.reason)")
            }
            if let err = result.error, !err.isEmpty {
                lines.append("  error: \(err)")
            }
        }
        if let audit = lastTripSyncAudit {
            lines.append("")
            lines.append("Trip Sync Audit (selected vineyard)")
            if let at = audit.ranAt {
                lines.append("  ran_at: \(df.string(from: at))")
            }
            lines.append("  local_for_vineyard: \(audit.localForVineyard)")
            lines.append("  local_across_all_vineyards: \(audit.localAcrossAllVineyards)")
            lines.append("  remote_for_vineyard: \(audit.remoteForVineyard)")
            lines.append("  remote_soft_deleted: \(audit.remoteSoftDeleted)")
            lines.append("  remote_missing_name: \(audit.remoteMissingFunction)")
            lines.append("  pending_upserts: \(audit.pendingUpsertIds.count)")
            lines.append("  pending_deletes: \(audit.pendingDeleteIds.count)")
            lines.append("  local_vineyard_mismatch: \(audit.localVineyardMismatch.count)")
            lines.append("  local_only: \(audit.localOnlyIds.count)")
            for d in audit.localOnlyDetails {
                let label = d.function ?? d.title ?? "(no name)"
                let when = d.startTime.map { df.string(from: $0) } ?? "-"
                lines.append("    - LOCAL_ONLY \(d.id.uuidString) \"\(label)\" \(when)")
                if let p = d.paddockName, !p.isEmpty { lines.append("        paddocks: \(p)") }
                lines.append("        paddock_ids: [\(d.paddockIds.map { $0.uuidString }.joined(separator: ","))]")
                lines.append("        vineyard_id: \(d.localVineyardId.uuidString)")
                if d.inferredFromPaddocks, let inferred = d.inferredVineyardId, inferred != d.localVineyardId {
                    lines.append("        paddocks_resolve_to: \(inferred.uuidString)")
                }
            }
            for d in audit.orphanLocalDetails {
                let label = d.function ?? d.title ?? "(no name)"
                let when = d.startTime.map { df.string(from: $0) } ?? "-"
                lines.append("    - ORPHAN \(d.id.uuidString) \"\(label)\" \(when)")
                if let p = d.paddockName, !p.isEmpty { lines.append("        paddocks: \(p)") }
                lines.append("        paddock_ids: [\(d.paddockIds.map { $0.uuidString }.joined(separator: ","))]")
                lines.append("        vineyard_id: \(d.localVineyardId.uuidString)")
                if d.inferredFromPaddocks, let inferred = d.inferredVineyardId, inferred != d.localVineyardId {
                    lines.append("        paddocks_resolve_to: \(inferred.uuidString)")
                }
            }
            if let err = audit.error, !err.isEmpty {
                lines.append("  error: \(err)")
            }
            if !audit.localFunctionCounts.isEmpty || !audit.remoteFunctionCounts.isEmpty {
                lines.append("  trip_function_distribution:")
                let keys = orderedFunctionKeys(
                    local: audit.localFunctionCounts,
                    remote: audit.remoteFunctionCounts
                )
                lines.append("    local:")
                for key in keys {
                    let count = audit.localFunctionCounts[key] ?? 0
                    if count > 0 {
                        lines.append("      - \(functionDisplayName(key)): \(count)")
                    }
                }
                lines.append("    remote:")
                for key in keys {
                    let count = audit.remoteFunctionCounts[key] ?? 0
                    if count > 0 {
                        lines.append("      - \(functionDisplayName(key)): \(count)")
                    }
                }
                lines.append("    diff (local - remote):")
                for key in keys {
                    let l = audit.localFunctionCounts[key] ?? 0
                    let r = audit.remoteFunctionCounts[key] ?? 0
                    let diff = l - r
                    if diff != 0 {
                        let sign = diff > 0 ? "+" : ""
                        lines.append("      - \(functionDisplayName(key)): \(sign)\(diff)")
                    }
                }
            }
        }
        if let audit = lastPinSyncAudit {
            let df2 = df
            lines.append("")
            lines.append("Pin Sync Audit (selected vineyard)")
            if let at = audit.ranAt {
                lines.append("  ran_at: \(df2.string(from: at))")
            }
            lines.append("  local_for_vineyard: \(audit.localForVineyard)")
            lines.append("  local_across_all_vineyards: \(audit.localAcrossAllVineyards)")
            lines.append("  remote_for_vineyard: \(audit.remoteForVineyard)")
            lines.append("  remote_active: \(audit.remoteActive)")
            lines.append("  remote_soft_deleted: \(audit.remoteSoftDeleted)")
            lines.append("  local_only: \(audit.localOnlyIds.count)")
            lines.append("  remote_only: \(audit.remoteOnlyIds.count)")
            lines.append("  local_vineyard_mismatch: \(audit.localVineyardMismatch.count)")
            lines.append("  pending_upserts: \(audit.pendingUpsertIds.count)")
            lines.append("  pending_deletes: \(audit.pendingDeleteIds.count)")
            for d in audit.localOnlyDetails {
                let paddockIdStr = d.paddockId?.uuidString ?? "(none)"
                let paddockName = d.paddockName ?? "—"
                let createdByStr = d.createdBy ?? "—"
                let createdByUser = d.createdByUserId?.uuidString ?? "(none)"
                lines.append("    - LOCAL_ONLY \(d.id.uuidString) \"\(d.title)\" mode=\(d.mode) completed=\(d.isCompleted) created=\(df2.string(from: d.createdAt))")
                lines.append("        vineyard_id: \(d.localVineyardId.uuidString)")
                lines.append("        paddock_id: \(paddockIdStr)")
                lines.append("        paddock_name: \(paddockName)")
                lines.append("        created_by: \(createdByStr) user_id=\(createdByUser)")
                lines.append("        pending_upsert: \(d.isPendingUpsert) pending_delete: \(d.isPendingDelete)")
                if let code = d.growthStageCode, !code.isEmpty {
                    lines.append("        growth_stage_code: \(code)")
                }
            }
            for d in audit.orphanLocalDetails {
                lines.append("    - ORPHAN \(d.id.uuidString) \"\(d.title)\" mode=\(d.mode) vineyard=\(d.localVineyardId.uuidString)")
            }
            for d in audit.remoteSoftDeletedDetails {
                let when = d.deletedAt.map { df2.string(from: $0) } ?? "-"
                lines.append("    - SOFT_DELETED \(d.id.uuidString) \"\(d.title)\" deleted_at=\(when)")
            }
            if let err = audit.error, !err.isEmpty {
                lines.append("  error: \(err)")
            }
        }
        if auditService.lastResult.scanned > 0 || auditService.lastResult.ranAt != nil {
            lines.append("")
            lines.append(contentsOf: auditService.diagnosticsSnippet())
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Row

private struct EntityDiagnosticRow: View {
    let row: SyncDiagnosticsView.DiagnosticRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: row.icon)
                    .font(.callout)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                statusBadge
            }
            HStack(spacing: 14) {
                metric("Local", value: "\(row.localCount)")
                metric("Pending", value: "\(row.pendingUpserts)", highlight: row.pendingUpserts > 0)
                if row.pendingDeletes > 0 {
                    metric("Deletes", value: "\(row.pendingDeletes)", highlight: true)
                }
                Spacer()
            }
            HStack {
                Text("Last sync")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(lastSyncText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let err = row.errorMessage, !err.isEmpty, row.status == .failure {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func metric(_ label: String, value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(highlight ? Color.orange : .primary)
        }
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch row.status {
            case .idle:
                if row.pendingUpserts > 0 || row.pendingDeletes > 0 { return ("pending", .orange) }
                return ("idle", .secondary)
            case .syncing: return ("syncing", .blue)
            case .success:
                if row.pendingUpserts > 0 || row.pendingDeletes > 0 { return ("pending", .orange) }
                return ("synced", .green)
            case .failure: return ("failed", .red)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var lastSyncText: String {
        guard let date = row.lastSync else { return "never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

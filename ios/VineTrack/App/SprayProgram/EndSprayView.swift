import SwiftUI
import Supabase

/// Server-confirmed completion; never performs an editable full-record save.
struct EndSprayView: View {
    let recordId: UUID
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var access
    @State private var isBusy: Bool = false
    @State private var confirmation: Bool = false
    @State private var allowUnlinked: Bool = false
    @State private var message: String?
    @State private var showTrip: Bool = false

    private var record: SprayRecord? { store.sprayRecords.first { $0.id == recordId } }
    private var trip: Trip? { record.flatMap { record in store.trips.first { $0.id == record.canonicalTripId } } }

    var body: some View {
        if let record, !record.isTemplate, record.endTime == nil,
           record.entrySource != "manual", record.manualEntryId == nil, access.canEditRecords {
            Button("End Spray") {
                if trip?.isActive == true {
                    message = SprayCompletionFailure.message("ACTIVE_TRIP")
                } else {
                    Task { await prepare() }
                }
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
            .frame(maxWidth: .infinity)
            .alert("End Spray", isPresented: $confirmation) {
                Button("End Spray") { Task { await complete() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(allowUnlinked
                     ? "No linked Trip is available. Mark this spray complete now?"
                     : "The linked Trip has already finished. This will mark this spray as completed using the Trip completion time.")
            }
            .alert("End Spray", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                if message == SprayCompletionFailure.message("ACTIVE_TRIP") {
                    Button("Open Trip") { showTrip = true }
                }
                Button("OK", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
            .sheet(isPresented: $showTrip) { TripView() }
        }
    }

    private func prepare() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let server = try await SprayCompletionRepository().fetchRecord(id: recordId)
            guard server.entrySource != "manual", server.manualEntryId == nil else {
                message = SprayCompletionFailure.message("MANUAL_SPRAY_WORKFLOW_REQUIRED")
                return
            }
            if let local = record {
                store.applyRemoteSprayRecordUpsert(SprayCompletionResolver.preservingServerCompletion(local: local, server: server.toSprayRecord()))
            }
            if server.endTime != nil { return }
            allowUnlinked = server.tripId == nil
            if let linkedId = server.tripId {
                let linked: BackendTrip = try await SupabaseClientProvider.shared.client.from("trips")
                    .select().eq("id", value: linkedId.uuidString).single().execute().value
                guard linked.deletedAt == nil, linked.vineyardId == server.vineyardId else {
                    message = SprayCompletionFailure.message("LINKED_TRIP_UNAVAILABLE")
                    return
                }
                if linked.isActive == true { message = SprayCompletionFailure.message("ACTIVE_TRIP"); return }
                guard linked.endTime != nil else {
                    message = "The linked Trip has not finished. Open and end the Trip first."
                    return
                }
            }
            confirmation = true
        } catch { message = SprayCompletionFailure.message("") }
    }

    private func complete() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await SprayCompletionRepository().complete(id: recordId, allowUnlinked: allowUnlinked)
            if let local = record { store.applyRemoteSprayRecordUpsert(try response.applying(to: local)) }
        } catch {
            let code = (error as? PostgrestError)?.message ?? ""
            message = SprayCompletionFailure.message(code)
        }
    }
}

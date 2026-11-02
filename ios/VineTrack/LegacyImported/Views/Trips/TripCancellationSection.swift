import SwiftUI

/// P0 Phase A (Issue #40): Cancel Trip for a Trip ended on this device and still awaiting sync.
/// Behaviour matches Android `TripCancellationSection`; only the layout is iOS-native.
struct TripCancellationSection: View {
    let trip: Trip
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(NewBackendAuthService.self) private var auth
    @State private var showSheet = false

    private var service: TripActivityCancellationService { .shared }

    var body: some View {
        let intentResult = service.intent(for: trip.id)
        let pending = service.isLocalEndPending(trip, store: store)
        switch intentResult {
        case .failure:
            Section {
                statusLabel("Cancellation status unreadable", "exclamationmark.triangle.fill", .orange)
                Text("Saved evidence is retained and this Trip stays held. Code TRIP_CANCEL_EVIDENCE_UNREADABLE.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .success(let intent?) where intent.state != .REFUSED:
            Section { intentStatus(intent) }
        case .success(let intent):
            if pending {
                Section {
                    statusLabel("Ended on this device · awaiting sync", "icloud.and.arrow.up", VineyardTheme.olive)
                    Text("This Trip finished locally and its final stage has not reached the server yet.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let intent, let code = intent.lastCode {
                        Text("Previous cancellation was refused (\(code)). The Trip and its evidence are unchanged.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    cancelButton
                }
            }
        }
    }

    @ViewBuilder
    private var cancelButton: some View {
        let eligibility = service.eligibility(trip: trip, role: accessControl.tripCancellationRole,
                                              userId: auth.userId, store: store)
        Button(role: .destructive) { showSheet = true } label: {
            Label("Cancel Trip…", systemImage: "xmark.octagon")
        }
        .disabled(!eligibility.allowed || service.isWorking)
        .accessibilityIdentifier("trip.cancelActivity")
        .sheet(isPresented: $showSheet) {
            TripCancellationSheet(trip: trip, actualCount: service.localActualCount(tripId: trip.id),
                                  userId: auth.userId,
                                  sprayRecordIds: TankMixPresentation.linkedRecord(for: trip.id, in: store.sprayRecords).map { [$0.id] } ?? [])
        }
        if let code = eligibility.code {
            Text(Self.explain(code)).font(.caption).foregroundStyle(.secondary)
            Text(code).font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func intentStatus(_ intent: TripActivityCancellation.Intent) -> some View {
        switch intent.state {
        case .REQUESTED:
            statusLabel("Cancellation sent · confirming", "clock.arrow.circlepath", .orange)
            Text("Waiting for the server receipt. Nothing local is removed until it is verified. Operation \(intent.operationId.prefix(8))…")
                .font(.caption).foregroundStyle(.secondary)
            if let code = intent.lastCode { Text(code).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
            Button("Check now") { Task { await service.reconcileAll() } }.disabled(service.isWorking)
        case .ACKED:
            statusLabel("Cancelled · finishing local cleanup", "checkmark.seal", .orange)
            Text("The server receipt is verified. This Trip's local queues are being released.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Retry cleanup") { Task { await service.reconcileAll() } }.disabled(service.isWorking)
        case .CLEANED:
            statusLabel("Trip cancelled", "checkmark.seal.fill", .green)
            Text("Recorded as \(Self.classificationLabel(intent.classification)). Original evidence is kept on this device. You can start a new Trip.")
                .font(.caption).foregroundStyle(.secondary)
        case .RECEIPT_MISMATCH:
            statusLabel("Receipt did not match · held", "exclamationmark.triangle.fill", .red)
            Text("Nothing was removed. Copy this code for support: \(intent.lastCode ?? "TRIP_CANCEL_RECEIPT_MISMATCH")")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        case .REFUSED:
            EmptyView()
        }
    }

    private func statusLabel(_ text: String, _ icon: String, _ color: Color) -> some View {
        Label(text, systemImage: icon).font(.headline).foregroundStyle(color)
    }

    static func classificationLabel(_ wire: String) -> String {
        wire == TripActivityCancellation.Classification.applied.rawValue ? "spray applied" : "not applied"
    }

    static func explain(_ code: String) -> String {
        switch code {
        case "TRIP_CANCEL_AUTH_REQUIRED": return "Sign in to cancel this Trip."
        case "TRIP_CANCEL_FORBIDDEN": return "Only an Owner, Manager or Supervisor can cancel a Trip."
        case "TRIP_CANCEL_NOT_LOCAL_END_PENDING": return "Only a Trip ended on this device and awaiting sync can be cancelled."
        case "TRIP_CANCEL_NOT_DEVICE_CLAIM": return "This device has no record of ending this Trip. Cancel it from the original device."
        case "TRIP_CANCEL_CLAIM_OWNER_MISMATCH": return "This Trip was ended under a different account on this device."
        case "TRIP_CANCEL_CLAIM_VINEYARD_MISMATCH": return "This Trip was ended for a different vineyard."
        default: return "Cancellation is not available for this Trip."
        }
    }
}

private struct TripCancellationSheet: View {
    typealias Classification = TripActivityCancellation.Classification
    let trip: Trip
    let actualCount: Int
    let userId: UUID?
    let sprayRecordIds: [UUID]
    @Environment(\.dismiss) private var dismiss
    @State private var classification: Classification = .unknown
    @State private var confirmNotApplied = false
    @State private var resultMessage: String?
    @State private var resultIsError = false

    private var service: TripActivityCancellationService { .shared }

    private var canSubmit: Bool {
        guard userId != nil, !service.isWorking else { return false }
        switch classification {
        case .unknown: return false
        case .applied: return actualCount > 0
        case .notApplied: return actualCount == 0 || confirmNotApplied
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Was spray applied?", selection: $classification) {
                        Text("Not applied").tag(Classification.notApplied)
                        Text("Applied").tag(Classification.applied)
                        Text("Not sure").tag(Classification.unknown)
                    }
                    .pickerStyle(.segmented)
                    .sensoryFeedback(.selection, trigger: classification)
                } header: {
                    Text("Was spray applied on this Trip?")
                } footer: {
                    Text(footer)
                }
                if classification == .notApplied && actualCount > 0 {
                    Section {
                        Toggle("I confirm the \(actualCount) recorded tank \(actualCount == 1 ? "actual was" : "actuals were") not applied", isOn: $confirmNotApplied)
                    } footer: {
                        Text("Recorded amounts are kept exactly as entered in the saved evidence. They are never replaced with planned amounts.")
                    }
                }
                if let resultMessage {
                    Section {
                        Text(resultMessage).font(.subheadline)
                            .foregroundStyle(resultIsError ? .orange : .green)
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Button(role: .destructive) { submit() } label: {
                        HStack {
                            Spacer()
                            if service.isWorking { ProgressView() } else { Text("Cancel Trip").font(.headline) }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("trip.cancelActivity.confirm")
                }
            }
            .navigationTitle("Cancel Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep Trip") { dismiss() } }
            }
            .interactiveDismissDisabled(service.isWorking)
        }
        .presentationDetents([.medium, .large])
    }

    private var footer: String {
        switch classification {
        case .unknown: return "Not sure changes nothing. The Trip stays held with all its evidence until someone confirms."
        case .applied where actualCount == 0: return "Applied needs recorded tank actuals on this device. None are recorded."
        case .applied: return "The \(actualCount) recorded tank \(actualCount == 1 ? "actual is" : "actuals are") archived for compliance before the Trip is cancelled."
        case .notApplied: return "The Trip is cancelled on the server. Original evidence is saved on this device first."
        }
    }

    private func submit() {
        guard let userId else { return }
        let sprayIds = sprayRecordIds
        Task {
            let outcome = await service.cancel(trip: trip, classification: classification,
                                               confirmedNotApplied: confirmNotApplied, userId: userId,
                                               sprayRecordIds: sprayIds)
            switch outcome {
            case .acked(let cleaned):
                resultIsError = !cleaned
                resultMessage = cleaned ? "Trip cancelled. You can start a new Trip." :
                    "Cancelled on the server. Local cleanup will finish on the next sync."
                if cleaned { try? await Task.sleep(for: .seconds(1)); dismiss() }
            case .pending(let code):
                resultIsError = true
                resultMessage = "Sent, awaiting confirmation. Nothing local was removed. \(code ?? "")"
            case .refused(let code):
                resultIsError = true
                resultMessage = "Not cancelled. The Trip and its evidence are unchanged. \(code)"
            }
        }
    }
}

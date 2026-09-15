import Foundation
import Testing
@testable import VineTrack

/// Focused coverage for the two connected Spray Trip sync defects:
/// the invalid `carrier_volume_basis` payload and the Phase 5
/// trip-finalisation / tank-actual deadlock.
struct SprayCarrierBasisSyncContractTests {

    // MARK: - Carrier basis canonicalisation

    @Test("L/ha and L/100m pass through unchanged")
    func canonicalBasesPassThrough() {
        #expect(SprayCarrierBasisSyncContract.serverValue(for: .litresPerHectare) == "l_per_ha")
        #expect(SprayCarrierBasisSyncContract.serverValue(for: .litresPer100Metres) == "l_per_100m")
        #expect(SprayCarrierBasisSyncContract.outcome(for: .litresPerHectare).didConvert == false)
        #expect(SprayCarrierBasisSyncContract.outcome(for: .litresPer100Metres).didConvert == false)
    }

    @Test("Manual total volume becomes the canonical manual_actual_total")
    func manualBecomesCanonical() {
        // The local enum stores `manual`; the DB CHECK only accepts
        // `manual_actual_total`. This mapping is the root-cause fix.
        #expect(SprayCarrierBasis.manualTotalVolume.rawValue == "manual")
        #expect(SprayCarrierBasisSyncContract.serverValue(for: .manualTotalVolume) == "manual_actual_total")
        #expect(SprayCarrierBasisSyncContract.outcome(for: .manualTotalVolume).didConvert)
    }

    @Test("Every value the boundary emits satisfies the database contract")
    func everyEmittedValueIsAccepted() {
        for basis in SprayCarrierBasis.allCases {
            let value = SprayCarrierBasisSyncContract.serverValue(for: basis)
            #expect(value != nil, "\(basis.rawValue) must map to a server value")
            #expect(value.map { SprayCarrierBasisSyncContract.serverValues.contains($0) } == true)
        }
        // Absence stays absence — NULL is explicitly allowed by the contract.
        #expect(SprayCarrierBasisSyncContract.serverValue(for: nil) == nil)
        #expect(SprayCarrierBasisSyncContract.outcome(for: nil) == .absent)
    }

    @Test("Unknown values are never guessed into a carrier basis")
    func unknownValuesAreRejectedNotGuessed() {
        // Treated-area methods, application modes and chemical rate bases must
        // never leak into carrier basis — they are different columns entirely.
        for foreign in ["whole_block", "banded", "spreader", "per_100l", "per_hectare", "band_area", "treated_area"] {
            let outcome = SprayCarrierBasisSyncContract.canonicalise(foreign)
            #expect(outcome.isUnknown, "\(foreign) must not canonicalise")
            // Critically: not silently mapped to L/ha or L/100 m.
            #expect(outcome.serverValue == nil)
        }
    }

    @Test("Offline replay of a raw stored value uses the canonical form")
    func offlineReplayCanonicalises() {
        #expect(SprayCarrierBasisSyncContract.canonicalise("manual").serverValue == "manual_actual_total")
        #expect(SprayCarrierBasisSyncContract.canonicalise(" MANUAL ").serverValue == "manual_actual_total")
        #expect(SprayCarrierBasisSyncContract.canonicalise("manual_actual_total").serverValue == "manual_actual_total")
        #expect(SprayCarrierBasisSyncContract.canonicalise("manual_actual_total").didConvert == false)
        #expect(SprayCarrierBasisSyncContract.canonicalise(nil) == .absent)
        #expect(SprayCarrierBasisSyncContract.canonicalise("") == .absent)
    }

    @Test("Server values read back into the local enum, legacy included")
    func serverValuesRoundTrip() {
        #expect(SprayCarrierBasisSyncContract.basis(fromServerValue: "l_per_ha") == .litresPerHectare)
        #expect(SprayCarrierBasisSyncContract.basis(fromServerValue: "l_per_100m") == .litresPer100Metres)
        #expect(SprayCarrierBasisSyncContract.basis(fromServerValue: "manual_actual_total") == .manualTotalVolume)
        // The legacy on-device value still decodes rather than silently
        // dropping the basis of an already-persisted record.
        #expect(SprayCarrierBasisSyncContract.basis(fromServerValue: "manual") == .manualTotalVolume)
        #expect(SprayCarrierBasisSyncContract.basis(fromServerValue: "whole_block") == nil)
    }

    // MARK: - Payload built at the real sync boundary

    private func record(basis: SprayCarrierBasis?, mode: SprayApplicationMode?) -> SprayRecord {
        SprayRecord(
            id: UUID(uuidString: "5A000000-0000-4000-8000-000000000001")!,
            tripId: UUID(uuidString: "5A000000-0000-4000-8000-000000000002")!,
            vineyardId: UUID(uuidString: "00BB9A18-28DA-4BA7-9136-B2C5A1B56FB5")!,
            sprayReference: "Estellar",
            notes: "operator notes",
            applicationGeometry: SprayApplicationSnapshot(
                grossAreaHa: 4,
                treatedAreaHa: 4,
                applicationMode: mode,
                treatedAreaMethod: .wholeBlock,
                carrierVolumeBasis: basis,
                totalCarrierLitres: 900
            ),
            sprayJobId: UUID(uuidString: "5A000000-0000-4000-8000-000000000003")!
        )
    }

    @Test("Manual spray upsert no longer emits the rejected `manual` value")
    func upsertEmitsCanonicalManual() {
        let payload = BackendSprayRecord.upsert(
            from: record(basis: .manualTotalVolume, mode: .banded),
            createdBy: nil,
            clientUpdatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        #expect(payload.carrierVolumeBasis == "manual_actual_total")
        // Semantic separation: the treated-area method stays in its own column.
        #expect(payload.treatedAreaMethod == "whole_block")
        #expect(payload.applicationMode == SprayApplicationMode.banded.rawValue)
        #expect(payload.applicationMode != payload.carrierVolumeBasis)
    }

    @Test("Upsert preserves every identity while correcting the carrier basis")
    func upsertPreservesIdentities() {
        let original = record(basis: .manualTotalVolume, mode: .wholeBlock)
        let payload = BackendSprayRecord.upsert(
            from: original,
            createdBy: UUID(uuidString: "94238371-53C6-472D-975B-48BF98A268A9")!,
            clientUpdatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        #expect(payload.id == original.id)
        #expect(payload.tripId == original.tripId)
        #expect(payload.vineyardId == original.vineyardId)
        #expect(payload.sprayJobId == original.sprayJobId)
        #expect(payload.notes == original.notes)
        #expect(payload.totalCarrierLitres == 900)
        #expect(payload.treatedAreaHa == 4)
    }

    @Test("Banded L/100m spray is unaffected by the correction")
    func bandedPerHundredMetresUnaffected() {
        let payload = BackendSprayRecord.upsert(
            from: record(basis: .litresPer100Metres, mode: .banded),
            createdBy: nil,
            clientUpdatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        #expect(payload.carrierVolumeBasis == "l_per_100m")
    }

    // MARK: - Diagnostics

    @Test("Carrier diagnostic reports conversion without leaking content")
    func diagnosticReportsConversion() {
        let id = UUID(uuidString: "5A000000-0000-4000-8000-000000000001")!
        let converted = SprayCarrierSyncDiagnostic(sprayRecordId: id, basis: .manualTotalVolume, applicationMode: "banded")
        #expect(converted.didConvert)
        #expect(converted.wasRejected == false)
        #expect(converted.attemptedBasis == "manual")
        #expect(converted.canonicalBasis == "manual_actual_total")
        #expect(converted.isNoteworthy)
        #expect(converted.summary.contains("operator notes") == false)

        let clean = SprayCarrierSyncDiagnostic(sprayRecordId: id, basis: .litresPerHectare, applicationMode: "whole_block")
        #expect(clean.isNoteworthy == false)
        #expect(clean.canonicalBasis == "l_per_ha")
    }

    // MARK: - Phase 5 upload gate

    @Test("A trip whose parent row is missing legitimately blocks its actuals")
    func missingParentBlocksActual() {
        let decision = SprayTankActualUploadGate.decide(parentTripBlocked: true, sprayRecordPending: false)
        #expect(decision == .skipParentTripNotEstablished)
        #expect(decision.skipReason != nil)
    }

    @Test("A trip pending only for deferred finalisation does NOT block its actuals")
    func deferredFinalisationDoesNotBlockActual() {
        // This is the deadlock: the trip stayed queued waiting for actuals while
        // the actuals refused to upload because the trip was queued.
        #expect(SprayTankActualUploadGate.decide(parentTripBlocked: false, sprayRecordPending: false) == .upload)
    }

    @Test("A spray record not yet on the server still defers its actuals")
    func pendingSprayRecordBlocksActual() {
        #expect(
            SprayTankActualUploadGate.decide(parentTripBlocked: false, sprayRecordPending: true)
                == .skipSprayRecordNotEstablished
        )
    }

    // MARK: - Parent existence vs deferred finalisation

    @MainActor
    private func metadata() throws -> (TripSyncMetadata, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trip-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (TripSyncMetadata(persistence: PersistenceStore(directory: directory)), directory)
    }

    @MainActor
    @Test("Parent existence is tracked separately from the pending queue")
    func parentExistenceIsSeparateFromPendingQueue() throws {
        let (metadata, directory) = try metadata()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tripId = UUID(uuidString: "890D268F-EA69-4A98-B0FA-844362F55B76")!

        metadata.markDirty(tripId, at: Date())
        #expect(metadata.isParentEstablished(tripId) == false)

        // Parent uploaded; final ended state stays queued behind actual-use.
        metadata.markParentsEstablished([tripId])
        metadata.markDirty(tripId, at: Date())
        #expect(metadata.pendingUpserts[tripId] != nil)
        #expect(metadata.isParentEstablished(tripId))

        // Idempotent: repeating the marking changes nothing.
        metadata.markParentsEstablished([tripId])
        #expect(metadata.isParentEstablished(tripId))

        // Clearing the queue after finalisation leaves the parent established.
        metadata.clearDirty([tripId])
        #expect(metadata.pendingUpserts[tripId] == nil)
        #expect(metadata.isParentEstablished(tripId))
    }

    @MainActor
    @Test("Established parents survive a relaunch so queued actuals can recover")
    func establishedParentsSurviveRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trip-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tripId = UUID(uuidString: "C9CB8E43-201E-43F6-B50B-B92E9D2A66BC")!

        let first = TripSyncMetadata(persistence: PersistenceStore(directory: directory))
        first.markDirty(tripId, at: Date(timeIntervalSince1970: 1_780_000_000))
        first.markParentsEstablished([tripId])

        let relaunched = TripSyncMetadata(persistence: PersistenceStore(directory: directory))
        #expect(relaunched.isParentEstablished(tripId))
        // The queued finalisation is preserved, not lost, across the upgrade.
        #expect(relaunched.pendingUpserts[tripId] != nil)
        // Server-closed + local-pending: the actual may now upload.
        #expect(
            SprayTankActualUploadGate.decide(
                parentTripBlocked: relaunched.pendingUpserts[tripId] != nil && !relaunched.isParentEstablished(tripId),
                sprayRecordPending: false
            ) == .upload
        )
    }

    // MARK: - Ended trip payload

    private func endedTrip(id: UUID) -> Trip {
        Trip(
            id: id,
            vineyardId: UUID(uuidString: "00BB9A18-28DA-4BA7-9136-B2C5A1B56FB5")!,
            startTime: Date(timeIntervalSince1970: 1_779_990_000),
            endTime: Date(timeIntervalSince1970: 1_780_000_000),
            isActive: false
        )
    }

    @Test("A deferred ended trip uploads its true ended state, never active-with-end-time")
    func deferredEndedTripUploadsTrueState() {
        let id = UUID(uuidString: "C4DB2285-F69E-49DC-BD9F-521CF92CE207")!
        let trip = endedTrip(id: id)
        let payload = BackendTrip.upsert(from: trip, createdBy: nil, clientUpdatedAt: Date(timeIntervalSince1970: 1_780_000_100))

        // The old hold set isActive = true and endTime = nil; the nil was omitted
        // by the encoder, leaving is_active = true alongside a populated
        // server end_time. That combination must now be unreachable.
        #expect(payload.isActive == false)
        #expect(payload.endTime == trip.endTime)
        #expect(!(payload.isActive && payload.endTime != nil))
        #expect(payload.id == id)
        #expect(payload.startTime == trip.startTime)
    }

    @MainActor
    @Test("Once actuals clear, the hold releases and the trip finishes ended")
    func holdReleasesAndTripFinishesEnded() throws {
        let (metadata, directory) = try metadata()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID(uuidString: "890D268F-EA69-4A98-B0FA-844362F55B76")!
        let trip = endedTrip(id: id)

        // Parent exists on the server; finalisation is queued behind actuals.
        metadata.markParentsEstablished([id])
        metadata.markDirty(id, at: Date(timeIntervalSince1970: 1_780_000_050))
        #expect(metadata.isParentEstablished(id))

        // The actual is no longer blocked, so it uploads.
        #expect(SprayTankActualUploadGate.decide(parentTripBlocked: false, sprayRecordPending: false) == .upload)

        // Hold released: the final upload carries the real ended state.
        let payload = BackendTrip.upsert(from: trip, createdBy: nil, clientUpdatedAt: Date(timeIntervalSince1970: 1_780_000_200))
        #expect(payload.isActive == false)
        #expect(payload.endTime == trip.endTime)

        metadata.clearDirty([id])
        #expect(metadata.pendingUpserts[id] == nil)
        #expect(metadata.isParentEstablished(id))
    }

    @MainActor
    @Test("A deleted trip drops its established-parent claim")
    func deletedTripDropsParentClaim() throws {
        let (metadata, directory) = try metadata()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tripId = UUID(uuidString: "C4DB2285-F69E-49DC-BD9F-521CF92CE207")!
        metadata.markParentsEstablished([tripId])
        metadata.markDeleted(tripId, at: Date())
        #expect(metadata.isParentEstablished(tripId) == false)
    }
}

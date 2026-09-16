import Foundation
import CoreLocation

/// Drives a Scout E-L selection through the EXISTING production Growth Stage
/// workflow. This type deliberately owns no persistence of its own.
///
/// ## What it reuses, and why that matters
///
/// Every step below is the same code the Growth screen runs when an operator
/// records a stage from the tractor:
///
/// - `GrowthStagePickerSheet` — the enabled-stage catalogue, search and the
///   E-L confirmation image step.
/// - `LocationService.freshLocation()` — the strict fix validator.
/// - `PinContextResolver.resolve` — block and row resolution from the fix.
/// - `MigratedDataStore.createGrowthStagePin` — the canonical pin writer, which
///   persists durably and fires `onGrowthStagePinAdded`.
/// - `GrowthStageRecordSyncService.mirrorGrowthStagePin` — the canonical
///   `growth_stage_records` writer, reached through that hook.
/// - `PinSyncService` / `GrowthStageRecordSyncService` — the existing offline
///   outbox, retry and photo behaviour.
///
/// Scouting therefore adds no second phenology writer. The pin and the growth
/// record created here are indistinguishable from ones created on the Growth
/// screen, which is exactly the requirement: they must appear in the Growth
/// Stage list, the reports and the E-L heatmap, and be counted once.
///
/// ## The Scout only keeps a reference
///
/// On success the caller stores the canonical pin id, the canonical record id
/// and a label snapshot for report presentation. It never stores a competing
/// stage value — see `ScoutGrowthStageLink`.
@MainActor
struct ScoutGrowthStageCoordinator {

    let store: MigratedDataStore
    let locationService: LocationService
    let tracking: TripTrackingService?
    let growthStageRecordSync: GrowthStageRecordSyncService
    let auth: NewBackendAuthService

    /// What the canonical workflow produced, for the Scout to reference.
    nonisolated struct Capture: Equatable, Sendable {
        let pinID: UUID
        let growthStageRecordID: UUID
        let stageCode: String
        /// Label as it read on the day — presentation only.
        let stageLabel: String
    }

    nonisolated enum CaptureFailure: LocalizedError, Equatable, Sendable {
        case noQualifyingFix(LocationService.LocationQuality)
        case noVineyardSelected
        case pinNotCreated
        case recordNotMirrored

        var errorDescription: String? {
            switch self {
            case .noQualifyingFix(let quality):
                // The same honesty rule as pin capture: a stage observation is
                // positional evidence, so a stale or imprecise fix is refused
                // rather than quietly used. Never a centroid, never a
                // last-known position.
                switch quality {
                case .unavailable:
                    return "Waiting for GPS. The E-L stage will be recorded where you are standing, so it needs a live fix."
                case .stale:
                    return "The GPS position is out of date. Wait for a fresh fix, then choose the stage again."
                case .lowAccuracy:
                    return "GPS accuracy is not good enough yet. Wait for it to improve, then choose the stage again."
                case .fresh:
                    return nil
                }
            case .noVineyardSelected:
                return "Select a vineyard before recording a Growth Stage."
            case .pinNotCreated:
                return "This device could not save the Growth Stage pin. Try again."
            case .recordNotMirrored:
                return "The Growth Stage pin was saved but its record has not appeared yet. It will sync automatically."
            }
        }
    }

    /// Record a new E-L stage through the canonical pipeline.
    ///
    /// Exactly ONE pin and ONE growth record result, because both are produced
    /// by the production writers rather than here. If the pin is created but
    /// the mirror has not yet produced a record, that is reported as
    /// `.recordNotMirrored` rather than retried locally — the canonical service
    /// owns that reconciliation and will complete it.
    func capture(stage: GrowthStage, paddockID: UUID) -> Result<Capture, CaptureFailure> {
        guard store.selectedVineyardId != nil else { return .failure(.noVineyardSelected) }

        // The existing strict validator, not a bespoke one.
        let (location, quality) = locationService.freshLocation()
        guard let location, quality == .fresh else {
            return .failure(.noQualifyingFix(quality))
        }

        let resolved = PinContextResolver.resolve(
            coordinate: location.coordinate,
            store: store,
            tracking: tracking
        )

        // The canonical pin writer. Durable, and it fires the mirror hook.
        guard let pin = store.createGrowthStagePin(
            stageCode: stage.code,
            stageDescription: stage.description,
            coordinate: location.coordinate,
            heading: locationService.heading?.trueHeading,
            side: .right,
            // Prefer the block the scout is actually assessing; fall back to
            // geometric resolution only when it agrees there is none.
            paddockId: resolved.paddockId ?? paddockID,
            rowNumber: resolved.rowNumber,
            createdBy: auth.userName,
            createdByUserId: auth.userId,
            notes: nil
        ) else {
            return .failure(.pinNotCreated)
        }

        guard let record = growthStageRecordSync.records.first(where: { $0.pinId == pin.id }) else {
            return .failure(.recordNotMirrored)
        }

        return .success(
            Capture(
                pinID: pin.id,
                growthStageRecordID: record.id,
                stageCode: stage.code,
                stageLabel: stage.displayName
            )
        )
    }

    /// Change the stage on an already-linked observation.
    ///
    /// Routed through the canonical pin update plus
    /// `mirrorGrowthStagePin`, which updates the existing record in place when
    /// one already exists for the pin. An edit therefore never mints a second
    /// pin or a second growth record — the requirement that an offline retry or
    /// a corrected selection cannot duplicate phenology.
    func updateStage(
        pinID: UUID,
        stage: GrowthStage
    ) -> Result<Capture, CaptureFailure> {
        guard var pin = store.pins.first(where: { $0.id == pinID }) else {
            // The canonical pin is gone (deleted in the Growth workflow, where
            // it is allowed to be). Treat as a fresh capture decision by the
            // caller rather than silently recreating one here.
            return .failure(.pinNotCreated)
        }
        pin.growthStageCode = stage.code
        pin.notes = stage.description
        store.updatePin(pin)
        // Existing supported path: idempotent, updates the record keyed by pin.
        growthStageRecordSync.mirrorGrowthStagePin(pin)

        guard let record = growthStageRecordSync.records.first(where: { $0.pinId == pin.id }) else {
            return .failure(.recordNotMirrored)
        }
        return .success(
            Capture(
                pinID: pin.id,
                growthStageRecordID: record.id,
                stageCode: stage.code,
                stageLabel: stage.displayName
            )
        )
    }

    /// Resolve the current stage of a linked record for display on reopen.
    ///
    /// Read from the canonical record, never from a value cached on the scout
    /// observation — if someone corrects the stage in the Growth workflow, the
    /// Scout must show the corrected value rather than a stale copy.
    func linkedStage(recordID: UUID) -> (code: String, label: String)? {
        guard let record = growthStageRecordSync.records.first(where: { $0.id == recordID }) else {
            return nil
        }
        let label = GrowthStage.allStages.first { $0.code == record.stageCode }?.displayName
        return (record.stageCode, label ?? record.stageLabel ?? record.stageCode)
    }

    /// Attach a photograph to the canonical growth record, using the existing
    /// growth-photo behaviour rather than a Scout-specific one.
    ///
    /// This is the "existing pin-photo behaviour where applicable" requirement:
    /// a photo taken at the moment of the E-L capture belongs to the canonical
    /// observation, so it appears wherever that observation appears.
    func attachCanonicalPhoto(recordID: UUID, imageData: Data) throws {
        try growthStageRecordSync.attachPhoto(recordId: recordID, imageData: imageData)
    }
}

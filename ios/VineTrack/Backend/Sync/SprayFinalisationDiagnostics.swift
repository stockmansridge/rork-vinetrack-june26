import Foundation

/// Read-only observability for the Spray Trip finalisation lifecycle.
///
/// Pure value types with no store, network or SwiftUI dependency, so the
/// reason each trip is stuck is testable and identical to what the customer
/// copies out of Sync Diagnostics.
///
/// Content-free by construction: identifiers, counts and states only. No
/// notes, chemical names, litres, rates, tokens or payloads.
nonisolated enum SprayFinalisationDiagnostics {

    // MARK: - Trip finalisation

    nonisolated struct TripInput: Sendable, Equatable, Identifiable {
        var id: UUID { tripId }
        let tripId: UUID
        let sprayRecordId: UUID?
        let isActive: Bool
        let hasEndTime: Bool
        let tripPendingUpsert: Bool
        let parentEstablished: Bool
        let isPhase5Held: Bool
        let pendingActualCount: Int
        let sprayRecordPending: Bool

        init(
            tripId: UUID,
            sprayRecordId: UUID?,
            isActive: Bool,
            hasEndTime: Bool,
            tripPendingUpsert: Bool,
            parentEstablished: Bool,
            isPhase5Held: Bool,
            pendingActualCount: Int,
            sprayRecordPending: Bool
        ) {
            self.tripId = tripId
            self.sprayRecordId = sprayRecordId
            self.isActive = isActive
            self.hasEndTime = hasEndTime
            self.tripPendingUpsert = tripPendingUpsert
            self.parentEstablished = parentEstablished
            self.isPhase5Held = isPhase5Held
            self.pendingActualCount = pendingActualCount
            self.sprayRecordPending = sprayRecordPending
        }

        /// The one legitimate reason a child upload defers.
        var isPendingParentCreation: Bool { tripPendingUpsert && !parentEstablished }

        var status: SprayFinalisationStatus {
            SprayFinalisationStatus.resolve(
                isPendingParentCreation: isPendingParentCreation,
                sprayRecordPending: sprayRecordPending,
                pendingActualCount: pendingActualCount,
                tripPendingUpsert: tripPendingUpsert
            )
        }

        /// A record can be pending without being failed — that is exactly the
        /// production incident, so relevance never keys off failure counts.
        var isRelevant: Bool {
            tripPendingUpsert
                || isPhase5Held
                || pendingActualCount > 0
                || sprayRecordPending
                || (!isActive && hasEndTime && status != .fullySynced)
        }

        /// Copyable, operator-readable lines for one trip.
        var lines: [String] {
            var out: [String] = ["- trip_id: \(tripId.uuidString)"]
            out.append("  spray_record_id: \(sprayRecordId?.uuidString ?? "-")")
            out.append("  local_is_active: \(isActive)")
            out.append("  local_end_time: \(hasEndTime ? "present" : "absent")")
            out.append("  trip_pending_upsert: \(tripPendingUpsert)")
            out.append("  parent_established: \(parentEstablished)")
            out.append("  pending_parent_creation: \(isPendingParentCreation)")
            out.append("  phase5_held: \(isPhase5Held)")
            out.append("  pending_tank_actuals: \(pendingActualCount)")
            out.append("  spray_record_pending: \(sprayRecordPending)")
            out.append("  finalisation_status: \(status.rawValue)")
            if !isActive && hasEndTime && isActiveEndedConflictPossible {
                out.append("  note: locally ended and still queued")
            }
            return out
        }

        private var isActiveEndedConflictPossible: Bool { tripPendingUpsert }
    }

    /// Only the trips a support engineer needs, newest problems first.
    static func relevantTrips(_ inputs: [TripInput]) -> [TripInput] {
        inputs.filter(\.isRelevant)
    }

    // MARK: - Tank actuals

    nonisolated struct TankActualInput: Sendable, Equatable, Identifiable {
        var id: UUID { actualId }
        let actualId: UUID
        let tripId: UUID
        let sprayRecordId: UUID
        let tankNumber: Int
        let tankSessionId: String
        let isPending: Bool
        let parentTripBlocked: Bool
        let sprayRecordPending: Bool
        /// Set only when the sync layer actually classified a failure.
        let failureKind: SyncFailureKind?

        init(
            actualId: UUID,
            tripId: UUID,
            sprayRecordId: UUID,
            tankNumber: Int,
            tankSessionId: String,
            isPending: Bool,
            parentTripBlocked: Bool,
            sprayRecordPending: Bool,
            failureKind: SyncFailureKind? = nil
        ) {
            self.actualId = actualId
            self.tripId = tripId
            self.sprayRecordId = sprayRecordId
            self.tankNumber = tankNumber
            self.tankSessionId = tankSessionId
            self.isPending = isPending
            self.parentTripBlocked = parentTripBlocked
            self.sprayRecordPending = sprayRecordPending
            self.failureKind = failureKind
        }

        var decision: SprayTankActualUploadGate.Decision {
            SprayTankActualUploadGate.decide(
                parentTripBlocked: parentTripBlocked,
                sprayRecordPending: sprayRecordPending
            )
        }

        /// Distinguishes waiting-on-a-parent from a real upload failure.
        var skipReason: String {
            if let failureKind {
                switch failureKind {
                case .retryable: return "retryable_upload_failure"
                case .permanent: return "permanent_failure"
                }
            }
            switch decision {
            case .skipParentTripNotEstablished: return "trip_parent_not_established"
            case .skipSprayRecordNotEstablished: return "spray_record_still_pending"
            case .upload: return "ready_to_upload"
            }
        }

        var lines: [String] {
            [
                "- actual_id: \(actualId.uuidString)",
                "  trip_id: \(tripId.uuidString)",
                "  spray_record_id: \(sprayRecordId.uuidString)",
                "  tank_number: \(tankNumber)",
                "  tank_session_id: \(tankSessionId)",
                "  pending: \(isPending)",
                "  gate_decision: \(decision == .upload ? "upload" : "skip")",
                "  skip_reason: \(skipReason)"
            ]
        }
    }

    // MARK: - Carrier basis

    nonisolated struct CarrierBasisInput: Sendable, Equatable {
        let sprayRecordId: UUID
        let localBasisRaw: String?

        init(sprayRecordId: UUID, localBasisRaw: String?) {
            self.sprayRecordId = sprayRecordId
            self.localBasisRaw = localBasisRaw
        }

        var outcome: SprayCarrierBasisSyncContract.Outcome {
            SprayCarrierBasisSyncContract.canonicalise(localBasisRaw)
        }

        var isUnsupported: Bool { outcome.isUnknown }
        var didConvert: Bool { outcome.didConvert }

        var lines: [String] {
            var out: [String] = ["- spray_record_id: \(sprayRecordId.uuidString)"]
            out.append("  carrier_basis_local: \(localBasisRaw?.isEmpty == false ? (localBasisRaw ?? "-") : "<none>")")
            out.append("  carrier_basis_server: \(outcome.serverValue ?? "NULL")")
            out.append("  carrier_basis_conversion: \(didConvert ? "yes" : "no")")
            if isUnsupported {
                out.append("  carrier_basis_status: unsupported")
            }
            return out
        }
    }

    // MARK: - Summary

    nonisolated struct Summary: Sendable, Equatable {
        var tripsPending: Int = 0
        var tripsPhase5Held: Int = 0
        var tripsWaitingForParent: Int = 0
        var tripsReadyForFinalSync: Int = 0
        var tankActualsPending: Int = 0
        var sprayRecordsPending: Int = 0
        var carrierBasisConversions: Int = 0
        var carrierBasisUnsupported: Int = 0
        var failedItems: Int = 0
        var retryableFailures: Int = 0
        var permanentFailures: Int = 0

        var lines: [String] {
            [
                "  trips_pending: \(tripsPending)",
                "  trips_phase5_held: \(tripsPhase5Held)",
                "  trips_waiting_for_parent_creation: \(tripsWaitingForParent)",
                "  trips_ready_for_final_sync: \(tripsReadyForFinalSync)",
                "  tank_actuals_pending: \(tankActualsPending)",
                "  spray_records_pending: \(sprayRecordsPending)",
                "  spray_records_carrier_conversion: \(carrierBasisConversions)",
                "  spray_records_carrier_unsupported: \(carrierBasisUnsupported)",
                "  failed_items: \(failedItems)",
                "  retryable_failures: \(retryableFailures)",
                "  permanent_failures: \(permanentFailures)"
            ]
        }
    }

    static func summary(
        trips: [TripInput],
        actuals: [TankActualInput],
        carriers: [CarrierBasisInput],
        sprayRecordsPending: Int,
        retryableFailures: Int,
        permanentFailures: Int
    ) -> Summary {
        var summary = Summary()
        summary.tripsPending = trips.filter(\.tripPendingUpsert).count
        summary.tripsPhase5Held = trips.filter(\.isPhase5Held).count
        summary.tripsWaitingForParent = trips.filter(\.isPendingParentCreation).count
        summary.tripsReadyForFinalSync = trips.filter { $0.status == .readyForFinalTripSync }.count
        summary.tankActualsPending = actuals.filter(\.isPending).count
        summary.sprayRecordsPending = sprayRecordsPending
        summary.carrierBasisConversions = carriers.filter(\.didConvert).count
        summary.carrierBasisUnsupported = carriers.filter(\.isUnsupported).count
        summary.retryableFailures = retryableFailures
        summary.permanentFailures = permanentFailures
        summary.failedItems = retryableFailures + permanentFailures
        return summary
    }

    /// The complete copyable block appended to the support diagnostic.
    static func report(
        trips: [TripInput],
        actuals: [TankActualInput],
        carriers: [CarrierBasisInput],
        summary: Summary
    ) -> [String] {
        var lines: [String] = ["Spray Finalisation"]
        lines.append(contentsOf: summary.lines)

        let relevant = relevantTrips(trips)
        lines.append("  trips:")
        if relevant.isEmpty {
            lines.append("    (none pending)")
        } else {
            for trip in relevant { lines.append(contentsOf: trip.lines.map { "    \($0)" }) }
        }

        let pendingActuals = actuals.filter(\.isPending)
        lines.append("  tank_actuals_pending_detail:")
        if pendingActuals.isEmpty {
            lines.append("    (none pending)")
        } else {
            for actual in pendingActuals { lines.append(contentsOf: actual.lines.map { "    \($0)" }) }
        }

        let noteworthy = carriers.filter { $0.didConvert || $0.isUnsupported }
        lines.append("  carrier_basis (pending spray records):")
        if carriers.isEmpty {
            lines.append("    (none pending)")
        } else {
            // Unsupported/converted first — that is what recurrence looks like.
            for carrier in noteworthy + carriers.filter({ !$0.didConvert && !$0.isUnsupported }) {
                lines.append(contentsOf: carrier.lines.map { "    \($0)" })
            }
        }
        return lines
    }
}

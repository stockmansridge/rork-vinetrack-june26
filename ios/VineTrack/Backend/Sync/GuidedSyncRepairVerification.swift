import Foundation
import Supabase

/// Independent receipt inspection after each correction or full ordered sync.
/// This NEVER clears an upload queue. The existing Trip, Actual Use, Spray and
/// cancellation services remain the only writers of their durable ACKs.
@MainActor
enum GuidedSyncRepairVerification {
    struct Result: Sendable {
        let verified: Bool
        let code: String
        let explanation: String
        let evidence: [String]
    }
    private static func held(_ code: String, _ message: String, _ evidence: [String] = []) -> Result {
        Result(verified: false, code: code, explanation: message, evidence: evidence)
    }

    static func inspect(
        issue: GuidedSyncRepairIssue, vineyard: UUID, owner: UUID,
        store: MigratedDataStore, tripSync: TripSyncService,
        spraySync: SprayRecordSyncService
    ) async -> Result {
        guard store.selectedVineyardId == vineyard,
              store.currentUserIdProvider?() == owner,
              SupabaseClientProvider.shared.client.auth.currentUser?.id == owner,
              (issue.verifiedCurrentScope || issue.kind == .protectedQueue) else {
            return held("SCOPE_UNVERIFIED", "The original account/vineyard is not verified. No receipt was assumed.")
        }
        switch issue.kind {
        case .tripUpload:
            guard let trip = store.trips.first(where: { $0.id == issue.recordId && $0.vineyardId == vineyard })
            else { return held("TRIP_LOCAL_EVIDENCE_UNAVAILABLE", "The original local Trip is not loaded. Preserve and review its archive.") }
            do {
                let server = try await SupabaseTripSyncRepository().fetchTripForOccurrenceStart(
                    tripId: trip.id, vineyardId: vineyard)
                guard store.selectedVineyardId == vineyard,
                      store.currentUserIdProvider?() == owner else {
                    return held("SCOPE_CHANGED", "Account or vineyard changed during verification.")
                }
                guard let server, server.deletedAt == nil else {
                    return held("TRIP_DELETED_OR_NOT_VISIBLE",
                        "The original Trip is deleted or not visible. It cannot be re-finalised.")
                }
                guard !tripSync.isPendingUpsert(trip.id) else {
                    return held("TRIP_UPLOAD_PENDING", "The original Trip upload/finalisation remains queued.",
                        ["server_end_set:\(server.endTime != nil)", "server_active:\(server.isActive == true)"])
                }
                let (input, result) = await TripActivityCancellationService.shared.verifyClosure(
                    trip: trip, store: store)
                guard store.selectedVineyardId == vineyard,
                      store.currentUserIdProvider?() == owner else {
                    return held("SCOPE_CHANGED", "Account or vineyard changed during verification.")
                }
                guard result.isClosedSynced else {
                    return held(result.state.rawValue,
                        "The original Trip has not passed independent closure checks.",
                        result.reasons)
                }
                // A clean local queue alone cannot prove every original
                // Actual Use is present. Confirm all original IDs and contents
                // again through the authenticated server endpoint.
                for actual in SprayTankActualStore.shared.records where
                    actual.tripId == trip.id && actual.vineyardId == vineyard {
                    guard !SprayTankActualStore.shared.pendingIds.contains(actual.id),
                          let remote = try await SprayTankActualStore.shared.actualReader(actual),
                          TankDependencyVerification.actualMatches(local: actual, server: remote)
                    else {
                        return held("ACTUAL_USE_READBACK_MISMATCH",
                            "One original Actual Use amount or identity still lacks an exact server receipt.")
                    }
                }
                return Result(verified: true, code: "CLOSED_SYNCED",
                    explanation: "Original Trip End, tank sessions, Actual Use and linked Spray completion passed independent server checks.",
                    evidence: [result.state.rawValue,
                               "original_trip:\(trip.id.uuidString.lowercased())",
                               "server_sessions:\(input.serverSessionIds?.count ?? 0)"])
            } catch {
                return held("TRIP_VERIFICATION_READ_FAILED",
                    "The exact Trip or linked record could not be independently read. Nothing was acknowledged.")
            }

        case .tankActual:
            guard let actual = SprayTankActualStore.shared.records.first(where: {
                $0.id == issue.recordId && $0.vineyardId == vineyard
            }) else {
                return held("ORIGINAL_ACTUAL_NOT_IN_LOCAL_STORE", "The original Actual Use is no longer in the current local records.")
            }
            guard !SprayTankActualStore.shared.pendingIds.contains(actual.id) else {
                return held("ACTUAL_USE_STILL_QUEUED", "The original Actual Use is still queued; verify its tank session and parent Trip.")
            }
            do {
                let row = try await SupabaseTripSyncRepository()
                    .fetchTripForOccurrenceStart(tripId: actual.tripId, vineyardId: vineyard)
                guard let row, row.deletedAt == nil,
                      TankDependencyVerification.ids(row.tankSessions ?? [])
                        .contains(TankDependencyVerification.normalized(actual.tankSessionId)),
                      let remote = try await SprayTankActualStore.shared.actualReader(actual),
                      GuidedRepairFieldValidation.immutableIdentityMatches(actual, remote),
                      TankDependencyVerification.actualMatches(local: actual, server: remote),
                      store.selectedVineyardId == vineyard, store.currentUserIdProvider?() == owner
                else {
                    return held("TANK_ACTUAL_SERVER_RECEIPT_MISSING",
                        "The exact original Actual Use, amount or parent tank-session receipt is unverified.")
                }
                return Result(verified: true, code: "ACTUAL_USE_VERIFIED",
                    explanation: "Exact original Actual Use ID, quantities and tank session independently match the server.",
                    evidence: ["actual_id:\(actual.id.uuidString.lowercased())",
                               "tank_session:\(TankDependencyVerification.normalized(actual.tankSessionId))"])
            } catch {
                return held("TANK_ACTUAL_READ_FAILED", "The server Actual Use could not be inspected; pending evidence is retained.")
            }

        case .sprayRecord:
            guard let original = store.sprayRecords.first(where: { $0.id == issue.recordId && $0.vineyardId == vineyard })
            else { return held("SPRAY_LOCAL_SNAPSHOT_UNAVAILABLE", "Original Spray Record snapshot not loaded.") }
            guard !spraySync.isPendingUpsert(original.id),
                  !spraySync.isPendingDelete(original.id) else {
                return held("SPRAY_QUEUE_PENDING", "The original Spray Record still has an unacknowledged operation.")
            }
            do {
                let server = try await SprayCompletionRepository().fetchRecord(id: original.id)
                guard server.id == original.id && server.vineyardId == vineyard,
                      store.selectedVineyardId == vineyard,
                      store.currentUserIdProvider?() == owner else {
                    return held("SPRAY_SCOPE_MISMATCH", "The Spray Record readback did not match the original selected-vineyard ID.")
                }
                if spraySync.isPendingDelete(original.id) {
                    return held("SPRAY_DELETE_PENDING", "Spray deletion is still awaiting acknowledgement.")
                }
                if let tripId = original.canonicalTripId,
                   let parent = store.trips.first(where: { $0.id == tripId && $0.vineyardId == vineyard }) {
                    if let tripEnd = parent.endTime {
                        guard server.deletedAt == nil,
                              server.tripId == tripId,
                              server.endTime == tripEnd else {
                            return held("LINKED_SPRAY_END_NOT_VERIFIED", "The linked Spray End does not match the original finished Trip.")
                        }
                    } else if server.deletedAt != nil {
                        return held("SPRAY_SERVER_DELETED", "The remote Spray was deleted. Its original state must be reviewed.")
                    }
                } else if server.deletedAt != nil {
                    return held("SPRAY_SERVER_DELETED", "The remote Spray is deleted; it is not an accepted live upload.")
                }
                return Result(verified: true, code: "SPRAY_RECORD_VERIFIED",
                    explanation: "Exact Spray Record identity and required Trip End link verified on the server.",
                    evidence: ["spray_id:\(server.id.uuidString.lowercased())"])
            } catch {
                return held("SPRAY_READ_FAILED", "The original Spray Record could not be independently inspected.")
            }

        case .trackedSprayCompletion:
            guard let tripId = issue.relatedTripId,
                  let parent = store.trips.first(where: {
                      $0.id == tripId && $0.vineyardId == vineyard
                  }), let end = parent.endTime, !parent.isActive else {
                return held("ORIGINAL_END_UNAVAILABLE",
                            "A linked Spray End requires the original locally recorded ended Trip.")
            }
            do {
                guard try TrackedSprayCompletionSync.shared.hasAcknowledgedCompletion(
                    tripId: tripId, sprayRecordId: issue.recordId,
                    ownerId: owner, vineyardId: vineyard) else {
                    return held("TRACKED_SPRAY_END_PENDING",
                                "The original linked Spray completion has not received its durable acknowledgement.")
                }
                let remoteTrip = try await SupabaseTripSyncRepository()
                    .fetchTripForOccurrenceStart(tripId: tripId, vineyardId: vineyard)
                let spray = try await SprayCompletionRepository().fetchRecord(id: issue.recordId)
                guard let remoteTrip, remoteTrip.deletedAt == nil,
                      remoteTrip.id == tripId, remoteTrip.endTime == end,
                      remoteTrip.isActive == false,
                      spray.id == issue.recordId, spray.vineyardId == vineyard,
                      spray.deletedAt == nil, spray.tripId == tripId,
                      spray.endTime == end,
                      store.selectedVineyardId == vineyard,
                      store.currentUserIdProvider?() == owner else {
                    return held("LINKED_SPRAY_END_READBACK_MISMATCH",
                                "The original Trip End or linked Spray completion does not match the server.")
                }
                return Result(verified: true, code: "LINKED_SPRAY_COMPLETED",
                    explanation: "Original Trip End, linked Spray End and durable completion receipt all match.",
                    evidence: ["trip_id:\(tripId.uuidString.lowercased())",
                               "spray_id:\(issue.recordId.uuidString.lowercased())"])
            } catch {
                return held("LINKED_SPRAY_READBACK_FAILED",
                            "Original tracked Spray completion receipt could not be independently checked.")
            }

        case .initialMixDraft:
            guard let tripId = issue.relatedTripId else {
                return held("ORIGINAL_MIX_TRIP_UNKNOWN",
                            "The first-tank mix is not associated with a verified original Trip.")
            }
            let actualStore = SprayTankActualStore.shared
            guard !actualStore.initialMixDrafts.contains(where: {
                $0.tripId == tripId && $0.vineyardId == vineyard
            }) else {
                return held("ORIGINAL_FIRST_TANK_HANDOFF_PENDING",
                            "The original first-tank confirmation handoff is still retained, waiting for an exact recorded session and Actual Use.")
            }
            let actuals = actualStore.records.filter {
                $0.tripId == tripId && $0.sprayRecordId == issue.recordId &&
                $0.vineyardId == vineyard
            }
            guard !actuals.isEmpty else {
                return held("ORIGINAL_FIRST_TANK_ACTUAL_MISSING",
                            "The first-tank confirmation cannot be verified without its original recorded Actual Use.")
            }
            do {
                guard let row = try await SupabaseTripSyncRepository()
                    .fetchTripForOccurrenceStart(tripId: tripId, vineyardId: vineyard),
                      row.deletedAt == nil else {
                    return held("ORIGINAL_FIRST_TANK_PARENT_UNVERIFIED",
                                "The original first-tank parent Trip is absent or deleted on the server.")
                }
                let serverSessions = TankDependencyVerification.ids(row.tankSessions ?? [])
                for actual in actuals {
                    guard !actualStore.pendingIds.contains(actual.id),
                          serverSessions.contains(TankDependencyVerification.normalized(actual.tankSessionId)),
                          let server = try await actualStore.actualReader(actual),
                          TankDependencyVerification.actualMatches(local: actual, server: server)
                    else {
                        return held("ORIGINAL_FIRST_TANK_RECEIPT_UNVERIFIED",
                            "The original first-tank session or actual amounts do not match server evidence.")
                    }
                }
                return Result(verified: true, code: "FIRST_TANK_CONFIRMED",
                    explanation: "The original first-tank handoff is retired and its tank/Actual Use receipts independently match.",
                    evidence: ["trip_id:\(tripId.uuidString.lowercased())"])
            } catch {
                return held("FIRST_TANK_READBACK_FAILED",
                            "First-tank records were not independently read; original evidence remains protected.")
            }

        case .tripDeletion:
            guard let tripId = issue.relatedTripId else {
                return held("DELETE_SCOPE_UNVERIFIED", "The original deletion must be attributed to a specific Trip and vineyard.")
            }
            do {
                let remote = try await SupabaseTripSyncRepository()
                    .fetchTripForOccurrenceStart(tripId: tripId, vineyardId: vineyard)
                // A Trip the server never accepted has no tombstone to find.
                // The owner-reviewed retire records the server absence on the
                // original, scoped deletion intent; accept that receipt only
                // while the server still shows no row and nothing is queued.
                if remote == nil,
                   let intent = try store.tripDeletionJournal.load().intents[tripId],
                   intent.scope?.account == owner, intent.scope?.vineyard == vineyard,
                   intent.scope?.trip == tripId,
                   intent.acknowledgement?.hasPrefix("REVIEWED_SERVER_ABSENCE_VERIFIED:") == true {
                    guard !tripSync.isPendingUpsert(tripId) && !tripSync.isPendingDelete(tripId) &&
                          SprayTankActualStore.shared.pendingCount(tripId: tripId) == 0 &&
                          !store.sprayRecords.contains(where: {
                              $0.vineyardId == vineyard && $0.canonicalTripId == tripId &&
                              (spraySync.isPendingUpsert($0.id) || spraySync.isPendingDelete($0.id))
                          }) else {
                        return held("NEVER_CREATED_DEPENDENTS_PENDING",
                            "The server never had this Trip, but linked local queues are still waiting.")
                    }
                    return Result(verified: true, code: "NEVER_CREATED_RETIRE_VERIFIED",
                        explanation: "The server has no copy of this Trip, the reviewed retire is recorded on the original deletion, and nothing linked is still queued.",
                        evidence: ["trip_id:\(tripId.uuidString.lowercased())",
                                   "verified_source:reviewed_server_absence"])
                }
                guard let remote, remote.id == tripId, remote.vineyardId == vineyard,
                      remote.deletedAt != nil else {
                    return held("DELETE_TOMBSTONE_NOT_VERIFIED",
                        "An original, authenticated server deletion receipt is required; this Trip will not be recreated.")
                }
                let journal = try store.tripDeletionJournal.load()
                let oldAck = journal.intents[tripId].flatMap {
                    $0.scope?.account == owner && $0.scope?.vineyard == vineyard
                        ? $0.acknowledgement : nil
                }
                let cancellation = try TripCancellationIntentStore.shared.find(
                    tripId: tripId.uuidString.lowercased())
                let newAck = cancellation.map {
                    $0.ownerId == owner.uuidString.lowercased() &&
                    $0.vineyardId == vineyard.uuidString.lowercased() &&
                    ($0.state == .ACKED || $0.state == .CLEANED)
                } ?? false
                let reviewedArchiveAck = (try? GuidedRepairAuditLedger.shared.history(
                    account: owner, vineyard: vineyard, record: tripId))?.contains(where: {
                    $0.stages.contains(where: { $0.code == "SERVER_CANCEL_RECEIPT_AND_ARCHIVE_VERIFIED" }) &&
                    GuidedLegacyDeletedTripRepair.archiveConfirmed(
                        operationId: $0.id, tripId: tripId,
                        vineyard: vineyard, owner: owner)
                }) ?? false
                guard oldAck != nil || newAck || reviewedArchiveAck else {
                    return held("CANCEL_ORIGINAL_ACK_UNAVAILABLE",
                        "Server tombstone exists, but the original cancellation journal has no durable acknowledgement.")
                }
                guard !tripSync.isPendingUpsert(tripId) && !tripSync.isPendingDelete(tripId) &&
                      SprayTankActualStore.shared.pendingCount(tripId: tripId) == 0 &&
                      !store.sprayRecords.contains(where: {
                          $0.vineyardId == vineyard && $0.canonicalTripId == tripId &&
                          (spraySync.isPendingUpsert($0.id) || spraySync.isPendingDelete($0.id))
                      }) else {
                    return held("CANCEL_DEPENDENTS_PENDING",
                        "The server Trip is deleted but linked local records are still queued. Verify cannot clear them: choose \"Reconcile deleted Trip and linked records\" instead.")
                }
                return Result(verified: true, code: "CANCELLATION_VERIFIED",
                    explanation: "The original server tombstone, cancellation receipt and linked local queues have been checked.",
                    evidence: ["trip_id:\(tripId.uuidString.lowercased())",
                               oldAck != nil ? "verified_source:trip_deletion_journal"
                                   : (newAck ? "verified_source:trip_activity_cancellation_receipt"
                                             : "verified_source:reviewed_legacy_deletion_receipt")])
            } catch {
                return held("DELETION_READ_FAILED", "Deletion evidence was unavailable; no old queue records were retired.")
            }

        case .protectedQueue:
            // An unidentified legacy queue may ONLY be retired after an
            // operator-reviewed server tombstone, server-owned cancellation
            // receipt and exact original local archive. The current vineyard
            // selection alone does not establish any upload authority.
            do {
                let history = try GuidedRepairAuditLedger.shared.history(
                    account: owner, vineyard: vineyard, record: issue.recordId)
                guard let reviewed = history.first(where: { entry in
                    entry.stages.contains(where: { $0.code == "SERVER_CANCEL_RECEIPT_AND_ARCHIVE_VERIFIED" })
                }), GuidedLegacyDeletedTripRepair.archiveConfirmed(
                    operationId: reviewed.id, tripId: issue.recordId,
                    vineyard: vineyard, owner: owner) else {
                    return held("ORIGINAL_SCOPE_UNATTRIBUTED",
                        "This original Trip has no reviewed cancellation receipt and source archive. It remains protected.")
                }
                let trip = try await SupabaseTripSyncRepository()
                    .fetchTripForOccurrenceStart(
                        tripId: issue.recordId, vineyardId: vineyard)
                let receipt = try await SupabaseTripCancellationRemote()
                    .readReceipt(tripId: issue.recordId.uuidString.lowercased(),
                                 vineyardId: vineyard.uuidString.lowercased())
                let sprays = try await SprayCompletionRepository()
                    .fetchLinked(tripId: issue.recordId)
                struct Row: Decodable { let id: UUID }
                let actuals: [Row] = try await SupabaseClientProvider.shared.client
                    .from("spray_tank_actuals").select("id")
                    .eq("trip_id", value: issue.recordId.uuidString)
                    .eq("vineyard_id", value: vineyard.uuidString)
                    .is("deleted_at", value: nil).limit(1).execute().value
                guard let trip, trip.deletedAt != nil, trip.vineyardId == vineyard,
                      let receipt,
                      TripActivityCancellation.string(receipt, "operation_id") == reviewed.id.uuidString.lowercased(),
                      TripActivityCancellation.string(receipt, "trip_id") == issue.recordId.uuidString.lowercased(),
                      TripActivityCancellation.string(receipt, "vineyard_id") == vineyard.uuidString.lowercased(),
                      TripActivityCancellation.string(receipt, "status") == "CANCELLED_ACKED",
                      sprays.isEmpty, actuals.isEmpty,
                      !tripSync.isPendingUpsert(issue.recordId),
                      !tripSync.isPendingDelete(issue.recordId),
                      SprayTankActualStore.shared.pendingCount(tripId: issue.recordId) == 0,
                      store.selectedVineyardId == vineyard,
                      store.currentUserIdProvider?() == owner else {
                    return held("REVIEWED_CANCELLATION_DEPENDENTS_PENDING",
                        "The original server tombstone, linked records or queued local operations are not fully reconciled.")
                }
                return Result(verified: true, code: "REVIEWED_LEGACY_CANCELLATION_VERIFIED",
                    explanation: "Original Trip remains deleted; its linked records and historical queue are reconciled under an audited cancellation receipt.",
                    evidence: ["operation_id:\(reviewed.id.uuidString.lowercased())",
                               "trip_id:\(issue.recordId.uuidString.lowercased())"])
            } catch {
                return held("REVIEWED_CANCELLATION_READ_FAILED",
                    "The original cancellation evidence could not be independently read. Do not clear its queue.")
            }

        case .other:
            return held("GENERIC_RECEIPT_UNVERIFIED",
                "This entity lacks an exact registered readback contract in the repair tool. The normal sync can retry it, but it cannot be marked resolved without a record-specific receipt.")
        }
    }
}

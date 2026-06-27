import Foundation
import Observation

/// Admin-level audit/repair tool that scans every trip the current user can
/// see across all of their accessible vineyards (not just the currently
/// selected vineyard). Categorises problems, auto-repairs unambiguous cases,
/// and supports a manual reassignment flow for trips that need a human call.
///
/// Read-only against Supabase apart from explicit repair pushes triggered
/// from the UI. RLS on `trips`/`paddocks`/`vineyards` gates everything that
/// is fetched here.
@Observable
@MainActor
final class TripAuditService {

    enum Status: Equatable, Sendable {
        case idle
        case scanning
        case repairing
        case finished
        case failed(String)
    }

    enum ProblemCategory: String, Sendable, CaseIterable {
        case nullVineyard
        case unknownVineyard
        case deletedVineyard
        case scalarPaddockMismatch
        case paddockIdsMismatch
        case nameOnlyPaddock
        case unsafe

        var label: String {
            switch self {
            case .nullVineyard: return "Null vineyard_id"
            case .unknownVineyard: return "Unknown / bogus vineyard"
            case .deletedVineyard: return "Deleted vineyard"
            case .scalarPaddockMismatch: return "Block id in another vineyard"
            case .paddockIdsMismatch: return "Block ids in another vineyard"
            case .nameOnlyPaddock: return "Block name only, no reliable id"
            case .unsafe: return "Cannot safely repair"
            }
        }
    }

    struct AuditTrip: Identifiable, Sendable {
        let id: UUID
        var startTime: Date?
        var endTime: Date?
        var paddockId: UUID?
        var paddockIds: [UUID]
        var paddockName: String?
        var trackingPattern: String?
        var personName: String?
        var currentVineyardId: UUID?
        var currentVineyardName: String?
        var currentVineyardDeleted: Bool
        var inferredVineyardId: UUID?
        var inferredVineyardName: String?
        var problems: [ProblemCategory]
        var canAutoRepair: Bool
        var autoRepaired: Bool
        var manuallyRepaired: Bool
        var lastError: String?
    }

    struct AuditResult: Sendable {
        var scanned: Int = 0
        var alreadyCorrect: Int = 0
        var autoRepaired: Int = 0
        var needingReview: Int = 0
        var deletedVineyard: Int = 0
        var skipped: Int = 0
        var pushFailures: Int = 0
        var ranAt: Date?

        var counts: [ProblemCategory: Int] = [:]
    }

    var status: Status = .idle
    var lastResult: AuditResult = AuditResult()
    var trips: [AuditTrip] = []
    var vineyards: [BackendVineyard] = []
    var errorMessage: String?

    private let tripRepo: any TripSyncRepositoryProtocol
    private let paddockRepo: any PaddockSyncRepositoryProtocol
    private let vineyardRepo: any VineyardRepositoryProtocol

    init(
        tripRepo: (any TripSyncRepositoryProtocol)? = nil,
        paddockRepo: (any PaddockSyncRepositoryProtocol)? = nil,
        vineyardRepo: (any VineyardRepositoryProtocol)? = nil
    ) {
        self.tripRepo = tripRepo ?? SupabaseTripSyncRepository()
        self.paddockRepo = paddockRepo ?? SupabasePaddockSyncRepository()
        self.vineyardRepo = vineyardRepo ?? SupabaseVineyardRepository()
    }

    /// Convenience: only show problem trips in the UI.
    var problemTrips: [AuditTrip] {
        trips.filter { !$0.problems.isEmpty }
    }

    var nonDeletedVineyards: [BackendVineyard] {
        vineyards.filter { $0.deletedAt == nil }
    }

    func vineyard(for id: UUID?) -> BackendVineyard? {
        guard let id else { return nil }
        return vineyards.first { $0.id == id }
    }

    // MARK: - Scan

    func scan(autoRepair: Bool) async {
        guard status != .scanning, status != .repairing else { return }
        status = .scanning
        errorMessage = nil

        do {
            async let vRequest = vineyardRepo.listAllAccessibleVineyards(includeDeleted: true)
            async let pRequest = paddockRepo.fetchAllAccessiblePaddocks()
            async let tRequest = tripRepo.fetchAllAccessibleTrips()

            let fetchedVineyards = try await vRequest
            let fetchedPaddocks = try await pRequest
            let fetchedTrips = try await tRequest

            self.vineyards = fetchedVineyards

            let vineyardById = Dictionary(uniqueKeysWithValues: fetchedVineyards.map { ($0.id, $0) })
            let paddockToVineyard: [UUID: UUID] = Dictionary(
                fetchedPaddocks.map { ($0.id, $0.vineyardId) },
                uniquingKeysWith: { first, _ in first }
            )
            // paddock_name -> set of (vineyardId, paddockId) for non-deleted vineyards.
            // Used as a last-resort hint when the trip only carries paddockName.
            var paddocksByName: [String: [(vineyardId: UUID, paddockId: UUID)]] = [:]
            for p in fetchedPaddocks {
                guard let v = vineyardById[p.vineyardId], v.deletedAt == nil else { continue }
                paddocksByName[p.name.lowercased(), default: []].append((p.vineyardId, p.id))
            }

            var audit: [AuditTrip] = []
            audit.reserveCapacity(fetchedTrips.count)
            var result = AuditResult()
            result.scanned = fetchedTrips.count

            for trip in fetchedTrips {
                let currentVineyard = vineyardById[trip.vineyardId]
                let currentDeleted = currentVineyard?.deletedAt != nil

                let paddockIds = trip.paddockIds ?? (trip.paddockId.map { [$0] } ?? [])
                let resolvedVineyards = paddockIds.compactMap { paddockToVineyard[$0] }
                let allResolved = !paddockIds.isEmpty
                    && resolvedVineyards.count == paddockIds.count
                let unique = Set(resolvedVineyards)

                var problems: [ProblemCategory] = []
                var inferred: UUID?

                // Unique vineyard from paddocks?
                if allResolved, unique.count == 1, let only = unique.first,
                   vineyardById[only]?.deletedAt == nil {
                    inferred = only
                }

                // Categorise
                let tripVineyardIsZero = trip.vineyardId.uuidString == "00000000-0000-0000-0000-000000000000"
                if tripVineyardIsZero {
                    problems.append(.nullVineyard)
                } else if currentVineyard == nil {
                    problems.append(.unknownVineyard)
                } else if currentDeleted {
                    problems.append(.deletedVineyard)
                }

                if let scalar = trip.paddockId,
                   let scalarVineyard = paddockToVineyard[scalar],
                   scalarVineyard != trip.vineyardId,
                   currentVineyard != nil {
                    problems.append(.scalarPaddockMismatch)
                }

                if !paddockIds.isEmpty,
                   allResolved,
                   unique.count == 1,
                   let only = unique.first,
                   only != trip.vineyardId,
                   currentVineyard != nil,
                   !currentDeleted {
                    problems.append(.paddockIdsMismatch)
                }

                if paddockIds.isEmpty,
                   let name = trip.paddockName, !name.isEmpty {
                    let matches = paddocksByName[name.lowercased()] ?? []
                    if matches.count == 1, let m = matches.first {
                        inferred = m.vineyardId
                    } else if !matches.isEmpty {
                        problems.append(.nameOnlyPaddock)
                    }
                }

                let canAutoRepair: Bool = {
                    guard let inferred else { return false }
                    if inferred == trip.vineyardId, !currentDeleted { return false }
                    return true
                }()

                if !problems.isEmpty, !canAutoRepair {
                    problems.append(.unsafe)
                }

                if problems.isEmpty {
                    result.alreadyCorrect += 1
                }
                for p in problems {
                    result.counts[p, default: 0] += 1
                }
                if currentDeleted { result.deletedVineyard += 1 }

                let entry = AuditTrip(
                    id: trip.id,
                    startTime: trip.startTime,
                    endTime: trip.endTime,
                    paddockId: trip.paddockId,
                    paddockIds: paddockIds,
                    paddockName: trip.paddockName,
                    trackingPattern: trip.trackingPattern,
                    personName: trip.personName,
                    currentVineyardId: tripVineyardIsZero ? nil : trip.vineyardId,
                    currentVineyardName: currentVineyard?.name,
                    currentVineyardDeleted: currentDeleted,
                    inferredVineyardId: inferred,
                    inferredVineyardName: inferred.flatMap { vineyardById[$0]?.name },
                    problems: problems,
                    canAutoRepair: canAutoRepair,
                    autoRepaired: false,
                    manuallyRepaired: false,
                    lastError: nil
                )
                audit.append(entry)
            }
            self.trips = audit

            if autoRepair {
                await runAutoRepair(into: &result)
            }

            result.needingReview = self.trips.reduce(0) { acc, t in
                acc + ((!t.problems.isEmpty && !t.autoRepaired && !t.manuallyRepaired) ? 1 : 0)
            }
            result.ranAt = Date()
            self.lastResult = result
            self.status = .finished
        } catch {
            self.errorMessage = error.localizedDescription
            self.status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Auto repair

    private func runAutoRepair(into result: inout AuditResult) async {
        status = .repairing
        for index in trips.indices {
            let entry = trips[index]
            guard entry.canAutoRepair, let target = entry.inferredVineyardId else { continue }
            let scalar: UUID? = entry.paddockIds.count == 1 ? entry.paddockIds.first : entry.paddockId
            do {
                try await tripRepo.updateTripVineyardAssignment(
                    id: entry.id,
                    vineyardId: target,
                    paddockId: scalar
                )
                trips[index].autoRepaired = true
                trips[index].currentVineyardId = target
                trips[index].currentVineyardName = vineyards.first { $0.id == target }?.name
                trips[index].currentVineyardDeleted = false
                trips[index].problems = []
                result.autoRepaired += 1
            } catch {
                trips[index].lastError = error.localizedDescription
                result.pushFailures += 1
            }
        }
    }

    // MARK: - Manual repair

    func manuallyReassign(tripId: UUID, toVineyard vineyardId: UUID, paddockId: UUID?) async -> Bool {
        guard let index = trips.firstIndex(where: { $0.id == tripId }) else { return false }
        do {
            try await tripRepo.updateTripVineyardAssignment(
                id: tripId,
                vineyardId: vineyardId,
                paddockId: paddockId
            )
            trips[index].manuallyRepaired = true
            trips[index].currentVineyardId = vineyardId
            trips[index].currentVineyardName = vineyards.first { $0.id == vineyardId }?.name
            trips[index].currentVineyardDeleted = false
            trips[index].paddockId = paddockId ?? trips[index].paddockId
            trips[index].problems = []
            trips[index].lastError = nil
            return true
        } catch {
            trips[index].lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Diagnostics

    func diagnosticsSnippet() -> [String] {
        let r = lastResult
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        var out: [String] = []
        out.append("Admin Trip Vineyard Audit")
        if let at = r.ranAt {
            out.append("  ran_at: \(df.string(from: at))")
        } else {
            out.append("  ran_at: never")
        }
        out.append("  scanned: \(r.scanned)")
        out.append("  already_correct: \(r.alreadyCorrect)")
        out.append("  auto_repaired: \(r.autoRepaired)")
        out.append("  needing_review: \(r.needingReview)")
        out.append("  deleted_vineyard: \(r.deletedVineyard)")
        out.append("  push_failures: \(r.pushFailures)")
        for cat in ProblemCategory.allCases {
            let n = r.counts[cat] ?? 0
            if n > 0 {
                out.append("  \(cat.rawValue): \(n)")
            }
        }
        for t in problemTrips {
            let label = t.problems.map(\.rawValue).joined(separator: ",")
            out.append("    - \(t.id.uuidString) [\(label)]" +
                      (t.paddockName.map { " paddock=\"\($0)\"" } ?? "") +
                      (t.currentVineyardName.map { " vineyard=\"\($0)\"" } ?? "") +
                      (t.currentVineyardDeleted ? " (deleted)" : "") +
                      (t.lastError.map { " err=\"\($0)\"" } ?? ""))
        }
        return out
    }
}

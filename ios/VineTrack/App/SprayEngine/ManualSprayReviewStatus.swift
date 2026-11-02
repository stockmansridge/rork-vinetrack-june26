import Foundation

/// Manual-spray presentation evidence. A disappeared local operation does NOT
/// prove upload success: background replay can clear the queue before this
/// screen sees the server-readback record.
nonisolated enum ManualSprayReviewStatus: Sendable, Hashable {
    case reviewOnly
    case submitting
    case locallySavedAwaitingServer
    case verificationRequired
    case serverConfirmed

    static func resolve(serverConfirmed: Bool, hasRetainedSave: Bool,
                        hasSubmissionMarker: Bool, isSaving: Bool = false) -> Self {
        if serverConfirmed { return .serverConfirmed }
        if isSaving { return .submitting }
        if hasRetainedSave { return .locallySavedAwaitingServer }
        if hasSubmissionMarker { return .verificationRequired }
        return .reviewOnly
    }

    /// Read-only canonical server receipt: no queue mutation, retry or ACK.
    /// Unknown, partial or mismatched data MUST NOT release the old draft.
    static func reportMatchesOriginal(_ report: SprayReportPayloadV1,
                                      payload: ManualSprayPayload) -> Bool {
        guard report.identity.vineyardId == payload.vineyardId,
              report.identity.tripId == payload.tripId,
              report.identity.sprayRecordId == payload.sprayRecordId,
              report.identity.vineyardTimeZone == payload.vineyardTimeZone,
              report.provenance?.source == "manual",
              report.provenance?.manualEntryId == payload.manualEntryId,
              report.provenance?.isManualEntry == true,
              sameTimestamp(report.trip.startUtc, payload.startUtc),
              sameTimestamp(report.trip.endUtc, payload.endUtc),
              let blocks = report.blocks,
              blocks.count == payload.blocks.count,
              Set(blocks.map(\.blockId)) == Set(payload.blocks.map { $0.blockId.uuidString.lowercased() }),
              report.tanks.count == payload.tanks.count else { return false }

        for saved in payload.tanks {
            guard let actual = report.tanks.first(where: {
                $0.actualId == saved.actualId && $0.tankNumber == saved.tankNumber
            }), let water = actual.actualWaterLitres,
                  sameQuantity(water, saved.waterVolumeLitres),
                  actual.chemicals.count == saved.chemicals.count else { return false }
            for chemical in saved.chemicals {
                guard let reported = actual.chemicals.first(where: {
                    $0.actualChemicalId == chemical.id && $0.savedChemicalId == chemical.savedChemicalId
                }), let qty = reported.actualAmountBase,
                    sameQuantity(qty, chemical.actualAmountBase),
                    reported.unit == chemical.unit.rawValue,
                    reported.productCategory == chemical.productCategory,
                    reported.physicalForm == chemical.physicalForm.rawValue
                else { return false }
            }
        }
        return true
    }

    private static func sameQuantity(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs.isFinite && rhs.isFinite &&
            abs(lhs - rhs) <= max(0.000001, max(abs(lhs), abs(rhs)) * 0.000000001)
    }

    private static func sameTimestamp(_ raw: String?, _ expected: Date) -> Bool {
        guard let raw else { return false }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = parser.date(from: raw)
        parser.formatOptions = [.withInternetDateTime]
        guard let actual = fractional ?? parser.date(from: raw) else { return false }
        return abs(actual.timeIntervalSince(expected)) <= 1
    }

    var canOfferSave: Bool { self == .reviewOnly }

    var label: String {
        switch self {
        case .reviewOnly: "Review only — not yet saved"
        case .submitting: "Saving original manual spray — do not close"
        case .locallySavedAwaitingServer: "Saved on device — awaiting server confirmation"
        case .verificationRequired: "Submission status unknown — verification required"
        case .serverConfirmed: "Completed — server confirmed"
        }
    }
}

/// Local-only, owner/vineyard-scoped submission intent. This is NOT a sync
/// receipt and MUST NOT mutate, replay or acknowledge retained operations.
/// Persisted intent prevents a stale draft reopening as a new application
/// after asynchronous background ACK removes the original queue item.
@MainActor
struct ManualSpraySubmissionGuard {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func legacyKey(ownerId: UUID, vineyardId: UUID) -> String {
        "vinetrack_manual_spray_submission_guard_v1_\(ownerId.uuidString.lowercased())_\(vineyardId.uuidString.lowercased())"
    }

    private func key(ownerId: UUID, vineyardId: UUID, manualEntryId: UUID) -> String {
        "\(legacyKey(ownerId: ownerId, vineyardId: vineyardId))_\(manualEntryId.uuidString.lowercased())"
    }

    /// Only a single application's submission can prevent resubmitting that
    /// exact application; other spray records are not locked by this marker.
    func submittedId(ownerId: UUID, vineyardId: UUID, manualEntryId: UUID) -> UUID? {
        let active = defaults.string(forKey: key(ownerId: ownerId, vineyardId: vineyardId,
                                                  manualEntryId: manualEntryId))
            ?? defaults.string(forKey: legacyKey(ownerId: ownerId, vineyardId: vineyardId))
        guard active == manualEntryId.uuidString else { return nil }
        return manualEntryId
    }

    @discardableResult
    func mark(ownerId: UUID, vineyardId: UUID, manualEntryId: UUID) -> Bool {
        let name = key(ownerId: ownerId, vineyardId: vineyardId, manualEntryId: manualEntryId)
        defaults.set(manualEntryId.uuidString, forKey: name)
        return defaults.synchronize() &&
               submittedId(ownerId: ownerId, vineyardId: vineyardId, manualEntryId: manualEntryId) == manualEntryId
    }

    func clearIfMatching(ownerId: UUID, vineyardId: UUID, manualEntryId: UUID) {
        guard submittedId(ownerId: ownerId, vineyardId: vineyardId,
                          manualEntryId: manualEntryId) == manualEntryId else { return }
        defaults.removeObject(forKey: key(ownerId: ownerId, vineyardId: vineyardId,
                                          manualEntryId: manualEntryId))
        if defaults.string(forKey: legacyKey(ownerId: ownerId, vineyardId: vineyardId)) ==
            manualEntryId.uuidString {
            defaults.removeObject(forKey: legacyKey(ownerId: ownerId, vineyardId: vineyardId))
        }
    }
}

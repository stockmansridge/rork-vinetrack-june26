import Foundation

/// The permanent sync boundary for `spray_records.carrier_volume_basis`.
///
/// The database contract is authoritative and narrow: `l_per_ha`,
/// `l_per_100m`, `manual_actual_total` or NULL. The local enum
/// `SprayCarrierBasis` stores manual total volume as `"manual"` (a local
/// persistence value), so the raw enum value must never be written straight to
/// the server column — that is what produced
/// `spray_records_carrier_volume_basis_check` violations in 3.0.7 (109).
///
/// This is CARRIER (water) volume only. Application mode, treated-area method,
/// band geometry and chemical label rate bases are separate columns and must
/// never be canonicalised into this one.
nonisolated enum SprayCarrierBasisSyncContract {
    /// The only values the server column accepts.
    static let serverValues: Set<String> = ["l_per_ha", "l_per_100m", "manual_actual_total"]

    nonisolated enum Outcome: Equatable, Sendable {
        /// Nothing recorded — encodes as NULL, which the contract allows.
        case absent
        /// A value the server accepts. `converted` is true when a known local
        /// alias was translated.
        case canonical(String, converted: Bool)
        /// Not recognised. Never guessed into L/ha or L/100 m; the payload
        /// omits the column and the local record is preserved for recovery.
        case unknown(String)

        var serverValue: String? {
            if case let .canonical(value, _) = self { return value }
            return nil
        }
        var didConvert: Bool {
            if case let .canonical(_, converted) = self { return converted }
            return false
        }
        var isUnknown: Bool {
            if case .unknown = self { return true }
            return false
        }
        var attemptedValue: String? {
            switch self {
            case .absent: return nil
            case let .canonical(value, converted): return converted ? nil : value
            case let .unknown(value): return value
            }
        }
    }

    /// Canonicalise the value a spray record is about to send.
    static func outcome(for basis: SprayCarrierBasis?) -> Outcome {
        canonicalise(basis?.rawValue)
    }

    /// Canonicalise a raw string (offline replay, legacy payloads, re-upload of
    /// a decoded record).
    static func canonicalise(_ raw: String?) -> Outcome {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !trimmed.isEmpty else { return .absent }
        if serverValues.contains(trimmed) { return .canonical(trimmed, converted: false) }
        // The ONLY unambiguous historical alias: the local enum's own raw value
        // for "the operator stated the total water directly".
        if trimmed == "manual" { return .canonical("manual_actual_total", converted: true) }
        return .unknown(trimmed)
    }

    /// The value to write to `carrier_volume_basis`, or nil for NULL.
    static func serverValue(for basis: SprayCarrierBasis?) -> String? {
        outcome(for: basis).serverValue
    }

    /// Read a server value back into the local enum. Accepts the canonical
    /// `manual_actual_total` as well as the legacy `manual` so a record written
    /// by either build round-trips instead of silently losing its basis.
    static func basis(fromServerValue raw: String?) -> SprayCarrierBasis? {
        guard case let .canonical(value, _) = canonicalise(raw) else { return nil }
        switch value {
        case "l_per_ha": return .litresPerHectare
        case "l_per_100m": return .litresPer100Metres
        case "manual_actual_total": return .manualTotalVolume
        default: return nil
        }
    }
}

/// Lightweight, non-identifying record of what the carrier boundary did.
/// Carries no notes, chemical or customer content.
nonisolated struct SprayCarrierSyncDiagnostic: Sendable, Equatable {
    let sprayRecordId: UUID
    /// The value the record attempted to send, when it was not already canonical.
    let attemptedBasis: String?
    /// The value actually sent (nil when the column was omitted).
    let canonicalBasis: String?
    let didConvert: Bool
    let wasRejected: Bool
    /// Application mode (foliar / banded / spreader …), kept separate from carrier basis.
    let applicationMode: String?
    /// The local carrier enum case, for recurrence identification.
    let volumeBasisCase: String?

    init(sprayRecordId: UUID, basis: SprayCarrierBasis?, applicationMode: String?) {
        let outcome = SprayCarrierBasisSyncContract.outcome(for: basis)
        self.sprayRecordId = sprayRecordId
        self.attemptedBasis = outcome.didConvert || outcome.isUnknown ? basis?.rawValue : nil
        self.canonicalBasis = outcome.serverValue
        self.didConvert = outcome.didConvert
        self.wasRejected = outcome.isUnknown
        self.applicationMode = applicationMode
        self.volumeBasisCase = basis.map { String(describing: $0) }
    }

    var isNoteworthy: Bool { didConvert || wasRejected }

    var summary: String {
        "spray \(sprayRecordId) carrier attempted=\(attemptedBasis ?? "-") canonical=\(canonicalBasis ?? "null") converted=\(didConvert) rejected=\(wasRejected) mode=\(applicationMode ?? "-") case=\(volumeBasisCase ?? "-")"
    }
}

/// Why an actual-use row did or did not upload. Kept as a pure decision so the
/// ordering rule is testable without network or store setup.
nonisolated enum SprayTankActualUploadGate {
    nonisolated enum Decision: Equatable, Sendable {
        case upload
        /// The parent trip row does not exist on the server yet.
        case skipParentTripNotEstablished
        /// The spray record has not reached the server yet.
        case skipSprayRecordNotEstablished

        var skipReason: String? {
            switch self {
            case .upload: return nil
            case .skipParentTripNotEstablished: return "parent trip not established on server"
            case .skipSprayRecordNotEstablished: return "spray record not established on server"
            }
        }
    }

    /// A trip pending ONLY because its final ended state is deferred must not
    /// block its own actuals — that was the Phase 5 deadlock.
    static func decide(parentTripBlocked: Bool, sprayRecordPending: Bool) -> Decision {
        if parentTripBlocked { return .skipParentTripNotEstablished }
        if sprayRecordPending { return .skipSprayRecordNotEstablished }
        return .upload
    }
}

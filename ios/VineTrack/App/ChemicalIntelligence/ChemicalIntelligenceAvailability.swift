import Foundation

/// Whether a recorded spray application's chemistry can be assessed at all, and
/// how far it can be trusted if so.
///
/// This is the contract the future Resistance Rules Engine consumes. It exists
/// as its own type for one reason: `chemicalSnapshot == nil` must never be read
/// as "no resistance issue". A large amount of legitimate VineTrack history
/// predates Chemical Intelligence and has no snapshot, and treating that silence
/// as safety would produce a green rotation report for a season nobody can
/// actually account for. The honest answer is "unable to fully assess this
/// application", and that answer needs a name in the domain.
///
/// Mirrors `ChemicalIntelligenceAvailability.kt` on Android.
nonisolated enum ChemicalIntelligenceAvailability: String, Codable, Sendable, Hashable, CaseIterable {
    /// Groups are authoritatively classified and the product identity is
    /// established. Usable without qualification.
    case availableVerified = "available_verified"
    /// The product is identified, but at least one resistance-relevant field is
    /// unconfirmed. Usable, must be shown as partial.
    case availablePartiallyVerified = "available_partially_verified"
    /// Chemistry is recorded but rests on operator entry or a legacy record.
    /// The engine may reason from it, and must say so.
    case availableUnverified = "available_unverified"
    /// Sources disagreed about a resistance-critical field. Nothing here may be
    /// relied on until a human resolves it.
    case conflict
    /// No usable chemistry was recorded for this application. NOT a pass.
    case unavailable

    nonisolated var label: String {
        switch self {
        case .availableVerified: return "Verified chemistry"
        case .availablePartiallyVerified: return "Partially verified chemistry"
        case .availableUnverified: return "Unverified chemistry"
        case .conflict: return "Conflicting chemistry"
        case .unavailable: return "Chemical intelligence unavailable"
        }
    }

    /// Whether resistance analysis can reach ANY conclusion about this
    /// application's chemistry.
    ///
    /// `false` obliges the caller to report "unable to fully assess" — never a
    /// clean result.
    nonisolated var canAssess: Bool {
        switch self {
        case .availableVerified, .availablePartiallyVerified, .availableUnverified:
            return true
        case .conflict, .unavailable:
            return false
        }
    }

    /// Whether the groups may be used without qualifying them to the operator.
    nonisolated var isDependable: Bool { self == .availableVerified }

    /// Whether a conclusion drawn from this application must carry a caveat.
    nonisolated var requiresQualification: Bool {
        switch self {
        case .availableVerified: return false
        case .availablePartiallyVerified, .availableUnverified, .conflict, .unavailable:
            return true
        }
    }

    /// Explicit, permanent guarantee that no availability state is ever a
    /// silent pass.
    ///
    /// A future Resistance Engine asking "is this application fine?" gets `nil`
    /// from anything it cannot assess, forcing it to handle the unknown rather
    /// than falling through to a default green.
    nonisolated var permitsCleanResult: Bool { canAssess }

    /// Operator-facing sentence for an application that cannot be assessed.
    nonisolated var assessmentCaveat: String? {
        switch self {
        case .availableVerified:
            return nil
        case .availablePartiallyVerified:
            return "Some of this product's resistance information was unconfirmed when it was applied."
        case .availableUnverified:
            return "This product's activity groups were entered manually or carried over from an older record."
        case .conflict:
            return "Sources disagreed about this product's resistance information when it was applied."
        case .unavailable:
            return "No chemical intelligence was recorded for this application, so it cannot be fully assessed."
        }
    }

    /// Order for worst-first presentation, so an unassessable application is
    /// never buried under assessable ones.
    nonisolated var severityRank: Int {
        switch self {
        case .unavailable: return 0
        case .conflict: return 1
        case .availableUnverified: return 2
        case .availablePartiallyVerified: return 3
        case .availableVerified: return 4
        }
    }

    // MARK: - Resolution

    /// Read availability off a frozen spray-line snapshot.
    ///
    /// Deliberately takes only the snapshot. It does NOT accept a
    /// `SavedChemical`, and there is no overload that does, because resolving
    /// today's Chemical Store during a historical read is precisely the
    /// back-fill this stage forbids: an old application would silently inherit
    /// chemistry it was never recorded with.
    static func resolve(snapshot: ChemicalLineSnapshot?) -> ChemicalIntelligenceAvailability {
        guard let snapshot else { return .unavailable }
        // A snapshot can exist and still carry nothing assessable — a
        // legacy-only line that preserved `"Group 3 + 11"` as display text has
        // no structured group and must not be mistaken for one.
        guard snapshot.hasResistanceData else { return .unavailable }
        return from(status: snapshot.verificationStatus)
    }

    /// Map a frozen verification status onto availability.
    static func from(status: ChemicalVerificationStatus) -> ChemicalIntelligenceAvailability {
        switch status {
        case .verified: return .availableVerified
        case .partiallyVerified: return .availablePartiallyVerified
        // A legacy record that was never matched has chemistry of a sort, but
        // nobody ever confirmed which product it describes. That is unverified
        // chemistry, not partial verification.
        case .unverified, .needsMatch: return .availableUnverified
        case .conflict: return .conflict
        }
    }

    /// Availability for a whole tank/application: the WEAKEST line governs.
    ///
    /// A tank mixing a verified product with one whose chemistry is unknown
    /// cannot be assessed as verified — the unknown line could be the very
    /// group that breaks the rotation. An application with no lines at all is
    /// unavailable rather than vacuously fine.
    static func combined(
        _ availabilities: [ChemicalIntelligenceAvailability]
    ) -> ChemicalIntelligenceAvailability {
        availabilities.min { $0.severityRank < $1.severityRank } ?? .unavailable
    }
}

extension ChemicalLineSnapshot {
    /// Availability of this frozen line's chemistry.
    nonisolated var resistanceAvailability: ChemicalIntelligenceAvailability {
        ChemicalIntelligenceAvailability.resolve(snapshot: self)
    }
}

extension SprayChemical {
    /// Availability of this application line's chemistry.
    ///
    /// Reads the frozen snapshot only. A line recorded before Chemical
    /// Intelligence existed reports `.unavailable`, which is the truth.
    nonisolated var resistanceAvailability: ChemicalIntelligenceAvailability {
        ChemicalIntelligenceAvailability.resolve(snapshot: chemicalSnapshot)
    }
}

extension SprayTank {
    /// Weakest availability across this tank's product lines.
    nonisolated var resistanceAvailability: ChemicalIntelligenceAvailability {
        ChemicalIntelligenceAvailability.combined(chemicals.map(\.resistanceAvailability))
    }
}

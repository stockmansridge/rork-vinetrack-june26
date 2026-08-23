import Foundation

/// A vineyard's spray calculation/compliance profile.
///
/// Governs how the grower is allowed to ENTER carrier volume. It says nothing
/// about product label rates — see `SprayProductRateBasis`.
nonisolated enum SprayComplianceProfile: String, Sendable, Codable, CaseIterable {
    /// Australia — hectare and row-length carrier volumes both acceptable.
    case australia = "au"
    /// New Zealand / VineTrack SWNZ — L/100 m is the only user-entered canopy
    /// carrier-volume basis. L/ha is still derived and stored internally.
    case newZealandSWNZ = "nz_swnz"

    var label: String {
        switch self {
        case .australia: return "Australia"
        case .newZealandSWNZ: return "New Zealand (SWNZ)"
        }
    }
}

/// Which carrier-volume bases a vineyard may enter.
nonisolated enum SprayCarrierVolumePolicy: String, Sendable, Codable, CaseIterable {
    case litresPerHectareOnly = "l_per_ha"
    case litresPer100MetresOnly = "l_per_100m"
    case either = "either"

    func allows(_ basis: SprayCarrierBasis) -> Bool {
        // Manual is always available. The policy governs which CALIBRATED
        // canopy workflow a vineyard may use; it has no view on an operator
        // who already knows they are mixing 400 L in a knapsack, and an SWNZ
        // vineyard hand-spraying a few vines is not breaching anything.
        if basis == .manualTotalVolume { return true }
        switch self {
        case .either: return true
        case .litresPerHectareOnly: return basis == .litresPerHectare
        case .litresPer100MetresOnly: return basis == .litresPer100Metres
        }
    }

    /// The basis to present by default under this policy.
    var defaultBasis: SprayCarrierBasis {
        self == .litresPer100MetresOnly ? .litresPer100Metres : .litresPerHectare
    }
}

/// The vineyard-level spray profile as stored (both fields nullable) plus the
/// rules for resolving an unset profile.
///
/// Resolution NEVER writes anything: an unset vineyard keeps NULL in the
/// database and simply presents a country-appropriate default, so no existing
/// vineyard silently acquires a compliance profile it did not choose.
nonisolated struct SprayVineyardProfile: Sendable, Hashable {
    /// Stored `vineyards.spray_compliance_profile`, or nil when never set.
    let storedProfile: SprayComplianceProfile?
    /// Stored `vineyards.spray_carrier_volume_basis`, or nil when never set.
    let storedPolicy: SprayCarrierVolumePolicy?
    /// Existing `vineyards.country_code` (ISO-3166 alpha-2).
    let countryCode: String?

    init(
        storedProfile: SprayComplianceProfile? = nil,
        storedPolicy: SprayCarrierVolumePolicy? = nil,
        countryCode: String? = nil
    ) {
        self.storedProfile = storedProfile
        self.storedPolicy = storedPolicy
        self.countryCode = countryCode
    }

    /// New Zealand vineyards default to the SWNZ profile; everyone else to AU.
    var resolvedProfile: SprayComplianceProfile {
        if let storedProfile { return storedProfile }
        let code = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code == "NZ" ? .newZealandSWNZ : .australia
    }

    /// An explicitly stored policy always wins. Otherwise the profile decides:
    /// SWNZ restricts entry to L/100 m, Australia allows either.
    var resolvedPolicy: SprayCarrierVolumePolicy {
        if let storedPolicy { return storedPolicy }
        return resolvedProfile == .newZealandSWNZ ? .litresPer100MetresOnly : .either
    }

    var defaultCarrierBasis: SprayCarrierBasis { resolvedPolicy.defaultBasis }

    func allows(_ basis: SprayCarrierBasis) -> Bool { resolvedPolicy.allows(basis) }

    /// True when the grower has no choice to make and the UI should not offer one.
    var isCarrierBasisLocked: Bool { resolvedPolicy != .either }
}

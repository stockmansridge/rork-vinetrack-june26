import CryptoKit
import Foundation

/// The PERSISTED shape of `saved_chemicals.default_rates` (sql/214).
///
/// This is the storage mirror of the Deno `SavedChemicalDefaultRates` contract
/// in `supabase/functions/chemical-info-lookup/default_rates.ts`, and of the
/// Android `StoredChemicalDefaultRates`. It is deliberately separate from the
/// in-flight review state: one is a decision being made, the other is the
/// decision that was made. Merging them would let an unconfirmed
/// recommendation reach the database.
///
/// # What this records, and what it must never become
///
/// `registered_uses` is label evidence and stays untouched forever. This column
/// records only WHICH authoritative rate the operator confirmed, never a new
/// rate. If it is absent, wrong or unreadable, every calculation still has
/// everything it needs from `registered_uses`, so nothing here confers
/// authority.
///
/// The amount is a SNAPSHOT of the label's own amount in the LABEL's own unit —
/// not the pack unit, not the inventory unit, never a converted convenience
/// figure. A label reading `3 L/100 L` persists as `value: 3, unit: "L"` even
/// for a product the vineyard buys in millilitres.
///
/// # Null is "not recorded", never "no rates exist"
///
/// A `nil` column means no default has been recorded. A `nil` basis slot means
/// none is recorded FOR THAT BASIS. Neither says anything about what the label
/// offers. Nothing is ever backfilled here from `ratePerHa` or `rates`: those
/// are legacy operator numbers with no link back to a registered direction, so
/// deriving a default from them would invent a provenance the data cannot
/// support.
nonisolated struct StoredChemicalDefaultRates: Codable, Sendable, Hashable {
    /// Contract version. Bump only when the stored shape changes.
    static let currentVersion: Int = 1

    var version: Int
    var perHectare: StoredChemicalDefaultRate?
    var per100Litres: StoredChemicalDefaultRate?

    init(
        version: Int = StoredChemicalDefaultRates.currentVersion,
        perHectare: StoredChemicalDefaultRate? = nil,
        per100Litres: StoredChemicalDefaultRate? = nil
    ) {
        self.version = version
        self.perHectare = perHectare
        self.per100Litres = per100Litres
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case version
        case perHectare = "per_hectare"
        case per100Litres = "per_100_litres"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? StoredChemicalDefaultRates.currentVersion
        // Tolerant per slot: one unreadable basis must never discard the other,
        // and must never take the whole chemical down with it.
        perHectare = try? c.decodeIfPresent(StoredChemicalDefaultRate.self, forKey: .perHectare)
        per100Litres = try? c.decodeIfPresent(StoredChemicalDefaultRate.self, forKey: .per100Litres)
    }

    /// The slot for a basis, or `nil` when nothing is recorded on it.
    nonisolated func slot(_ basis: ChemicalDefaultRateBasis) -> StoredChemicalDefaultRate? {
        switch basis {
        case .perHectare: return perHectare
        case .per100Litres: return per100Litres
        }
    }

    /// Replace one basis slot, leaving the other exactly as it was.
    nonisolated func withSlot(
        _ basis: ChemicalDefaultRateBasis,
        _ slot: StoredChemicalDefaultRate?
    ) -> StoredChemicalDefaultRates {
        var copy = self
        switch basis {
        case .perHectare: copy.perHectare = slot
        case .per100Litres: copy.per100Litres = slot
        }
        return copy
    }

    /// True when neither basis records a choice — the column may then stay null.
    nonisolated var isEmpty: Bool { perHectare == nil && per100Litres == nil }
}

/// One recorded operational default.
///
/// `rateIds` cites every authoritative registered rate that supports this
/// amount. It is an ARRAY, always: a printed label can state the same amount
/// against several distinct directions (VICOL APVMA 33182 states `3 L/100 L`
/// for both European Red Mites and Grapevine Scale), and collapsing them to one
/// id would discard a direction the operator is entitled to rely on.
nonisolated struct StoredChemicalDefaultRate: Codable, Sendable, Hashable {
    /// Provenance vocabulary. There is deliberately no `inferred`: nothing in
    /// this system reconstructs a historical choice, so no value may imply it.
    static let sourceOperator: String = "operator"
    static let sourceRecommended: String = "recommended"

    /// Deterministic identity of the grouped choice. See `ChemicalDefaultRateIdentity`.
    var optionKey: String
    /// Gate D1 `rate_v1_` identities of printed DIRECTIONS. Never UUIDs. At least one.
    var rateIds: [String]
    /// Must equal the slot this selection is stored under.
    var basis: String
    /// The label rate's own unit (`"L"`, `"mL"`, `"kg"`, `"g"`).
    var unit: String
    /// Single-value amount, or `nil` when the label states a range.
    var value: Double?
    /// Lower bound of a true range, else `nil`.
    var minValue: Double?
    /// Upper bound of a true range, else `nil`.
    var maxValue: Double?
    /// Provenance, never part of identity. `operator` means a human confirmed it.
    var source: String
    /// Provenance. Optional; never part of identity.
    var selectedAt: String?
    /// The label revision the amount was read from. Provenance for "the label
    /// has moved on" detection — it must never influence `optionKey`, or a
    /// reissued label restating the same direction would orphan the default.
    var labelVersion: String?

    init(
        optionKey: String,
        rateIds: [String],
        basis: String,
        unit: String,
        value: Double? = nil,
        minValue: Double? = nil,
        maxValue: Double? = nil,
        source: String = StoredChemicalDefaultRate.sourceOperator,
        selectedAt: String? = nil,
        labelVersion: String? = nil
    ) {
        self.optionKey = optionKey
        self.rateIds = rateIds
        self.basis = basis
        self.unit = unit
        self.value = value
        self.minValue = minValue
        self.maxValue = maxValue
        self.source = source
        self.selectedAt = selectedAt
        self.labelVersion = labelVersion
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case optionKey = "option_key"
        case rateIds = "rate_ids"
        case basis
        case unit
        case value
        case minValue = "min_value"
        case maxValue = "max_value"
        case source
        case selectedAt = "selected_at"
        case labelVersion = "label_version"
    }
}

/// Deterministic identity for a grouped operational choice.
///
/// Pure and platform-independent: the same choice yields the same key on the
/// server, on Android and here. A UUID would change on every write, making the
/// key useless for recognising that two clients chose the same thing.
///
/// Byte-for-byte mirror of `canonicalDefaultOptionInput` / `mintDefaultOptionKey`
/// in `default_rates.ts`, including the U+001F field separator and U+001E rate
/// separator. Both are needed: without them two different field splits could
/// hash alike.
///
/// Contains ONLY what makes the choice the choice — basis, label unit, amount
/// and the supporting direction set. Deliberately absent: `source`,
/// `selectedAt`, `labelVersion`, UI ordering, recommendation state, the pack
/// unit, label URL and any cache key. Every one of those can differ between two
/// clients that made the identical choice.
nonisolated enum ChemicalDefaultRateIdentity {
    static let optionIDVersion: String = "default_option_v1"

    private static let unitSeparator: String = "\u{001f}"
    private static let recordSeparator: String = "\u{001e}"

    /// Canonical rate-id list: trimmed, de-duplicated, sorted.
    ///
    /// Sorting is what makes the identity order-independent — a client listing
    /// the Grapevine Scale direction first must reach the same option as one
    /// listing European Red Mites first, because they made the same choice.
    static func canonicalRateIDs(_ ids: [String?]?) -> [String] {
        let trimmed = (ids ?? [])
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(trimmed)).sorted()
    }

    /// Mirror of the Deno `normaliseIdentityText`.
    static func normaliseText(_ value: String?) -> String {
        let folded = (value ?? "").precomposedStringWithCompatibilityMapping.lowercased()
        var out = ""
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            let isAllowed = (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
            if isAllowed {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// Mirror of the Deno `normaliseIdentityNumber`.
    ///
    /// Absent is the literal `-`, distinct from any numeric value: "no upper
    /// bound" and "an upper bound of zero" must never hash alike.
    static func normaliseNumber(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-" }
        var fixed = String(format: "%.6f", value)
        while fixed.hasSuffix("0") { fixed.removeLast() }
        if fixed.hasSuffix(".") { fixed.removeLast() }
        return fixed == "-0" ? "0" : fixed
    }

    /// The exact bytes hashed for an option identity.
    static func canonicalInput(
        basis: String,
        unit: String?,
        value: Double?,
        minValue: Double?,
        maxValue: Double?,
        rateIDs: [String?]?
    ) -> String {
        let ids = canonicalRateIDs(rateIDs).map { normaliseText($0) }.sorted()
        let joinedIDs = ids.joined(separator: recordSeparator)
        let fields: [String] = [
            "v=\(optionIDVersion)",
            "basis=\(normaliseText(basis).isEmpty ? "-" : normaliseText(basis))",
            "unit=\(normaliseText(unit).isEmpty ? "-" : normaliseText(unit))",
            "value=\(normaliseNumber(value))",
            "min=\(normaliseNumber(minValue))",
            "max=\(normaliseNumber(maxValue))",
            "rates=\(joinedIDs.isEmpty ? "-" : joinedIDs)"
        ]
        return fields.joined(separator: unitSeparator)
    }

    /// Mint the deterministic identity of a grouped operational choice.
    static func mintOptionKey(
        basis: String,
        unit: String?,
        value: Double?,
        minValue: Double?,
        maxValue: Double?,
        rateIDs: [String?]?
    ) -> String {
        let input = canonicalInput(
            basis: basis,
            unit: unit,
            value: value,
            minValue: minValue,
            maxValue: maxValue,
            rateIDs: rateIDs
        )
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(optionIDVersion)_\(hex.prefix(32))"
    }
}

// MARK: - Building a stored default from a confirmed option

extension StoredChemicalDefaultRate {

    /// Build the persisted record of a CONFIRMED operational choice.
    ///
    /// Returns `nil` when the option states no usable number, because a
    /// verbatim direction with no figure is a faithful record and not a rate a
    /// calculation may run on — it can never become a default.
    ///
    /// The amount is copied from the LABEL, never from the operator's typing:
    /// `value` / `minValue` / `maxValue` are the registered figures exactly as
    /// printed. `confirmedValue` is the operator's exact dose INSIDE a band and
    /// is only accepted when the option authorises it, so a stored default can
    /// never name a dose the label does not cover.
    ///
    /// - Parameters:
    ///   - option: the registered option the operator confirmed.
    ///   - basis: the slot this will be stored under.
    ///   - grapevineUses: the authoritative GRAPEVINE uses this option was
    ///     built from. Passing the whole label would let a pome-fruit direction
    ///     supply a `rate_id` for a vineyard default.
    ///   - confirmedValue: the operator's exact dose within a label band.
    ///   - labelVersion: provenance only; never part of the identity.
    ///   - source: `operator` once a human has confirmed. A recommendation that
    ///     has not been confirmed must not be persisted.
    static func confirmed(
        option: ChemicalDefaultRateOption,
        basis: ChemicalDefaultRateBasis,
        grapevineUses: [ChemicalRegisteredUse],
        confirmedValue: Double? = nil,
        labelVersion: String? = nil,
        selectedAt: Date? = nil,
        source: String = StoredChemicalDefaultRate.sourceOperator
    ) -> StoredChemicalDefaultRate? {
        let rate = option.rate
        // A default must cite a real registered rate. No usable number, no
        // default — the label evidence still stands on its own.
        guard rate.value != nil || (rate.minValue != nil && rate.maxValue != nil) else {
            return nil
        }

        let rateIDs = ChemicalDefaultRate.rateIDs(for: option, from: grapevineUses)
        // Every default must be traceable to at least one printed direction.
        // An untraceable default is exactly the invented provenance this
        // contract exists to prevent.
        guard !rateIDs.isEmpty else { return nil }

        let optionKey = ChemicalDefaultRateIdentity.mintOptionKey(
            basis: basis.rawValue,
            unit: rate.unit,
            value: rate.value,
            minValue: rate.minValue,
            maxValue: rate.maxValue,
            rateIDs: rateIDs
        )

        var stored = StoredChemicalDefaultRate(
            optionKey: optionKey,
            rateIds: rateIDs,
            basis: basis.rawValue,
            unit: rate.unit,
            value: rate.value,
            minValue: rate.minValue,
            maxValue: rate.maxValue,
            source: source,
            selectedAt: (selectedAt ?? Date()).iso8601DefaultRateTimestamp,
            labelVersion: labelVersion
        )
        // The operator's exact dose is recorded ALONGSIDE the registered
        // figures, never over them: a band stays a band on the record.
        if let confirmedValue, option.authorises(confirmedValue), option.isLabelRange {
            stored.value = confirmedValue
        }
        return stored
    }
}

extension ChemicalDefaultRate {

    /// Every authoritative `rate_id` that supports this option's amount.
    ///
    /// An option merges rates that state the same amount on the same basis, so
    /// several printed directions can stand behind one operator choice. All of
    /// them are cited: collapsing to the first would discard a direction the
    /// operator is entitled to rely on.
    ///
    /// Server-minted ids only. A rate the server never identified contributes
    /// nothing rather than a device-minted substitute, because a locally
    /// invented identity would not match on any other client.
    static func rateIDs(
        for option: ChemicalDefaultRateOption,
        from grapevineUses: [ChemicalRegisteredUse]
    ) -> [String] {
        var ids: [String] = []
        for use in grapevineUses {
            for rate in use.rates where distinctnessKey(rate) == option.id {
                guard let rateId = rate.rateId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rateId.isEmpty
                else { continue }
                ids.append(rateId)
            }
        }
        return Array(Set(ids)).sorted()
    }
}

private extension Date {
    /// ISO-8601 with fractional seconds, matching the server's provenance format.
    var iso8601DefaultRateTimestamp: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
    }
}

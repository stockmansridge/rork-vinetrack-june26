import Foundation

/// The resistance-relevant facts about a product AS THEY STOOD when a spray
/// was recorded.
///
/// Historical resistance analysis must not depend on the current Chemical
/// Store record. If a saved chemical's classification is corrected in three
/// years — or the product is archived, or its actives are restructured — the
/// spray from today must still be able to say what VineTrack believed at the
/// time it was applied. Otherwise a corrected record silently rewrites years of
/// spray history, and every rotation calculated from it.
///
/// Persisted additively inside the existing `tanks` JSONB on each chemical
/// line, so no relational churn and no migration are required for it.
nonisolated struct ChemicalLineSnapshot: Codable, Sendable, Hashable {
    /// Which Chemical Store record was frozen. Kept so history is
    /// self-describing: a reader of the snapshot alone can say what it came
    /// from. Never used to re-read today's record for chemistry.
    var savedChemicalId: String?
    /// The product name AS DISPLAYED at application time. Frozen separately
    /// from the store record because a product can be renamed later.
    var productName: String?
    /// Actives and their groups as classified at application time.
    var activeIngredients: [ChemicalActiveIngredient]
    /// Bare group codes, e.g. `["3", "11"]`, duplicated out of
    /// `activeIngredients` so a reader never has to reconstruct them.
    var activityGroupCodes: [String]
    /// The trust level the product carried at application time. A spray
    /// recorded against an unverified product stays visibly unverified in
    /// history even if the product is verified later.
    var verificationStatus: ChemicalVerificationStatus
    /// The registered identity used, e.g. `"AU:apvma:62764"`.
    var registrationIdentityKey: String?
    /// Country the identity was scoped to.
    var countryCode: String?
    /// `ChemicalIntelligence.schemaVersion` at the time.
    var schemaVersion: Int
    /// `AuthoritativeActivityGroups.tableVersion` at the time — which revision
    /// of the classification table made this call.
    var activityGroupTableVersion: Int
    /// The legacy `chemical_group` string as it was DISPLAYED at the time.
    /// Kept for faithful reproduction of an old record, never for calculation.
    var legacyChemicalGroup: String?
    /// When the snapshot was taken.
    var capturedAt: Date?

    // MARK: - Applied rate provenance
    //
    // What was ACTUALLY poured, and where that number came from. Frozen for
    // the same reason as the chemistry above: a spray must stay readable
    // after the Chemical Store record moves on.
    //
    // This matters most for a confirmed BAND. If the store holds
    // `2–3 L/100 L` and the operator sprayed 2.5, the record has to say 2.5
    // — the range alone cannot reconstruct it, and re-reading the store later
    // would give a band rather than the dose. Equally, the store must keep
    // saying `2–3`: the 2.5 belonged to one tank, not to the product.

    /// The dose actually applied on this line, in `appliedRateUnit`.
    var appliedRate: Double?
    /// The unit that dose was expressed in — never the pack unit.
    var appliedRateUnit: String?
    /// The basis the dose was quoted against (`per_hectare` / `per_100_litres`).
    /// Stored verbatim so no reader has to infer it, and never converted.
    var appliedRateBasis: String?
    /// Whether the rate this dose came from was a registered label direction
    /// (`canonical`) or one the operator typed and confirmed (`manual`).
    ///
    /// Keeps the official/user-confirmed distinction alive in history: a
    /// record must never later present a typed rate as label evidence.
    var rateEntryMethod: String?
    /// The confirmed band this dose was chosen inside, when there was one.
    /// Absent for a single confirmed rate.
    var rateRangeMin: Double?
    var rateRangeMax: Double?

    init(
        savedChemicalId: String? = nil,
        productName: String? = nil,
        activeIngredients: [ChemicalActiveIngredient] = [],
        activityGroupCodes: [String] = [],
        verificationStatus: ChemicalVerificationStatus = .unverified,
        registrationIdentityKey: String? = nil,
        countryCode: String? = nil,
        schemaVersion: Int = ChemicalIntelligence.currentSchemaVersion,
        activityGroupTableVersion: Int = AuthoritativeActivityGroups.tableVersion,
        legacyChemicalGroup: String? = nil,
        capturedAt: Date? = nil,
        appliedRate: Double? = nil,
        appliedRateUnit: String? = nil,
        appliedRateBasis: String? = nil,
        rateEntryMethod: String? = nil,
        rateRangeMin: Double? = nil,
        rateRangeMax: Double? = nil
    ) {
        self.savedChemicalId = savedChemicalId
        self.productName = productName
        self.activeIngredients = activeIngredients
        self.activityGroupCodes = activityGroupCodes
        self.verificationStatus = verificationStatus
        self.registrationIdentityKey = registrationIdentityKey
        self.countryCode = countryCode
        self.schemaVersion = schemaVersion
        self.activityGroupTableVersion = activityGroupTableVersion
        self.legacyChemicalGroup = legacyChemicalGroup
        self.capturedAt = capturedAt
        self.appliedRate = appliedRate
        self.appliedRateUnit = appliedRateUnit
        self.appliedRateBasis = appliedRateBasis
        self.rateEntryMethod = rateEntryMethod
        self.rateRangeMin = rateRangeMin
        self.rateRangeMax = rateRangeMax
    }

    /// True when the dose on this line came from a rate the operator typed.
    nonisolated var isUserEnteredRate: Bool {
        rateEntryMethod?.trimmingCharacters(in: .whitespacesAndNewlines)
            == StoredChemicalDefaultRate.entryManual
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case savedChemicalId = "saved_chemical_id"
        case productName = "product_name"
        case activeIngredients = "active_ingredients"
        case activityGroupCodes = "activity_groups"
        case verificationStatus = "verification_status"
        case registrationIdentityKey = "registration_identity_key"
        case countryCode = "country_code"
        case schemaVersion = "schema_version"
        case activityGroupTableVersion = "activity_group_table_version"
        case legacyChemicalGroup = "legacy_chemical_group"
        case capturedAt = "captured_at"
        case appliedRate = "applied_rate"
        case appliedRateUnit = "applied_rate_unit"
        case appliedRateBasis = "applied_rate_basis"
        case rateEntryMethod = "rate_entry_method"
        case rateRangeMin = "rate_range_min"
        case rateRangeMax = "rate_range_max"
    }

    /// One wire format for `captured_at` on both platforms: an ISO-8601 string.
    ///
    /// Encoded explicitly rather than left to the ambient `JSONEncoder` date
    /// strategy, because the snapshot travels inside `tanks` JSONB that Android
    /// also writes. A Swift-default `978307200.5` next to Kotlin's
    /// `"2026-08-15T…Z"` would be two shapes for the same fact in one column.
    nonisolated static let capturedAtFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated static func parseCapturedAt(_ raw: String) -> Date? {
        if let date = capturedAtFormatter.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(savedChemicalId, forKey: .savedChemicalId)
        try c.encodeIfPresent(productName, forKey: .productName)
        try c.encode(activeIngredients, forKey: .activeIngredients)
        try c.encode(activityGroupCodes, forKey: .activityGroupCodes)
        try c.encode(verificationStatus.rawValue, forKey: .verificationStatus)
        try c.encodeIfPresent(registrationIdentityKey, forKey: .registrationIdentityKey)
        try c.encodeIfPresent(countryCode, forKey: .countryCode)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(activityGroupTableVersion, forKey: .activityGroupTableVersion)
        try c.encodeIfPresent(legacyChemicalGroup, forKey: .legacyChemicalGroup)
        try c.encodeIfPresent(
            capturedAt.map { Self.capturedAtFormatter.string(from: $0) },
            forKey: .capturedAt
        )
        try c.encodeIfPresent(appliedRate, forKey: .appliedRate)
        try c.encodeIfPresent(appliedRateUnit, forKey: .appliedRateUnit)
        try c.encodeIfPresent(appliedRateBasis, forKey: .appliedRateBasis)
        try c.encodeIfPresent(rateEntryMethod, forKey: .rateEntryMethod)
        try c.encodeIfPresent(rateRangeMin, forKey: .rateRangeMin)
        try c.encodeIfPresent(rateRangeMax, forKey: .rateRangeMax)
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        savedChemicalId = try c.decodeIfPresent(String.self, forKey: .savedChemicalId)
        productName = try c.decodeIfPresent(String.self, forKey: .productName)
        activeIngredients = try c.decodeIfPresent([ChemicalActiveIngredient].self, forKey: .activeIngredients) ?? []
        activityGroupCodes = try c.decodeIfPresent([String].self, forKey: .activityGroupCodes) ?? []
        let raw = try c.decodeIfPresent(String.self, forKey: .verificationStatus) ?? ""
        verificationStatus = ChemicalVerificationStatus(rawValue: raw) ?? .unverified
        registrationIdentityKey = try c.decodeIfPresent(String.self, forKey: .registrationIdentityKey)
        countryCode = try c.decodeIfPresent(String.self, forKey: .countryCode)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        activityGroupTableVersion = try c.decodeIfPresent(Int.self, forKey: .activityGroupTableVersion) ?? 0
        legacyChemicalGroup = try c.decodeIfPresent(String.self, forKey: .legacyChemicalGroup)
        // Accept the ISO-8601 string this type now writes, and still read a
        // numeric/strategy-decoded date so snapshots already persisted by an
        // earlier build keep loading.
        if let raw = try? c.decodeIfPresent(String.self, forKey: .capturedAt) {
            capturedAt = Self.parseCapturedAt(raw)
        } else {
            capturedAt = try? c.decodeIfPresent(Date.self, forKey: .capturedAt)
        }
        appliedRate = try c.decodeIfPresent(Double.self, forKey: .appliedRate)
        appliedRateUnit = try c.decodeIfPresent(String.self, forKey: .appliedRateUnit)
        appliedRateBasis = try c.decodeIfPresent(String.self, forKey: .appliedRateBasis)
        rateEntryMethod = try c.decodeIfPresent(String.self, forKey: .rateEntryMethod)
        rateRangeMin = try c.decodeIfPresent(Double.self, forKey: .rateRangeMin)
        rateRangeMax = try c.decodeIfPresent(Double.self, forKey: .rateRangeMax)
    }

    /// Records what was actually applied, and where the rate came from.
    ///
    /// Returns a COPY: the saved chemical's own confirmed rate is never
    /// touched, which is what keeps a stored `2–3 L/100 L` band intact after a
    /// spray goes out at 2.5.
    nonisolated func recordingApplied(
        rate: Double,
        unit: String,
        basis: ChemicalDefaultRateBasis,
        entryMethod: String,
        confirmedRange: (min: Double, max: Double)? = nil
    ) -> ChemicalLineSnapshot {
        var copy = self
        copy.appliedRate = rate
        copy.appliedRateUnit = unit
        copy.appliedRateBasis = basis.rawValue
        copy.rateEntryMethod = entryMethod
        copy.rateRangeMin = confirmedRange?.min
        copy.rateRangeMax = confirmedRange?.max
        return copy
    }

    /// Whether this snapshot carries anything the Resistance Engine could use.
    nonisolated var hasResistanceData: Bool {
        !activityGroupCodes.isEmpty || activeIngredients.contains { !$0.name.isEmpty }
    }

    /// Freeze a saved chemical's current intelligence onto a spray line.
    ///
    /// Returns `nil` when there is genuinely nothing structured to record, so a
    /// legacy line stays honestly empty rather than carrying a snapshot that
    /// implies knowledge VineTrack never had.
    static func capture(
        from intelligence: ChemicalIntelligence?,
        legacyChemicalGroup: String,
        savedChemicalId: String? = nil,
        productName: String? = nil,
        at date: Date = Date()
    ) -> ChemicalLineSnapshot? {
        guard let intelligence, !intelligence.isEmpty else {
            // Nothing structured. Preserve only the displayed legacy string if
            // there was one, so the historical record still reproduces.
            let trimmed = legacyChemicalGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ChemicalLineSnapshot(
                savedChemicalId: savedChemicalId,
                productName: productName,
                verificationStatus: .unverified,
                schemaVersion: 0,
                activityGroupTableVersion: 0,
                legacyChemicalGroup: trimmed,
                capturedAt: date
            )
        }
        return ChemicalLineSnapshot(
            savedChemicalId: savedChemicalId,
            productName: productName,
            activeIngredients: intelligence.activeIngredients,
            activityGroupCodes: intelligence.activityGroupCodes,
            // The RESOLVED status, not the stored one: a spray must never claim
            // its product was verified when the evidence said otherwise.
            verificationStatus: intelligence.resolvedVerificationStatus,
            registrationIdentityKey: intelligence.registration?.identityKey,
            countryCode: intelligence.registration?.countryCode,
            schemaVersion: intelligence.schemaVersion,
            activityGroupTableVersion: intelligence.activityGroupTableVersion,
            legacyChemicalGroup: legacyChemicalGroup.isEmpty
                ? intelligence.legacyChemicalGroup
                : legacyChemicalGroup,
            capturedAt: date
        )
    }
}

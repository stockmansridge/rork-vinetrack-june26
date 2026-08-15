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
        capturedAt: Date? = nil
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
        capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt)
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

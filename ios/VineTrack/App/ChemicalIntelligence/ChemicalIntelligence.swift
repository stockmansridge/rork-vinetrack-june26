import Foundation

/// The structured, verification-aware chemical record.
///
/// This aggregate replaces the resistance-critical role of the free-text
/// `chemical_group` column. It answers, in machine-readable form:
///
/// - What exact product is this?          → `registration`
/// - Which actives does it contain?       → `activeIngredients`
/// - At what concentration?               → each active's concentration
/// - Which activity group per active?     → each active's `activityGroup`
/// - What rate basis does the label use?  → `labelRateBases` / `registeredUses`
/// - Is any of this actually verified?    → `verification`
///
/// It is stored ALONGSIDE the legacy scalar columns, never instead of them, so
/// old app builds and the existing API keep working untouched while the
/// structured model becomes the authority.
nonisolated struct ChemicalIntelligence: Codable, Sendable, Hashable {

    /// Schema version of this payload. Stamped into spray snapshots so a
    /// historical record says which contract produced it.
    static let currentSchemaVersion: Int = 1

    /// Actives and their groups — the heart of the model.
    var activeIngredients: [ChemicalActiveIngredient]
    /// Country-scoped registered identity.
    var registration: ChemicalRegistration?
    /// Trust state and its evidence.
    var verification: ChemicalVerification
    /// Registered crop + target + rate combinations.
    var registeredUses: [ChemicalRegisteredUse]
    /// Product category key, aligned with the existing `product_category`
    /// vocabulary (fungicide, herbicide, insecticide, adjuvant, …).
    var productCategory: String
    /// Version of `AuthoritativeActivityGroups` that judged this record.
    var activityGroupTableVersion: Int
    /// Schema version of this payload.
    var schemaVersion: Int

    init(
        activeIngredients: [ChemicalActiveIngredient] = [],
        registration: ChemicalRegistration? = nil,
        verification: ChemicalVerification = ChemicalVerification(),
        registeredUses: [ChemicalRegisteredUse] = [],
        productCategory: String = "",
        activityGroupTableVersion: Int = AuthoritativeActivityGroups.tableVersion,
        schemaVersion: Int = ChemicalIntelligence.currentSchemaVersion
    ) {
        self.activeIngredients = activeIngredients
        self.registration = registration
        self.verification = verification
        self.registeredUses = registeredUses
        self.productCategory = productCategory
        self.activityGroupTableVersion = activityGroupTableVersion
        self.schemaVersion = schemaVersion
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case activeIngredients = "active_ingredients"
        case registration
        case verification
        case registeredUses = "registered_uses"
        case productCategory = "product_category"
        case activityGroupTableVersion = "activity_group_table_version"
        case schemaVersion = "schema_version"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeIngredients = try c.decodeIfPresent([ChemicalActiveIngredient].self, forKey: .activeIngredients) ?? []
        registration = try c.decodeIfPresent(ChemicalRegistration.self, forKey: .registration)
        verification = try c.decodeIfPresent(ChemicalVerification.self, forKey: .verification) ?? ChemicalVerification()
        registeredUses = try c.decodeIfPresent([ChemicalRegisteredUse].self, forKey: .registeredUses) ?? []
        productCategory = try c.decodeIfPresent(String.self, forKey: .productCategory) ?? ""
        activityGroupTableVersion = try c.decodeIfPresent(Int.self, forKey: .activityGroupTableVersion) ?? 0
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
    }

    // MARK: - Derived resistance data

    /// Every activity group across every active, de-duplicated and ordered.
    ///
    /// A Tebuconazole + Azoxystrobin product returns FRAC 3 and FRAC 11 as two
    /// separate members. This is the collection the Resistance Engine reads.
    nonisolated var activityGroups: [ChemicalActivityGroup] {
        activeIngredients.activityGroups
    }

    /// Bare codes for the queryable `activity_groups text[]` column:
    /// `["3", "11"]` — never `["3 + 11"]`.
    nonisolated var activityGroupCodes: [String] { activityGroups.codes }

    /// Distinct label rate bases across all registered uses.
    nonisolated var labelRateBases: [ChemicalLabelRateBasis] { registeredUses.rateBases }

    /// The trust level the evidence actually supports.
    ///
    /// Always prefer this over `verification.status`: it re-derives the claim
    /// from the actives, the registration and any conflicts, so a stale or
    /// over-optimistic stored status cannot promote a product.
    nonisolated var resolvedVerificationStatus: ChemicalVerificationStatus {
        verification.resolvedStatus(
            actives: activeIngredients,
            hasRegistration: registration?.isAuthoritativeIdentity ?? false
        )
    }

    /// Whether the future Resistance Engine may use these groups without
    /// qualifying them to the operator.
    nonisolated var isResistanceDependable: Bool {
        resolvedVerificationStatus.isResistanceDependable
    }

    /// Whether anything at all has been structured yet.
    nonisolated var isEmpty: Bool {
        activeIngredients.isEmpty && registration == nil && registeredUses.isEmpty
    }

    // MARK: - Legacy projections (Phase 3)

    /// `"3 + 11"` — derived FROM `activityGroups` purely so older app builds
    /// and the existing API keep rendering something familiar.
    ///
    /// Write it to the legacy column; never read it back for calculation.
    nonisolated var legacyChemicalGroup: String {
        activityGroups.legacyGroupProjection
    }

    /// `"Tebuconazole 200 g/L + Azoxystrobin 120 g/L"` — the legacy
    /// `active_ingredient` display projection.
    nonisolated var legacyActiveIngredient: String {
        activeIngredients.legacyActiveIngredientProjection
    }

    // MARK: - Construction

    /// Builds a candidate record from a pre-Chemical-Intelligence chemical.
    ///
    /// It reads the old free-text fields to SEED the audit, and marks the
    /// result `.needsMatch` with a `.legacyRecord` source. Groups parsed out of
    /// a typed string are candidates, tagged `.legacyRecord`, so they can never
    /// satisfy `hasAuthoritativeGroup` and the product can never drift into
    /// Verified without a human confirming it.
    ///
    /// Existing chemicals therefore keep loading and displaying exactly as they
    /// did, while becoming visible to the audit as unmatched.
    static func legacySeed(
        activeIngredientText: String,
        chemicalGroupText: String,
        modeOfActionText: String,
        productCategory: String,
        manufacturer: String,
        countryCode: String
    ) -> ChemicalIntelligence {
        let scheme = ChemicalActivityGroupScheme.implied(byProductCategory: productCategory)
        // Mode of action ("11 (QoI / Strobilurin)") is usually a better source
        // of a code than the chemical group free-text, so try it first.
        var candidates = ChemicalActivityGroup.parseLegacyText(modeOfActionText, assumedScheme: scheme)
        if candidates.isEmpty {
            candidates = ChemicalActivityGroup.parseLegacyText(chemicalGroupText, assumedScheme: scheme)
        }

        let names = splitActiveNames(activeIngredientText)
        var actives: [ChemicalActiveIngredient] = []
        if names.isEmpty {
            // No actives recorded at all: still surface the candidate groups so
            // the audit can see the product exists and needs matching.
            actives = candidates.map { group in
                ChemicalActiveIngredient(
                    name: "",
                    activityGroup: group,
                    groupSource: .legacyRecord,
                    identitySource: .legacyRecord
                )
            }
        } else {
            for (index, name) in names.enumerated() {
                // Pair actives with candidate groups positionally ONLY when the
                // counts line up exactly. A 2-active product with one parsed
                // group tells us nothing about which active owns it, so we
                // attach nothing rather than attach it to the wrong one.
                let group = names.count == candidates.count ? candidates[index] : nil
                actives.append(
                    ChemicalActiveIngredient(
                        name: name,
                        activityGroup: group,
                        groupSource: group == nil ? nil : .legacyRecord,
                        identitySource: .legacyRecord
                    )
                )
            }
        }

        let registration = countryCode.isEmpty && manufacturer.isEmpty
            ? nil
            : ChemicalRegistration(countryCode: countryCode, registrant: manufacturer)

        return ChemicalIntelligence(
            activeIngredients: actives,
            registration: registration,
            verification: .legacy(),
            registeredUses: [],
            productCategory: productCategory,
            activityGroupTableVersion: 0
        )
    }

    /// Splits a legacy free-text active ingredient field into candidate names.
    ///
    /// Handles `"Tebuconazole 200 g/L + Azoxystrobin 120 g/L"` and the `&`, `,`
    /// and `/` variants people type. Concentrations are stripped from the name
    /// but deliberately NOT parsed into `concentration`: a legacy string is not
    /// evidence of a label value.
    static func splitActiveNames(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: "+&,;"))
        var out: [String] = []
        for part in parts {
            let name = stripConcentration(part)
            guard !name.isEmpty else { continue }
            out.append(name)
        }
        return out
    }

    /// `"Tebuconazole 200 g/L"` → `"Tebuconazole"`.
    private static func stripConcentration(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cut at the first digit that begins a concentration token.
        if let range = value.rangeOfCharacter(from: .decimalDigits) {
            let prefix = value[value.startIndex..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Only cut when a real name precedes the number, so an active whose
            // name legitimately contains a digit (e.g. "2,4-D") survives.
            if prefix.count >= 4 { value = prefix }
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " -–—()"))
    }
}

/// The contract the future Resistance Rules Engine consumes.
///
/// Deliberately a flat, self-contained projection: the engine never touches a
/// `SavedChemical`, never parses `"Group 3 + 11"`, and never reads label text.
/// If it can be answered from this struct, the engine can answer it.
nonisolated struct ChemicalResistanceProfile: Codable, Sendable, Hashable, Identifiable {
    /// The saved chemical this profile describes.
    let productId: UUID
    let productName: String
    /// Registered identity string, e.g. `"AU:apvma:62764"`. `nil` when the
    /// product has never been matched.
    let registrationIdentityKey: String?
    let countryCode: String
    let activeIngredients: [ChemicalActiveIngredient]
    /// Scheme-qualified group identifiers, e.g. `["frac:3", "frac:11"]`.
    let activityGroups: [ChemicalActivityGroup]
    let verificationStatus: ChemicalVerificationStatus
    let registeredUses: [ChemicalRegisteredUse]
    let labelRateBases: [ChemicalLabelRateBasis]
    /// `schemaVersion.activityGroupTableVersion`, so a future engine run can
    /// tell which contract and which classification table produced this.
    let sourceVersion: String

    nonisolated var id: UUID { productId }

    /// Bare codes: `["3", "11"]`.
    nonisolated var activityGroupCodes: [String] { activityGroups.codes }

    /// Whether the engine may rely on these groups without qualification.
    nonisolated var isDependable: Bool { verificationStatus.isResistanceDependable }

    /// Typed targets the product is registered against on grapevines.
    nonisolated var viticulturalTargets: [SprayTarget] { registeredUses.viticulturalTargets }
}

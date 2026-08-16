import Foundation
import Testing
@testable import VineTrack

/// Contract tests for the ONE canonical Chemical Intelligence capture path.
///
/// The Android suite `ChemicalSnapshotCaptureTest` asserts the same fixtures and
/// the same outcomes, so a spray created on either platform freezes an identical
/// shape into the shared `tanks` JSONB.
///
/// Everything here protects four rules:
///
///  1. A NEW application freezes the chemistry that exists NOW.
///  2. A template is configuration, so instantiating it re-reads the store.
///  3. An unresolvable product stays honestly unresolved — never invented.
///  4. A completed application never changes because the store changed.
struct ChemicalSnapshotCaptureTests {

    // MARK: - Fixtures

    private func frac(_ code: String) -> ChemicalActivityGroup {
        ChemicalActivityGroup(scheme: .frac, code: code)
    }

    private func active(
        _ name: String,
        _ concentration: Double?,
        group: ChemicalActivityGroup?
    ) -> ChemicalActiveIngredient {
        ChemicalActiveIngredient(
            name: name,
            concentration: concentration,
            concentrationUnit: concentration == nil ? nil : .gramsPerLitre,
            activityGroup: group,
            groupSource: group == nil ? nil : .authoritativeClassification,
            identitySource: .officialRegister
        )
    }

    private func verifiedEvidence(
        conflicts: [ChemicalVerificationConflict] = []
    ) -> ChemicalVerification {
        ChemicalVerification(
            status: .verified,
            sources: [
                ChemicalDataSource(kind: .officialRegister, name: "APVMA PUBCRIS"),
                AuthoritativeActivityGroups.source()
            ],
            verifiedAt: Date(timeIntervalSince1970: 1_786_000_000),
            conflicts: conflicts
        )
    }

    /// Azoxystrobin, FRAC 11, verified — the reference product for this stage.
    private func group11Intel(
        number: String = "62764",
        conflicts: [ChemicalVerificationConflict] = []
    ) -> ChemicalIntelligence {
        ChemicalIntelligence(
            activeIngredients: [active("Azoxystrobin", 250, group: frac("11"))],
            registration: ChemicalRegistration(
                countryCode: "AU",
                scheme: .apvma,
                registrationNumber: number,
                registrant: "Example Crop Science",
                registeredProductName: "Example Fungicide"
            ),
            verification: verifiedEvidence(conflicts: conflicts),
            productCategory: "fungicide"
        )
    }

    /// The SAME product legitimately re-verified as FRAC 3.
    private func group3Intel() -> ChemicalIntelligence {
        ChemicalIntelligence(
            activeIngredients: [active("Tebuconazole", 200, group: frac("3"))],
            registration: ChemicalRegistration(
                countryCode: "AU",
                scheme: .apvma,
                registrationNumber: "62764",
                registrant: "Example Crop Science",
                registeredProductName: "Example Fungicide"
            ),
            verification: verifiedEvidence(),
            productCategory: "fungicide"
        )
    }

    private let chemId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherChemId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let at = Date(timeIntervalSince1970: 1_786_000_000)

    private func savedChemical(
        id: UUID? = nil,
        name: String = "Example Fungicide",
        activeIngredient: String = "",
        chemicalGroup: String = "",
        modeOfAction: String = "",
        isActive: Bool = true,
        intelligence: ChemicalIntelligence? = nil
    ) -> SavedChemical {
        SavedChemical(
            id: id ?? chemId,
            name: name,
            chemicalGroup: chemicalGroup,
            manufacturer: "Example Crop Science",
            activeIngredient: activeIngredient,
            modeOfAction: modeOfAction,
            productCategory: "fungicide",
            isActive: isActive,
            chemicalIntelligence: intelligence
        )
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Phase 15: the normal Spray Calculator path

    @Test("A new application freezes id, name, identity, active, group and resolved status")
    func newApplicationFreezesEverything() throws {
        let chem = savedChemical(intelligence: group11Intel())

        let snapshot = try #require(
            ChemicalSnapshotCapture.captureForNewApplication(
                savedChemicalId: chem.id,
                productName: chem.name,
                library: [chem],
                at: at
            ).snapshot
        )

        #expect(snapshot.savedChemicalId == chemId.uuidString)
        #expect(snapshot.productName == "Example Fungicide")
        #expect(snapshot.registrationIdentityKey == "AU:apvma:62764")
        #expect(snapshot.countryCode == "AU")
        #expect(snapshot.activeIngredients.map(\.name) == ["Azoxystrobin"])
        #expect(snapshot.activityGroupCodes == ["11"])
        #expect(snapshot.verificationStatus == .verified)
        #expect(snapshot.capturedAt == at)
        #expect(snapshot.hasResistanceData)
    }

    @Test("Reclassifying the product later never restates a recorded application")
    func historicalApplicationIsImmutable() throws {
        let september = savedChemical(intelligence: group11Intel())
        let historical = try #require(
            ChemicalSnapshotCapture.captureForNewApplication(
                savedChemicalId: september.id,
                productName: september.name,
                library: [september],
                at: at
            ).snapshot
        )

        // The Chemical Store is corrected months later.
        let november = savedChemical(intelligence: group3Intel())
        let fresh = try #require(
            ChemicalSnapshotCapture.captureForNewApplication(
                savedChemicalId: november.id,
                productName: november.name,
                library: [november],
                at: at.addingTimeInterval(60 * 60 * 24 * 60)
            ).snapshot
        )

        #expect(historical.activityGroupCodes == ["11"])
        #expect(fresh.activityGroupCodes == ["3"])
    }

    @Test("Resolution reports how the product was matched")
    func resolutionReportsMatchKind() {
        let chem = savedChemical(intelligence: group11Intel())

        #expect(
            ChemicalSnapshotCapture.resolve(
                savedChemicalId: chemId,
                productName: nil,
                in: [chem]
            ).match == .identifier
        )
        #expect(
            ChemicalSnapshotCapture.resolve(
                savedChemicalId: nil,
                productName: "example fungicide",
                in: [chem]
            ).match == .exactName
        )
        #expect(
            ChemicalSnapshotCapture.resolve(
                savedChemicalId: nil,
                productName: nil,
                registrationIdentityKey: "AU:apvma:62764",
                in: [chem]
            ).match == .registrationIdentity
        )
    }

    // MARK: - Phase 16: template instantiation

    @Test("Instantiating a template snapshots the product's current chemistry")
    func templateInstantiationRefreshesChemistry() throws {
        // A template recorded in September, when the product was FRAC 11.
        let septemberLine = SprayChemical(
            name: "Example Fungicide",
            ratePerHa: 1500,
            savedChemicalId: chemId,
            chemicalSnapshot: ChemicalSnapshotCapture.capture(
                savedChemical(intelligence: group11Intel()),
                at: at
            )
        )
        // By November the product has legitimately been re-verified as FRAC 3.
        let november = [savedChemical(intelligence: group3Intel())]

        let instantiated = try #require(
            ChemicalSnapshotCapture.captureForNewApplication(
                savedChemicalId: septemberLine.savedChemicalId,
                productName: septemberLine.name,
                library: november,
                at: at.addingTimeInterval(60 * 60 * 24 * 60)
            ).snapshot
        )

        // The template's configuration was reusable; its chemistry was not.
        #expect(instantiated.activityGroupCodes == ["3"])
        // And the completed September application is untouched.
        #expect(septemberLine.chemicalSnapshot?.activityGroupCodes == ["11"])
    }

    @Test("A template carries product identity forward, not its frozen chemistry")
    func templateCarriesIdentityNotChemistry() throws {
        let templateSnapshot = try #require(
            ChemicalSnapshotCapture.capture(savedChemical(intelligence: group11Intel()), at: at)
        )
        let november = [savedChemical(intelligence: group3Intel())]

        let resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: templateSnapshot.savedChemicalId.flatMap(UUID.init(uuidString:)),
            productName: templateSnapshot.productName,
            registrationIdentityKey: templateSnapshot.registrationIdentityKey,
            library: november,
            at: at
        )

        #expect(resolution.isResolved)
        #expect(resolution.savedChemicalId == chemId)
        #expect(resolution.snapshot?.activityGroupCodes == ["3"])
    }

    // MARK: - Phase 17: template pointing at a missing chemical

    @Test("A template referencing a deleted chemical invents no verified chemistry")
    func templateWithMissingChemicalStaysHonest() {
        let resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: otherChemId,
            productName: "Vanished Fungicide",
            library: [],
            at: at
        )

        #expect(!resolution.isResolved)
        #expect(resolution.match == .unresolved)
        #expect(resolution.savedChemicalId == nil)
        // No legacy text either, so there is genuinely nothing to record.
        #expect(resolution.snapshot == nil)
    }

    @Test("An unresolved product's legacy group text stays legacy evidence only")
    func unresolvedKeepsLegacyTextOnly() throws {
        let resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: nil,
            productName: "Unknown Mixture",
            legacyChemicalGroup: "Group 3 + 11",
            library: [],
            at: at
        )

        let snapshot = try #require(resolution.snapshot)
        #expect(snapshot.legacyChemicalGroup == "Group 3 + 11")
        // Preserved for faithful display — never promoted to structured groups.
        #expect(snapshot.activityGroupCodes.isEmpty)
        #expect(snapshot.activeIngredients.isEmpty)
        #expect(snapshot.verificationStatus == .unverified)
        #expect(snapshot.schemaVersion == 0)
        #expect(snapshot.activityGroupTableVersion == 0)
        #expect(!snapshot.hasResistanceData)
        #expect(snapshot.savedChemicalId == nil)
    }

    // MARK: - Phase 18: CSV import with a reliable match

    @Test("An imported line with a reliable match equals a calculator spray")
    func importedMatchesCalculator() {
        let chem = savedChemical(intelligence: group11Intel())

        let calculator = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: chemId,
            productName: "Example Fungicide",
            library: [chem],
            at: at
        ).snapshot
        // The importer resolves an exact, unique name to the same product.
        let imported = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: nil,
            productName: "Example Fungicide",
            library: [chem],
            at: at
        ).snapshot

        #expect(calculator == imported)
    }

    @Test("An imported snapshot survives persist and reload unchanged")
    func importedSnapshotRoundTrips() throws {
        let chem = savedChemical(intelligence: group11Intel())
        let line = SprayChemical(
            name: "Example Fungicide",
            ratePerHa: 1500,
            savedChemicalId: chemId,
            chemicalSnapshot: ChemicalSnapshotCapture.captureForNewApplication(
                savedChemicalId: nil,
                productName: "Example Fungicide",
                library: [chem],
                at: at
            ).snapshot
        )

        let reloaded = try roundTrip(line)

        #expect(reloaded.chemicalSnapshot == line.chemicalSnapshot)
        #expect(reloaded.chemicalSnapshot?.activityGroupCodes == ["11"])
        #expect(reloaded.ratePerHa == 1500)
    }

    // MARK: - Phase 19: CSV import without a reliable match

    @Test("An ambiguous name is left unresolved rather than guessed")
    func ambiguousNameIsUnresolved() {
        // Two library entries share the name — picking either would attach one
        // product's chemistry to another product's spray.
        let library = [
            savedChemical(id: chemId, intelligence: group11Intel()),
            savedChemical(id: otherChemId, intelligence: group3Intel())
        ]

        let resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: nil,
            productName: "Example Fungicide",
            library: library,
            at: at
        )

        #expect(!resolution.isResolved)
        #expect(resolution.snapshot == nil)
    }

    @Test("A partial name never attaches authoritative chemistry")
    func partialNameNeverMatches() {
        let library = [savedChemical(intelligence: group11Intel())]

        // "Example" is a prefix of "Example Fungicide" — deliberately not a match.
        let resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: nil,
            productName: "Example",
            library: library,
            at: at
        )

        #expect(!resolution.isResolved)
        #expect(resolution.snapshot == nil)
    }

    @Test("An unresolved import preserves the line and its rate")
    func unresolvedImportPreservesLine() throws {
        let resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: nil,
            productName: "Mystery Product",
            legacyChemicalGroup: "Group 3 + 11",
            library: [],
            at: at
        )
        let line = SprayChemical(
            name: "Mystery Product",
            ratePerHa: 2000,
            unit: .litres,
            savedChemicalId: resolution.savedChemicalId,
            chemicalSnapshot: resolution.snapshot
        )

        // The application is never lost just because its chemistry is unknown.
        #expect(line.name == "Mystery Product")
        #expect(line.ratePerHa == 2000)
        #expect(line.savedChemicalId == nil)
        let snapshot = try #require(line.chemicalSnapshot)
        #expect(snapshot.legacyChemicalGroup == "Group 3 + 11")
        #expect(snapshot.activeIngredients.isEmpty)
        #expect(snapshot.verificationStatus == .unverified)
    }

    // MARK: - Phase 20: offline creation

    @Test("An offline spray keeps the chemistry captured at application time")
    func offlineSprayKeepsCapturedChemistry() throws {
        // Offline: the device knows the product as FRAC 11.
        let cached = savedChemical(intelligence: group11Intel())
        let offlineLine = SprayChemical(
            name: "Example Fungicide",
            ratePerHa: 1500,
            savedChemicalId: chemId,
            chemicalSnapshot: ChemicalSnapshotCapture.captureForNewApplication(
                savedChemicalId: chemId,
                productName: "Example Fungicide",
                library: [cached],
                at: at
            ).snapshot
        )

        // The queued payload is serialised, the store changes elsewhere, then the
        // device replays tomorrow. Replay carries the payload verbatim.
        let replayed = try roundTrip(offlineLine)

        #expect(replayed.chemicalSnapshot?.activityGroupCodes == ["11"])
        #expect(replayed.chemicalSnapshot?.capturedAt == at)
        #expect(replayed.chemicalSnapshot == offlineLine.chemicalSnapshot)
    }

    // MARK: - Phase 12: historical records

    @Test("A historical line without chemistry keeps the absence")
    func historicalLineKeepsAbsence() throws {
        let legacyLine = SprayChemical(name: "Old product", ratePerHa: 2000)

        let reloaded = try roundTrip(legacyLine)

        // Never back-filled from today's store: the Resistance Engine must be
        // able to say "intelligence unavailable" rather than fabricate certainty.
        #expect(reloaded.chemicalSnapshot == nil)
        #expect(reloaded.name == "Old product")
    }

    // MARK: - Phase 13: resolved verification at capture time

    @Test("Capture records the resolved status, not the stored claim")
    func captureUsesResolvedStatus() throws {
        // The stored row says verified, but the evidence now carries a conflict.
        let conflicted = group11Intel(
            conflicts: [
                ChemicalVerificationConflict(
                    field: "activity_group",
                    activeIngredientName: "Azoxystrobin",
                    extractedValue: "3",
                    authoritativeValue: "11"
                )
            ]
        )
        let chem = savedChemical(intelligence: conflicted)
        #expect(chem.chemicalIntelligence?.verification.status == .verified)

        let snapshot = try #require(ChemicalSnapshotCapture.capture(chem, at: at))

        #expect(snapshot.verificationStatus == .conflict)
    }

    @Test("A legacy-only product freezes an honest needs-match reading")
    func legacyOnlyProductFreezesNeedsMatch() throws {
        let legacy = savedChemical(
            activeIngredient: "Azoxystrobin",
            chemicalGroup: "Group 11",
            modeOfAction: "11 (QoI)",
            intelligence: nil
        )

        let snapshot = try #require(ChemicalSnapshotCapture.capture(legacy, at: at))

        // Legacy text seeds the audit, but it is structurally incapable of
        // passing as verified.
        #expect(snapshot.verificationStatus == .needsMatch)
        #expect(snapshot.legacyChemicalGroup == "Group 11")
        #expect(snapshot.activeIngredients.map(\.name) == ["Azoxystrobin"])
        #expect(!snapshot.activeIngredients.contains { $0.hasAuthoritativeGroup })
    }

    // MARK: - Phase 21: every new-application constructor

    @Test("Every resolvable new-application line carries a canonical snapshot")
    func everyConstructorUsesTheCanonicalPath() {
        let chem = savedChemical(intelligence: group11Intel())
        let library = [chem]
        let canonical = ChemicalSnapshotCapture.capture(chem, at: at)

        // The four shapes a new application line arrives in: an explicit id
        // (calculator, manual sheet), a template's id, an importer's linked id,
        // and a name-only import row.
        let resolutions = [
            ChemicalSnapshotCapture.captureForNewApplication(
                savedChemicalId: chemId, productName: "Example Fungicide", library: library, at: at
            ),
            ChemicalSnapshotCapture.captureForNewApplication(
                savedChemicalId: chemId, productName: nil, library: library, at: at
            ),
            ChemicalSnapshotCapture.captureForNewApplication(
                savedChemicalId: chemId, productName: "example fungicide", library: library, at: at
            ),
            ChemicalSnapshotCapture.captureForNewApplication(
                savedChemicalId: nil, productName: "Example Fungicide", library: library, at: at
            )
        ]

        for resolution in resolutions {
            #expect(resolution.isResolved)
            #expect(resolution.snapshot != nil)
            // One capture path means one shape — no per-screen drift.
            #expect(resolution.snapshot == canonical)
        }
    }

    @Test("An archived product still resolves by id, because the spray happened")
    func archivedProductStillResolves() {
        let archived = savedChemical(isActive: false, intelligence: group11Intel())

        let resolution = ChemicalSnapshotCapture.captureForNewApplication(
            savedChemicalId: chemId,
            productName: "Example Fungicide",
            library: [archived],
            at: at
        )

        #expect(resolution.isResolved)
        #expect(resolution.snapshot?.activityGroupCodes == ["11"])
    }

    // MARK: - Phase 14: cross-platform JSON

    @Test("The snapshot serialises the shared snake_case shape")
    func snapshotSerialisesSharedShape() throws {
        let chem = savedChemical(intelligence: group11Intel())
        let snapshot = try #require(ChemicalSnapshotCapture.capture(chem, at: at))

        let data = try JSONEncoder().encode(snapshot)
        let encoded = try #require(String(data: data, encoding: .utf8))

        for key in [
            "\"saved_chemical_id\"",
            "\"product_name\"",
            "\"active_ingredients\"",
            "\"activity_groups\"",
            "\"verification_status\"",
            "\"registration_identity_key\"",
            "\"country_code\"",
            "\"schema_version\"",
            "\"activity_group_table_version\"",
            "\"captured_at\""
        ] {
            #expect(encoded.contains(key), "missing \(key) in \(encoded)")
        }
        // Status travels as its raw string, and captured_at as an ISO-8601
        // string — the same two shapes Android writes into the same column.
        #expect(encoded.contains("\"verified\""))
        #expect(encoded.contains(ChemicalLineSnapshot.capturedAtFormatter.string(from: at)))

        #expect(try roundTrip(snapshot) == snapshot)
    }
}

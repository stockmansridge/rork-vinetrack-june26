import Foundation
import Testing
@testable import VineTrack

/// Herbicide classification v2 — current numeric groups + legacy equivalence.
///
/// # What this pins
///
/// Australia replaced the alphabetical herbicide mode-of-action codes with the
/// globally aligned NUMERIC system. Labels began carrying numbers in 2022 and
/// the transition completed in 2024, so the code a grower reads on a current
/// Australian herbicide label is "Group 14", not "Group E" and not "Group G".
///
/// The table held the OLD global HRAC letters, which produced a FALSE CONFLICT
/// on every herbicide: the label and the lookup said the same thing in two
/// different alphabets and the app reported them as sources that disagreed. A
/// false alarm about a resistance group is the most expensive kind of wrong
/// answer this app can give.
///
/// These assertions are deliberately written against the RULE rather than one
/// product, and are mirrored test-for-test in the `chemical-info-lookup` edge
/// function (`activity_groups_v2_test.ts`) and on Android
/// (`AuthoritativeActivityGroupsV2Test.kt`). All three must agree — the whole
/// point is that a product's activity group has one answer, not three.
@Suite("Authoritative activity groups — herbicide v2")
struct AuthoritativeActivityGroupsV2Tests {

    private func hrac(_ code: String) -> ChemicalActivityGroup {
        ChemicalActivityGroup(scheme: .hrac, code: code, commonName: nil)
    }

    private func reconcile(
        _ active: String,
        _ code: String
    ) -> (group: ChemicalActivityGroup?, source: ChemicalDataSourceKind?, conflict: ChemicalVerificationConflict?) {
        AuthoritativeActivityGroups.reconcile(
            activeNamed: active,
            extracted: hrac(code),
            extractedSource: .aiInterpretation
        )
    }

    private var herbicides: [String] { AuthoritativeActivityGroups.herbicideActiveNames }

    @Test("the reference table version is bumped so a re-verification can tell which revision judged a product")
    func tableVersionBumped() {
        #expect(AuthoritativeActivityGroups.tableVersion == 2)
    }

    @Test("EVERY herbicide classifies to a CURRENT numeric group — no letters survive")
    func everyHerbicideIsNumeric() {
        #expect(!herbicides.isEmpty, "the table must still classify herbicides")
        for active in herbicides {
            let code = AuthoritativeActivityGroups.group(forActiveNamed: active)?.code
            #expect(code != nil, "\(active) lost its classification")
            #expect(
                code?.allSatisfy { $0.isNumber } == true,
                "\(active) still carries a legacy alphabetical code \"\(code ?? "")\" — current Australian labels print numbers"
            )
        }
    }

    @Test("every herbicide agrees with each of its own legacy codes, and none is served as the answer")
    func legacyCodesAgree() {
        for active in herbicides {
            guard let current = AuthoritativeActivityGroups.group(forActiveNamed: active)?.code else {
                continue
            }
            let legacy = AuthoritativeActivityGroups.legacyCodes(forActiveNamed: active)
            #expect(!legacy.isEmpty, "\(active) records no legacy code to reconcile against")

            for code in legacy {
                let outcome = reconcile(active, code)
                #expect(
                    outcome.conflict == nil,
                    "\(active): legacy code \"\(code)\" must not read as a source disagreement"
                )
                // The CURRENT group is what a grower sees — never the historical code.
                #expect(
                    outcome.group?.code == current,
                    "\(active): the current numeric group must be served, not the legacy code"
                )
            }
        }
    }

    @Test("the current value agrees with itself, however the source decorates it")
    func currentValueAgreesWithItself() {
        for active in herbicides {
            guard let current = AuthoritativeActivityGroups.group(forActiveNamed: active)?.code else {
                continue
            }
            for written in [current, "Group \(current)", "\(current) (whatever)"] {
                #expect(
                    reconcile(active, written).conflict == nil,
                    "\(active): \"\(written)\" is the current group written differently, not a conflict"
                )
            }
        }
    }

    @Test("a GENUINELY different group still conflicts — the check is not simply switched off")
    func realDisagreementStillConflicts() {
        for active in herbicides {
            guard let current = AuthoritativeActivityGroups.group(forActiveNamed: active)?.code else {
                continue
            }
            let wrong = current == "2" ? "9" : "2"
            if AuthoritativeActivityGroups.legacyCodes(forActiveNamed: active).contains(wrong) { continue }

            let outcome = reconcile(active, wrong)
            #expect(
                outcome.conflict != nil,
                "\(active): group \(wrong) is a real disagreement and must be reported"
            )
            #expect(
                outcome.group?.code == current,
                "the authoritative group is served even while the conflict stands"
            )
        }
    }

    @Test("a PPO inhibitor is Group 14, and its legacy 'E' and 'G' codes raise no conflict")
    func ppoInhibitorsAreGroup14() {
        // The two legacy alphabets disagree with each other about the letter:
        // "E" was PPO globally, "G" was PPO in Australia. Both mean Group 14,
        // which is exactly why equivalence is decided per ACTIVE, not per letter.
        let ppo = herbicides.filter {
            AuthoritativeActivityGroups.group(forActiveNamed: $0)?.code == "14"
        }
        #expect(!ppo.isEmpty, "the table must classify PPO inhibitors")

        for active in ppo {
            for legacy in ["E", "G", "Group E", "HRAC E"] {
                #expect(
                    reconcile(active, legacy).conflict == nil,
                    "\(active): legacy \"\(legacy)\" must not create a Group 14-versus-letter conflict"
                )
            }
        }
    }

    @Test("legacy letters are NOT decodable across actives — equivalence never leaks between chemistries")
    func legacyLettersDoNotLeak() throws {
        // "E" is a legacy code for flumioxazin (PPO / 14). It is NOT a legacy
        // code for an ALS inhibitor, so offering it there is still a real
        // disagreement. A per-LETTER mapping would silently accept it.
        let als = try #require(
            herbicides.first { AuthoritativeActivityGroups.group(forActiveNamed: $0)?.code == "2" }
        )

        #expect(
            !AuthoritativeActivityGroups.legacyCodes(forActiveNamed: als).contains("E"),
            "an ALS inhibitor must not inherit a PPO inhibitor's legacy letter"
        )
        #expect(
            reconcile(als, "E").conflict != nil,
            "a legacy letter belonging to another chemistry is a genuine conflict"
        )
    }

    @Test("equivalence requires the SAME scheme — FRAC 14 is not HRAC 14")
    func schemeMatters() {
        #expect(
            !AuthoritativeActivityGroups.groupsAreEquivalent(
                activeNamed: "flumioxazin",
                hrac("14"),
                ChemicalActivityGroup(scheme: .frac, code: "14", commonName: nil)
            ),
            "a bare number is meaningless without its scheme"
        )
    }

    @Test("a formulation suffix inherits both the current group and its legacy codes")
    func saltFormsInherit() {
        #expect(
            AuthoritativeActivityGroups.group(forActiveNamed: "Glyphosate isopropylamine salt")?.code == "9"
        )
        #expect(
            AuthoritativeActivityGroups
                .legacyCodes(forActiveNamed: "Glyphosate isopropylamine salt")
                .contains("G"),
            "a salt form must reconcile against its parent's legacy codes too"
        )
        #expect(
            reconcile("Glyphosate isopropylamine salt", "M").conflict == nil,
            "the old Australian letter for glyphosate is not a disagreement"
        )
    }
}

import Foundation
import Testing
@testable import VineTrack

/// Phase 1 terminology close-out.
///
/// The restructure gave the operator two different kinds of thing — a reusable
/// **Program Step** and an applied **Spray** — but half the entry points still
/// said "template", which is the old vocabulary for a third concept that no
/// longer exists in the UI. These tests pin the replacement wording so a future
/// edit cannot quietly reintroduce it.
///
/// They deliberately test presentation only. `isTemplate`, `is_template` and
/// `SprayJobTemplateService` are the internal contract and are expected to keep
/// their names.
struct SprayProgramTerminologyTests {

    // MARK: - Nouns

    @Test("A reusable step is a Program Step, its collection is the Program")
    func nouns() {
        #expect(SprayProgramTerminology.programStep == "Program Step")
        #expect(SprayProgramTerminology.programSteps == "Program Steps")
        #expect(SprayProgramTerminology.program == "Program")
    }

    // MARK: - Actions

    @Test("Trip-start entry points read Plan from Program and One-off Spray")
    func entryPointActions() {
        #expect(SprayProgramTerminology.planFromProgram == "Plan from Program")
        #expect(SprayProgramTerminology.oneOffSpray == "One-off Spray")
    }

    @Test("Creating a reusable step is Add Program Step")
    func addProgramStep() {
        #expect(SprayProgramTerminology.addProgramStep == "Add Program Step")
    }

    @Test("Promoting an applied spray is Add to Program, and reads In Program once on")
    func addToProgram() {
        #expect(SprayProgramTerminology.addToProgram == "Add to Program")
        #expect(SprayProgramTerminology.inProgram == "In Program")
    }

    /// Reworded once portal Program Steps became editable on mobile.
    ///
    /// "Managed in Admin Portal" described a locked, portal-only object. The
    /// Program is a shared vineyard resource — both interfaces edit the same
    /// `spray_jobs` row — so the banner now explains the sync relationship
    /// instead of implying mobile is locked out.
    @Test("Portal-backed steps read Synced with Admin Portal, not Managed")
    func portalBanner() {
        #expect(SprayProgramTerminology.syncedWithAdminPortal == "Synced with Admin Portal")
        #expect(SprayProgramTerminology.portalSyncBanner == SprayProgramTerminology.syncedWithAdminPortal)
        #expect(!SprayProgramTerminology.allLabels.contains { $0.localizedCaseInsensitiveContains("Managed in") })
    }

    // MARK: - Composed copy

    @Test("Plan from Program subtitle counts available steps without saying template")
    func planSubtitleCountsSteps() {
        let none = SprayProgramTerminology.planFromProgramSubtitle(count: 0)
        let some = SprayProgramTerminology.planFromProgramSubtitle(count: 4)

        #expect(none.contains("Program Steps"))
        #expect(some.contains("Program Step"))
        #expect(some.contains("4"))
        #expect(!none.lowercased().contains("template"))
        #expect(!some.lowercased().contains("template"))
    }

    @Test("Picker copy names Program Steps")
    func pickerCopy() {
        #expect(SprayProgramTerminology.chooseProgramStepTitle == "Choose a Program Step")
        #expect(SprayProgramTerminology.noProgramStepsAvailable == "No Program Steps Available")
    }

    // MARK: - Import spreadsheet

    /// The blank import sheet is the one genuine "template" left in the product,
    /// and precisely because of that it must not use the word — otherwise
    /// "template" would carry two meanings on the same screen.
    @Test("The import spreadsheet is Download Import CSV, never a template")
    func importSpreadsheetWording() {
        #expect(SprayProgramTerminology.downloadImportCSV == "Download Import CSV")
        #expect(SprayProgramTerminology.importCSV == "Import CSV")
        #expect(!SprayProgramTerminology.downloadImportCSV.lowercased().contains("template"))
        #expect(!SprayProgramTerminology.importCSV.lowercased().contains("program step"))
    }

    // MARK: - Vocabulary sweep

    @Test("No operator-facing label vends the retired vocabulary")
    func noRetiredVocabulary() {
        let retired = ["template", "templates", "custom spray job", "start from template"]
        for label in SprayProgramTerminology.allLabels {
            let lowered = label.lowercased()
            for word in retired {
                #expect(!lowered.contains(word), "\"\(label)\" still uses retired wording \"\(word)\"")
            }
        }
    }

    @Test("Every vended label is non-empty")
    func labelsArePresent() {
        for label in SprayProgramTerminology.allLabels {
            #expect(!label.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Internal contract is untouched

    /// Wording changed; storage did not. A record promoted through the
    /// "Add to Program" toggle is still an `isTemplate` row, which is what the
    /// Program catalog reads.
    @Test("Add to Program still writes the isTemplate contract")
    func toggleStillWritesIsTemplate() {
        var record = SprayRecord(sprayReference: "Bud Burst Cover", tanks: [SprayTank()], isTemplate: false)
        #expect(record.isTemplate == false)

        record.isTemplate = true

        let steps = SprayProgramCatalog.steps(localRecords: [record], portalRecords: [])
        #expect(steps.count == 1)
        #expect(steps.first?.name == "Bud Burst Cover")
    }
}

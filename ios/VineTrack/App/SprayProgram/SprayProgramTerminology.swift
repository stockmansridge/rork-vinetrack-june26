import Foundation

/// Canonical operator-facing wording for the Spray Program.
///
/// The internal contract still says `isTemplate` / `SprayJobTemplateService` /
/// `is_template`, and it should — that is what the row actually is in storage.
/// What an operator reads, however, is one vocabulary and one only:
///
/// - a reusable step in the vineyard's spray program is a **Program Step**
/// - the collection of those steps is the **Program**
/// - taking a step into the calculator is **Plan from Program**
/// - a spray with no program step behind it is a **One-off Spray**
/// - promoting an applied spray into the program is **Add to Program**
///
/// The word "template" is reserved for exactly one thing that genuinely is a
/// blank form: the import spreadsheet, which is surfaced as
/// `downloadImportCSV`. Keeping these strings in one place is what lets the
/// tests prove the old vocabulary is gone rather than merely absent from the
/// files someone remembered to check.
nonisolated enum SprayProgramTerminology {

    // MARK: - Nouns

    /// A single reusable step in the spray program.
    static let programStep = "Program Step"
    /// The vineyard's collection of reusable steps.
    static let program = "Program"
    /// Plural of `programStep`.
    static let programSteps = "Program Steps"

    // MARK: - Actions

    /// Entry point that starts a spray from an existing Program Step.
    static let planFromProgram = "Plan from Program"
    /// Entry point that starts a spray with nothing pre-filled.
    static let oneOffSpray = "One-off Spray"
    /// Creates a new reusable Program Step.
    static let addProgramStep = "Add Program Step"
    /// Promotes an applied spray record into the reusable program.
    static let addToProgram = "Add to Program"
    /// Supporting state shown once a record is already in the program.
    static let inProgram = "In Program"
    /// Banner for a Program Step that is shared with the admin portal.
    ///
    /// Deliberately "Synced", not "Managed". The Program is a shared vineyard
    /// resource — the portal and mobile edit the SAME `spray_jobs` row — so
    /// wording that described a locked, portal-only object now misleads. What
    /// the operator needs to know is that this is the shared Program Step, and
    /// that changing it here changes it everywhere.
    static let syncedWithAdminPortal = "Synced with Admin Portal"
    /// Alias kept so the banner has one canonical name at the call sites that
    /// describe the sync relationship rather than the step itself.
    static var portalSyncBanner: String { syncedWithAdminPortal }

    // MARK: - Import spreadsheet

    /// The blank import spreadsheet. Deliberately NOT called a template — that
    /// word now means a Program Step to the operator.
    static let downloadImportCSV = "Download Import CSV"
    static let importCSV = "Import CSV"

    // MARK: - Composed copy

    static let chooseProgramStepTitle = "Choose a Program Step"
    static let noProgramStepsAvailable = "No Program Steps Available"

    /// Subtitle for the `Plan from Program` entry point.
    /// - Parameter count: number of Program Steps currently available.
    static func planFromProgramSubtitle(count: Int) -> String {
        count == 0
            ? "No Program Steps yet — add one in Spray Program or the admin portal"
            : "Start from a saved Program Step (\(count) available)"
    }

    /// Every operator-facing string this type vends. Used by tests to prove the
    /// retired vocabulary cannot creep back in.
    static var allLabels: [String] {
        [
            programStep, program, programSteps,
            planFromProgram, oneOffSpray, addProgramStep, addToProgram,
            inProgram, syncedWithAdminPortal,
            downloadImportCSV, importCSV,
            chooseProgramStepTitle, noProgramStepsAvailable,
            planFromProgramSubtitle(count: 0),
            planFromProgramSubtitle(count: 3)
        ]
    }
}

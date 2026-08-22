import Foundation

/// Extracts a numeric E-L (Eichhorn–Lorenz) stage for sorting.
///
/// "EL12", "EL 12", "E-L 12" and "el-7" all resolve to their stage number, so
/// sorting follows the real phenological order (EL 7 < EL 12 < EL 31) rather
/// than the alphabetical order of the display text ("EL 12" < "EL 7").
///
/// Moved here verbatim from `SprayProgramView` when the Program tab gained its
/// own model: the parser is domain logic, not presentation, and the Program
/// catalogue below needs it without pulling in a view.
nonisolated enum ELStageParser {
    /// Parse a canonical `growth_stage_code` such as "EL12".
    static func stageNumber(fromCode code: String?) -> Int? {
        guard let code, !code.isEmpty else { return nil }
        let digits = code.filter(\.isNumber)
        guard !digits.isEmpty, digits.count <= 3, let value = Int(digits), value > 0 else { return nil }
        return value
    }

    /// Scan free text (spray reference / notes) for an E-L mention.
    static func stageNumber(inText text: String) -> Int? {
        let chars = Array(text.lowercased())
        var i = 0
        while i < chars.count {
            guard chars[i] == "e" else { i += 1; continue }
            // "EL" must start a word — the preceding character can't be
            // alphanumeric (avoids matching "Model 3", "Diesel 5", ...).
            if i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { i += 1; continue }
            var j = i + 1
            if j < chars.count, chars[j] == "-" { j += 1 }
            guard j < chars.count, chars[j] == "l" else { i += 1; continue }
            j += 1
            while j < chars.count, chars[j] == " " || chars[j] == "-" || chars[j] == "." { j += 1 }
            var digits = ""
            while j < chars.count, chars[j].isNumber, digits.count < 3 {
                digits.append(chars[j])
                j += 1
            }
            if let value = Int(digits), value > 0 { return value }
            i = max(j, i + 1)
        }
        return nil
    }
}

/// Maps a label/portal target STRING onto VineTrack's typed spray targets.
///
/// A portal Program Step states its target as free text, and one step commonly
/// names several ("Downy Mildew · Black Spot · Phomopsis"). The raw wording is
/// always kept for display; this only produces the typed set the calculator's
/// existing `sprayTargets` state understands.
///
/// Deliberately conservative — it delegates every individual decision to the
/// existing `ChemicalRegisteredUse.mapTarget`, so a target VineTrack has no
/// word for (Phomopsis, Black Spot) contributes nothing rather than being
/// force-fitted onto a target it is not.
nonisolated enum SprayProgramTargetParser {
    private static let separators = CharacterSet(charactersIn: "·,;/&+\n|")

    static func targets(from raw: String?) -> [SprayTarget] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let parts = raw
            .replacingOccurrences(of: " and ", with: ",", options: [.caseInsensitive])
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<SprayTarget>()
        var out: [SprayTarget] = []
        for part in parts {
            guard let mapped = ChemicalRegisteredUse.mapTarget(part) else { continue }
            if seen.insert(mapped).inserted { out.append(mapped) }
        }
        return out
    }
}

/// Where a Program Step is managed.
nonisolated enum SprayProgramStepSource: String, Sendable, Hashable {
    /// Created on device, stored in `spray_records` with `is_template = true`.
    case local
    /// Created in the admin portal (`spray_jobs`, `is_template = true`).
    /// Read-only on mobile — the existing permission boundary, preserved.
    case portal

    var isReadOnly: Bool { self == .portal }
}

/// One reusable step in the vineyard's spray program.
///
/// A Program Step is CONFIGURATION, not an application. It answers "what do we
/// spray at this growth stage, and with what" — never "when did we spray, over
/// what area, at what cost". That distinction is the whole point of separating
/// Program from Sprays: the old UI rendered both through the same operational
/// row, so a reusable step carried a meaningless date and tank count.
///
/// It wraps the existing merged `SprayRecord` template source rather than
/// replacing it, and adds the portal fields the previous iOS adapter decoded
/// but then dropped (canonical growth stage code, verbatim target wording).
/// No new storage, no new sync path, no duplicate objects.
nonisolated struct SprayProgramStep: Identifiable, Sendable, Hashable {
    /// The underlying template record — the same value the existing pickers
    /// and the calculator prefill flow already consume.
    let record: SprayRecord
    let source: SprayProgramStepSource
    /// Canonical `spray_jobs.growth_stage_code`. Portal steps only; a local
    /// step states its stage in its name or notes, if at all.
    let growthStageCode: String?
    /// The portal's own target wording, VERBATIM. Kept because it routinely
    /// names targets VineTrack has no typed case for, and dropping those would
    /// silently narrow what the step says it is for.
    let targetRaw: String?

    nonisolated var id: UUID { record.id }

    init(
        record: SprayRecord,
        source: SprayProgramStepSource,
        growthStageCode: String? = nil,
        targetRaw: String? = nil
    ) {
        self.record = record
        self.source = source
        let code = growthStageCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.growthStageCode = (code?.isEmpty ?? true) ? nil : code
        let target = targetRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetRaw = (target?.isEmpty ?? true) ? nil : target
    }

    // MARK: - Identity

    var name: String { record.sprayReference }
    var notes: String { record.notes }
    var isPortalManaged: Bool { source.isReadOnly }
    var operationType: OperationType { record.operationType }

    /// Product lines exactly as the step configures them. Rates are stored
    /// values — the Program screen never calculates anything from them.
    var products: [SprayChemical] { record.tanks.flatMap(\.chemicals) }

    // MARK: - Growth stage

    /// The numeric E-L stage, preferring the canonical portal code over any
    /// mention in the step's own text.
    var elStage: Int? {
        if let value = ELStageParser.stageNumber(fromCode: growthStageCode) { return value }
        if let value = ELStageParser.stageNumber(inText: record.sprayReference) { return value }
        return ELStageParser.stageNumber(inText: record.notes)
    }

    /// Badge text such as `"EL4"`, or `nil` when no stage is known. A step
    /// without a stage says so rather than being given a plausible one.
    var elStageLabel: String? {
        if let code = growthStageCode, !code.isEmpty { return code.uppercased() }
        guard let stage = elStage else { return nil }
        return "EL\(stage)"
    }

    /// The phenological description for the resolved stage, e.g. "Budburst;
    /// leaf tips visible". Display sugar — never used for matching.
    var growthStageDescription: String? {
        guard let stage = elStage else { return nil }
        return GrowthStage.allStages
            .first { ELStageParser.stageNumber(fromCode: $0.code) == stage }?
            .description
    }

    // MARK: - Targets

    /// This step's target selection, as removable tags.
    ///
    /// Reads the STRUCTURED identifiers the record carries (typed cases plus
    /// this vineyard's own), and uses the verbatim wording line to recover how
    /// each was written. A step that has only the old free-text wording — every
    /// step written before targets became tags — is split on the conservative
    /// separators instead, so its wording becomes tags rather than being lost.
    ///
    /// - Parameter labels: the vineyard's target library, for wording that is
    ///   neither typed nor present on this step's own line.
    func targetTags(labels: [String: String] = [:]) -> [SprayTargetTag] {
        SprayTargetVocabulary.tags(
            identifiers: record.applicationGeometry?.targetIdentifiers ?? [],
            wording: targetRaw,
            labels: labels
        )
    }

    /// Typed targets this step is for. Custom targets contribute nothing here
    /// on purpose — the calculator has no case for them and forcing one would
    /// claim the step is for a disease it is not.
    var targets: [SprayTarget] {
        SprayTargetVocabulary.builtIns(targetTags())
    }

    /// What to SHOW as the step's target line.
    var targetDisplay: String? {
        SprayTargetVocabulary.displayString(targetTags()) ?? targetRaw
    }

    // MARK: - Prefill

    /// The configuration to carry into the guided Spray Calculator.
    ///
    /// Configuration only: identities and declared intent. No chemistry
    /// snapshot travels through here — the calculator resolves each product
    /// against TODAY's Chemical Store and freezes fresh chemistry at save
    /// time, which is the contract every new application follows.
    var calculatorPrefill: SprayProgramPrefill {
        let tags = targetTags()
        return SprayProgramPrefill(
            growthStageCode: growthStageCode,
            targets: SprayTargetVocabulary.builtIns(tags),
            customTargets: SprayTargetVocabulary.customs(tags).map(\.identifier),
            equipmentId: record.sprayEquipmentId,
            tractorId: record.tractorId
        )
    }

    // MARK: - Search

    /// Client-side match across everything a Program Step actually states.
    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        var haystack: [String] = [name, notes, operationType.rawValue]
        if let code = elStageLabel { haystack.append(code) }
        if let description = growthStageDescription { haystack.append(description) }
        if let target = targetDisplay { haystack.append(target) }
        haystack.append(contentsOf: targetTags().map(\.label))
        haystack.append(contentsOf: products.map(\.name))

        // "EL12" must also match a step whose stage came from a canonical code
        // written differently ("E-L 12"), so compare stage numbers as well.
        if let queryStage = ELStageParser.stageNumber(inText: trimmed) ?? ELStageParser.stageNumber(fromCode: trimmed),
           let stage = elStage,
           queryStage == stage {
            return true
        }

        return haystack.contains { $0.localizedStandardContains(trimmed) }
    }
}

/// Program Step configuration handed to the guided Spray Calculator.
///
/// Everything here is a DECLARED INTENT or an identity the operator already
/// chose once. Nothing is a calculated figure: area, carrier litres, tank
/// counts and product quantities stay owned by `SprayGuidedFlow` and
/// `SprayApplicationPlanner`.
nonisolated struct SprayProgramPrefill: Sendable, Hashable {
    /// Canonical E-L code, mapped onto the calculator's existing growth-stage
    /// state rather than appended to notes.
    let growthStageCode: String?
    /// Typed targets for the calculator's existing `sprayTargets`.
    let targets: [SprayTarget]
    /// Targets this vineyard named that the calculator has no typed case for,
    /// as stable identifiers.
    ///
    /// They travel so the spray this step plans still states what it is for.
    /// Nothing coerces them onto a built-in target — recording a Phomopsis
    /// spray as "Botrytis" because the enum has a Botrytis case would be a
    /// false compliance claim, and an untyped truth beats a typed lie.
    let customTargets: [String]
    let equipmentId: UUID?
    let tractorId: UUID?

    init(
        growthStageCode: String? = nil,
        targets: [SprayTarget] = [],
        customTargets: [String] = [],
        equipmentId: UUID? = nil,
        tractorId: UUID? = nil
    ) {
        self.growthStageCode = growthStageCode
        self.targets = targets
        self.customTargets = customTargets
        self.equipmentId = equipmentId
        self.tractorId = tractorId
    }

    var isEmpty: Bool {
        growthStageCode == nil && targets.isEmpty && customTargets.isEmpty
            && equipmentId == nil && tractorId == nil
    }
}

/// How the Program tab is ordered.
///
/// Deliberately has no date option. A Program Step is not dated — the vineyard
/// program is read in phenological order, and offering "Newest" here would sort
/// reusable configuration by a field that means nothing on it.
nonisolated enum SprayProgramStepSortOption: String, CaseIterable, Sendable {
    case elStageAscending = "elStageAsc"
    case elStageDescending = "elStageDesc"
    case nameAZ = "nameAZ"
    case nameZA = "nameZA"

    var label: String {
        switch self {
        case .elStageAscending: return "E-L Stage (Low \u{2192} High)"
        case .elStageDescending: return "E-L Stage (High \u{2192} Low)"
        case .nameAZ: return "Name (A\u{2013}Z)"
        case .nameZA: return "Name (Z\u{2013}A)"
        }
    }

    var icon: String {
        switch self {
        case .elStageAscending, .elStageDescending: return "leaf"
        case .nameAZ, .nameZA: return "textformat"
        }
    }
}

/// Builds the Program list from the existing merged template sources.
///
/// Pure logic, no view and no store: the merge, dedup, sort and search rules
/// are the part worth testing, and they should not require a SwiftUI host to
/// exercise.
nonisolated enum SprayProgramCatalog {

    /// Merge local templates with read-only portal templates.
    ///
    /// - Parameters:
    ///   - localRecords: `store.sprayRecords` — filtered to templates here.
    ///   - portalRecords: `SprayJobTemplateService.templateRecords`, the
    ///     service's already-mapped cache. Used as-is so Program shows exactly
    ///     what the existing pickers show, offline included.
    ///   - portalRows: `SprayJobTemplateService.templates`, consulted ONLY for
    ///     the metadata `toSprayRecord()` cannot carry on a `SprayRecord`.
    ///
    /// Local wins on an id collision, matching the existing implementation: a
    /// record the device owns must not be shadowed by a read-only copy.
    static func steps(
        localRecords: [SprayRecord],
        portalRecords: [SprayRecord],
        portalRows: [BackendSprayJobTemplate] = []
    ) -> [SprayProgramStep] {
        let local = localRecords.filter(\.isTemplate)
        let localIds = Set(local.map(\.id))

        var rowsById: [UUID: BackendSprayJobTemplate] = [:]
        for row in portalRows { rowsById[row.id] = row }

        var seenPortal = Set<UUID>()
        let portal = portalRecords
            .filter { !localIds.contains($0.id) && seenPortal.insert($0.id).inserted }
            .map { record in
                let row = rowsById[record.id]
                return SprayProgramStep(
                    record: record,
                    source: .portal,
                    growthStageCode: row?.growthStageCode,
                    targetRaw: row?.target
                )
            }

        return local.map { SprayProgramStep(record: $0, source: .local) } + portal
    }

    /// Apply the Program sort. Steps with no resolvable E-L stage always sink
    /// below staged ones in BOTH directions — an unknown stage is not a low
    /// stage, and floating it to the top of a reversed list would imply it is.
    static func sorted(
        _ steps: [SprayProgramStep],
        by option: SprayProgramStepSortOption
    ) -> [SprayProgramStep] {
        switch option {
        case .nameAZ:
            return steps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameZA:
            return steps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .elStageAscending, .elStageDescending:
            let ascending = option == .elStageAscending
            let keyed = steps.map { (step: $0, stage: $0.elStage) }
            return keyed.sorted { a, b in
                switch (a.stage, b.stage) {
                case let (x?, y?) where x != y:
                    return ascending ? x < y : x > y
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    // Stable, meaningful tie-break for equal or absent stages.
                    return a.step.name.localizedStandardCompare(b.step.name) == .orderedAscending
                }
            }.map(\.step)
        }
    }

    /// Every custom target this vineyard's Program Steps already use.
    ///
    /// The reason the target chooser is useful on day one. A vineyard that has
    /// been writing "Phomopsis" into its program for three seasons should not
    /// have to re-type it into a library before it can reuse it — the evidence
    /// that this vineyard sprays for Phomopsis is already in its own program.
    static func observedTargetTags(
        _ steps: [SprayProgramStep],
        labels: [String: String] = [:]
    ) -> [SprayTargetTag] {
        let all = steps.flatMap { $0.targetTags(labels: labels) }
        return SprayTargetVocabulary.customs(all)
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    static func filtered(_ steps: [SprayProgramStep], query: String) -> [SprayProgramStep] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return steps }
        return steps.filter { $0.matches(trimmed) }
    }
}

import Foundation

/// Turns stored spray history into canonical `ResistanceApplicationEvent`s.
///
/// WHICH RECORD STATES COUNT AS RESISTANCE HISTORY
///
/// Included:
/// - Records that are not templates and have a usable date, classified
///   `.actual` when an `endTime` is present.
///
/// Excluded, and why:
/// - `isTemplate == true` — a template is a reusable recipe, not an application. It
///   was never sprayed on a vine.
/// - Soft-deleted records — a deleted record is a retracted claim; counting it would
///   let a mistaken entry permanently consume a group's seasonal allowance. NOTE:
///   unlike Android's `SprayRecord`, the iOS model carries no `deletedAt` field, so
///   deletion is filtered upstream in the repository layer. `isDeleted` is exposed on
///   `Input` so a caller that does know can say so, and the exclusion stays visible.
/// - `endTime == nil` — classified `.planned` rather than discarded. VineTrack has no
///   separate cancelled/reversed state; an unfinished record is the closest thing, and
///   the engine excludes planned events from counting by default while still reporting
///   that it did so.
/// - No usable date — resistance rules are entirely sequence-based, and an event with
///   no position in the chronology cannot be evaluated. Surfaced via
///   `Result.undatedRecordIds` rather than dropped silently.
///
/// BLOCK ATTRIBUTION
///
/// Spray records do not currently record which blocks they covered. `SprayTank` carries
/// `rowApplications`, but `TankRowApplication` holds only `id`, `startRow` and `endRow`
/// — no block reference — on BOTH platforms, and it is never constructed with block
/// linkage. Rather than guess, this adapter requires the caller to supply `blockIds`. A
/// record with no blocks yields no events and is reported in
/// `Result.unattributedToBlockRecordIds` so the omission is visible.
///
/// Mirrors `ResistanceEventSource.kt` on Android.
nonisolated enum ResistanceEventSource {

    /// One record's resistance-relevant facts, supplied explicitly.
    ///
    /// Deliberately a neutral input rather than `SprayRecord` itself: block attribution
    /// has to come from the caller, and the iOS record has no target or deletion field.
    /// Keeping the adapter honest about what it is given beats inferring the rest.
    nonisolated struct Input: Sendable {
        nonisolated var recordId: String
        nonisolated var vineyardId: String
        nonisolated var appliedAtEpochMs: Int64?
        nonisolated var isTemplate: Bool
        nonisolated var isDeleted: Bool
        nonisolated var hasEndTime: Bool
        /// Nil means targets were never recorded (pre-sql/193). An empty array means
        /// recorded as targeting nothing. Those are different facts.
        nonisolated var targets: [ResistanceDisease]?
        nonisolated var blockIds: [String]
        nonisolated var products: [ResistanceProductLine]

        nonisolated init(
            recordId: String,
            vineyardId: String,
            appliedAtEpochMs: Int64?,
            isTemplate: Bool,
            isDeleted: Bool = false,
            hasEndTime: Bool,
            targets: [ResistanceDisease]?,
            blockIds: [String],
            products: [ResistanceProductLine]
        ) {
            self.recordId = recordId
            self.vineyardId = vineyardId
            self.appliedAtEpochMs = appliedAtEpochMs
            self.isTemplate = isTemplate
            self.isDeleted = isDeleted
            self.hasEndTime = hasEndTime
            self.targets = targets
            self.blockIds = blockIds
            self.products = products
        }
    }

    /// Events plus an explicit account of everything that did NOT become an event.
    ///
    /// The exclusions are returned rather than logged because a resistance report built
    /// on a silently-filtered history is exactly the false clean result this work exists
    /// to prevent.
    nonisolated struct Result: Sendable {
        nonisolated var events: [ResistanceApplicationEvent]
        nonisolated var deletedRecordIds: [String]
        nonisolated var templateRecordIds: [String]
        nonisolated var undatedRecordIds: [String]
        nonisolated var unattributedToBlockRecordIds: [String]

        nonisolated var hasExclusions: Bool {
            !deletedRecordIds.isEmpty || !templateRecordIds.isEmpty
                || !undatedRecordIds.isEmpty || !unattributedToBlockRecordIds.isEmpty
        }
    }

    nonisolated static func events(
        from inputs: [Input],
        seasonCalendar: ResistanceSeasonCalendar
    ) -> Result {
        var events: [ResistanceApplicationEvent] = []
        var deleted: [String] = []
        var templates: [String] = []
        var undated: [String] = []
        var unattributed: [String] = []

        for input in inputs {
            if input.isDeleted {
                deleted.append(input.recordId)
                continue
            }
            if input.isTemplate {
                templates.append(input.recordId)
                continue
            }
            guard let epochMs = input.appliedAtEpochMs else {
                undated.append(input.recordId)
                continue
            }
            var seenBlocks: Set<String> = []
            let blockIds = input.blockIds.filter { seenBlocks.insert($0).inserted }
            if blockIds.isEmpty {
                unattributed.append(input.recordId)
                continue
            }

            let kind: ResistanceEventKind = input.hasEndTime ? .actual : .planned
            let targetsRecorded = input.targets != nil
            let diseases = input.targets ?? []
            let seasonId = seasonCalendar.season(epochMs: epochMs).id

            for blockId in blockIds {
                events.append(
                    ResistanceApplicationEvent(
                        // One spray across three blocks becomes three events, each keeping
                        // the spray's own ID so a warning can always point back to the
                        // record the operator recognises.
                        applicationId: input.recordId,
                        kind: kind,
                        appliedAtEpochMs: epochMs,
                        seasonId: seasonId,
                        vineyardId: input.vineyardId,
                        blockId: blockId,
                        targets: diseases,
                        targetsRecorded: targetsRecorded,
                        products: input.products
                    )
                )
            }
        }

        return Result(
            events: events.chronological,
            deletedRecordIds: deleted,
            templateRecordIds: templates,
            undatedRecordIds: undated,
            unattributedToBlockRecordIds: unattributed
        )
    }

    /// Product lines built from the FROZEN snapshot on each chemical line.
    ///
    /// Never re-reads the live Chemical Store record. A classification corrected in 2029
    /// must not retroactively change what the 2026 rotation is said to have been, or
    /// every rotation decision made from that history becomes unstable.
    ///
    /// A missing snapshot is `.unavailable` — never "no groups". Legitimate VineTrack
    /// history predates Chemical Intelligence, and reading that silence as an absence of
    /// chemistry would hand back a green rotation report for a season nobody can account
    /// for.
    nonisolated static func productLines(from record: SprayRecord) -> [ResistanceProductLine] {
        record.tanks.flatMap { tank in
            tank.chemicals.map { chemical in
                let snapshot = chemical.chemicalSnapshot
                return ResistanceProductLine(
                    lineId: chemical.id.uuidString,
                    productName: snapshot?.productName ?? (chemical.name.isEmpty ? nil : chemical.name),
                    savedChemicalId: chemical.savedChemicalId?.uuidString,
                    groups: ResistanceGroupSignature.of(snapshot?.activityGroupCodes ?? []),
                    availability: ChemicalIntelligenceAvailability.resolve(snapshot: snapshot)
                )
            }
        }
    }

    /// Builds an `Input` from a real spray record plus the block attribution and
    /// deletion state only the caller can supply.
    nonisolated static func input(
        from record: SprayRecord,
        blockIds: [String],
        isDeleted: Bool = false
    ) -> Input {
        Input(
            recordId: record.id.uuidString,
            vineyardId: record.vineyardId.uuidString,
            appliedAtEpochMs: Int64((record.date.timeIntervalSince1970 * 1000).rounded()),
            isTemplate: record.isTemplate,
            isDeleted: isDeleted,
            hasEndTime: record.endTime != nil,
            // Targets live on the frozen application snapshot (sql/193). Nil there means
            // the question was never asked, which must not collapse into "no targets".
            targets: record.applicationGeometry?.targets.map { targets in
                targets.compactMap { ResistanceDisease.fromSprayTargetRaw($0.rawValue) }
            },
            blockIds: blockIds,
            products: productLines(from: record)
        )
    }
}

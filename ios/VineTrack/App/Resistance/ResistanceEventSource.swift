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
/// Since sql/195 a spray record states which blocks it treated, on the frozen
/// application snapshot (`applicationGeometry.blocks`). This adapter reads that
/// directly — no caller-supplied resolver, no inference. One spray attributed to blocks
/// A and C becomes two events sharing the spray's application ID.
///
/// Records written BEFORE sql/195 carry `nil` attribution, which means "blocks not
/// recorded" and nothing else. Such a record produces NO events and is reported in
/// `Result.unresolvedBlockApplications` with everything a caller needs to judge whether
/// it could have mattered. It is never assigned to a block: not by row number, not by
/// name similarity, not by current geometry, not by "the vineyard only has one block".
///
/// `TankRowApplication` still holds only `id`, `startRow` and `endRow` on both platforms.
/// Row numbers are not unique across blocks and carry no block reference, so they remain
/// unusable as attribution and are not consulted.
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
        /// The blocks this application treated. `nil` means NEVER RECORDED (a pre-sql/195
        /// record); a populated array means recorded. These are different facts and are
        /// kept apart for the same reason `targets` is: silence must not read as "none".
        ///
        /// An empty array is normalised to `nil` on construction, because "treated no
        /// blocks" is not a state a real application can be in.
        nonisolated var blockIds: [String]?
        nonisolated var products: [ResistanceProductLine]

        nonisolated init(
            recordId: String,
            vineyardId: String,
            appliedAtEpochMs: Int64?,
            isTemplate: Bool,
            isDeleted: Bool = false,
            hasEndTime: Bool,
            targets: [ResistanceDisease]?,
            blockIds: [String]?,
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

    /// A real application that cannot be placed on any block, carried with enough
    /// context for a caller to decide whether it could have changed a block's answer.
    ///
    /// This exists because of a specific, dangerous subtlety: an unattributed spray
    /// happened SOMEWHERE in this vineyard. It is not irrelevant — it is unplaceable.
    /// A block-specific evaluation that quietly ignored these could report "no issue
    /// detected" for a block whose history is genuinely unknown. Carrying the season,
    /// the declared targets and the frozen chemistry lets the caller say "historical
    /// block attribution is incomplete" precisely when it matters, instead of either
    /// crying wolf on every vineyard with legacy data or staying silent.
    nonisolated struct UnresolvedBlockApplication: Sendable, Hashable {
        nonisolated var applicationId: String
        nonisolated var vineyardId: String
        nonisolated var appliedAtEpochMs: Int64
        nonisolated var seasonId: String
        nonisolated var kind: ResistanceEventKind
        /// What the operator declared this spray was for, when they declared it.
        nonisolated var targets: [ResistanceDisease]
        nonisolated var targetsRecorded: Bool
        nonisolated var products: [ResistanceProductLine]

        /// True when this application could bear on the given disease.
        ///
        /// Unrecorded targets count as possibly-relevant: the spray may well have been
        /// for this disease and nothing establishes otherwise.
        nonisolated func mayConcern(_ disease: ResistanceDisease) -> Bool {
            !targetsRecorded || targets.contains(disease)
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
        /// Real applications whose treated blocks were never recorded.
        nonisolated var unresolvedBlockApplications: [UnresolvedBlockApplication]

        /// Record ids of the unresolved applications, in chronological order.
        nonisolated var unattributedToBlockRecordIds: [String] {
            unresolvedBlockApplications.map(\.applicationId)
        }

        /// True when any real application in this history cannot be placed on a block.
        /// A block-specific clean result must be qualified when this is true and the
        /// unresolved applications could concern the disease being evaluated.
        nonisolated var hasUnresolvedBlockAttribution: Bool {
            !unresolvedBlockApplications.isEmpty
        }

        /// The unresolved applications that could bear on `disease` in `seasonId`.
        nonisolated func unresolvedApplications(
            concerning disease: ResistanceDisease,
            seasonId: String? = nil
        ) -> [UnresolvedBlockApplication] {
            unresolvedBlockApplications.filter { application in
                application.mayConcern(disease)
                    && (seasonId == nil || application.seasonId == seasonId)
            }
        }

        nonisolated var hasExclusions: Bool {
            !deletedRecordIds.isEmpty || !templateRecordIds.isEmpty
                || !undatedRecordIds.isEmpty || !unresolvedBlockApplications.isEmpty
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
        var unresolved: [UnresolvedBlockApplication] = []

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
            let kind: ResistanceEventKind = input.hasEndTime ? .actual : .planned
            let targetsRecorded = input.targets != nil
            let diseases = input.targets ?? []
            let seasonId = seasonCalendar.season(epochMs: epochMs).id

            var seenBlocks: Set<String> = []
            let blockIds = (input.blockIds ?? []).filter { seenBlocks.insert($0).inserted }
            if blockIds.isEmpty {
                // Unplaceable, NOT irrelevant. Reported with full context so a
                // block-specific evaluation can qualify its answer rather than
                // pretending this spray never happened.
                unresolved.append(
                    UnresolvedBlockApplication(
                        applicationId: input.recordId,
                        vineyardId: input.vineyardId,
                        appliedAtEpochMs: epochMs,
                        seasonId: seasonId,
                        kind: kind,
                        targets: diseases,
                        targetsRecorded: targetsRecorded,
                        products: input.products
                    )
                )
                continue
            }

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
            unresolvedBlockApplications: unresolved.sorted {
                $0.appliedAtEpochMs != $1.appliedAtEpochMs
                    ? $0.appliedAtEpochMs < $1.appliedAtEpochMs
                    : $0.applicationId < $1.applicationId
            }
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
                    groups: groups(from: snapshot),
                    availability: ChemicalIntelligenceAvailability.resolve(snapshot: snapshot)
                )
            }
        }
    }

    /// The frozen groups for one line, SCHEME-QUALIFIED wherever the snapshot recorded
    /// a scheme.
    ///
    /// The structured actives are the authority: each carries its own FRAC/HRAC/IRAC
    /// classification, so a `"9"` on a herbicide active stays HRAC 9 and can never be
    /// counted against a FRAC 9 rule. `activityGroupCodes` is a denormalised bare copy
    /// with no scheme, so it is consulted only when the actives carry no classification
    /// at all — older snapshots that genuinely never recorded one. Those stay bare and
    /// are resolved by the reading ruleset rather than being promoted to a scheme
    /// nobody wrote down.
    nonisolated static func groups(from snapshot: ChemicalLineSnapshot?) -> ResistanceGroupSignature {
        guard let snapshot else { return .empty }
        let structured = ResistanceGroupSignature.of(
            structured: snapshot.activeIngredients.compactMap(\.activityGroup)
        )
        if !structured.codes.isEmpty { return structured }
        return ResistanceGroupSignature.of(snapshot.activityGroupCodes)
    }

    /// Builds an `Input` from a real spray record.
    ///
    /// Block attribution and declared targets both come from the record's own frozen
    /// application snapshot, so a normal record needs nothing from the caller but its
    /// deletion state (which the iOS model does not carry — see the type docs).
    ///
    /// `blockIdsOverride` exists for one legitimate case: an import or migration path
    /// that has established attribution from a genuinely authoritative external source.
    /// It is NOT a hook for inferring blocks from row numbers or names.
    nonisolated static func input(
        from record: SprayRecord,
        isDeleted: Bool = false,
        blockIdsOverride: [String]? = nil
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
            // Block attribution (sql/195), read verbatim from the record. Nil stays nil.
            blockIds: blockIdsOverride ?? record.applicationGeometry?.blocks?.blockIds,
            products: productLines(from: record)
        )
    }
}

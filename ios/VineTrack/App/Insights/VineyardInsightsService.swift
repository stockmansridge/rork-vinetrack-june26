import Foundation
import Observation

/// Local-first state holder for the Vineyard Insights preview.
///
/// Deliberately a self-contained service rather than state spread through the
/// existing app objects: this is an unreleased, System Admin-only preview, so
/// keeping it in one removable place means the feature can be withdrawn
/// without unpicking anything else. It also keeps the capture rules testable.
///
/// Every mutation writes to `VineyardInsightsStore` FIRST and queues a sync
/// operation second. Nothing here performs network work — Round 1 establishes
/// the capture and durability contract; the replay worker is a later slice and
/// consumes `VineyardInsightsStore.loadQueue()`, which already carries each
/// record's own vineyard id.
@Observable
@MainActor
final class VineyardInsightsService {

    private(set) var visits: [ScoutVisit] = []
    private(set) var notes: [VintageNote] = []
    private(set) var openVisitID: UUID?

    /// True when the most recent local write failed to reach disk.
    ///
    /// Surfaced so the operator can be told, rather than being left to assume a
    /// capture is safe. A field observation that silently failed to save is the
    /// worst outcome this feature can produce.
    private(set) var lastWriteFailed = false

    private let store: VineyardInsightsStore
    private let now: () -> Date

    init(store: VineyardInsightsStore = VineyardInsightsStore(), now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
        self.visits = store.loadVisits()
        self.notes = store.loadNotes()
    }

    @discardableResult
    private func record(_ success: Bool) -> Bool {
        lastWriteFailed = !success
        return success
    }

    // MARK: - Scout

    func openVisit(_ id: UUID?) { openVisitID = id }

    func visit(_ id: UUID?) -> ScoutVisit? {
        guard let id else { return nil }
        return visits.first { $0.id == id }
    }

    var openVisit: ScoutVisit? { visit(openVisitID) }

    func visits(status: ScoutStatus) -> [ScoutVisit] {
        visits.filter { $0.status == status }.sorted { $0.scoutDate > $1.scoutDate }
    }

    /// Start a new visit. The id is client-generated so an offline capture
    /// already has its permanent identity before the server ever hears of it.
    @discardableResult
    func startVisit(
        vineyardID: UUID,
        scoutUserID: UUID?,
        scoutName: String?,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        date: Date = Date()
    ) -> ScoutVisit {
        let visit = ScoutVisit(
            vineyardID: vineyardID,
            vintageYear: VintageResolver.vintageYear(
                for: date,
                seasonStartMonth: seasonStartMonth,
                seasonStartDay: seasonStartDay
            ),
            scoutDate: date,
            scoutUserID: scoutUserID,
            scoutNameSnapshot: scoutName,
            clientUpdatedAt: now()
        )
        persist(visit)
        openVisitID = visit.id
        return visit
    }

    func toggleBlock(visitID: UUID, paddockID: UUID) {
        guard var visit = visit(visitID), visit.isEditable else { return }
        if let existing = visit.assessment(paddockID: paddockID) {
            // Removing a block that already holds observations would discard
            // field work, so only an untouched block may be removed by a toggle.
            guard existing.recordedObservations.isEmpty else { return }
            visit.removeBlock(paddockID: paddockID)
        } else {
            visit.addBlock(paddockID: paddockID)
        }
        persist(visit)
    }

    func setSummary(visitID: UUID, summary: String) {
        guard var visit = visit(visitID), visit.isEditable else { return }
        visit.visitSummary = summary.isEmpty ? nil : summary
        persist(visit)
    }

    func setWeather(visitID: UUID, weather: ScoutWeatherSnapshot) {
        guard var visit = visit(visitID) else { return }
        visit.weather = weather
        persist(visit)
    }

    func setObservationValue(
        visitID: UUID,
        assessmentID: UUID,
        item: ScoutItem,
        option: ScoutOption
    ) {
        updateObservation(visitID: visitID, assessmentID: assessmentID, item: item) {
            $0.valueCode = option.code
            $0.valueLabel = option.label
        }
    }

    func setObservationNotes(
        visitID: UUID,
        assessmentID: UUID,
        item: ScoutItem,
        notes: String
    ) {
        updateObservation(visitID: visitID, assessmentID: assessmentID, item: item) {
            $0.notes = notes.isEmpty ? nil : notes
        }
    }

    func addPhoto(visitID: UUID, assessmentID: UUID, item: ScoutItem, photo: ScoutPhoto) {
        updateObservation(visitID: visitID, assessmentID: assessmentID, item: item) {
            $0.photos.append(photo)
        }
    }

    /// Attach the canonical Growth Stage record created for an E-L selection.
    ///
    /// The stage VALUE is deliberately not stored on the observation — only the
    /// link and the label shown at the time. See `ScoutGrowthStageLink`.
    func linkGrowthStageRecord(
        visitID: UUID,
        assessmentID: UUID,
        recordID: UUID,
        stageLabel: String
    ) {
        updateObservation(visitID: visitID, assessmentID: assessmentID, item: .growthStage) {
            $0.linkedGrowthStageRecordID = recordID
            $0.valueLabel = stageLabel
        }
    }

    private func updateObservation(
        visitID: UUID,
        assessmentID: UUID,
        item: ScoutItem,
        _ transform: (inout ScoutObservation) -> Void
    ) {
        guard var visit = visit(visitID), visit.isEditable else { return }
        guard var assessment = visit.assessments.first(where: { $0.id == assessmentID }) else { return }
        var observation = assessment.observation(item)
            ?? ScoutObservation.empty(assessmentID: assessmentID, item: item)
        transform(&observation)
        assessment.setObservation(observation)
        visit.setAssessment(assessment)
        persist(visit)
    }

    func review(visitID: UUID) -> ScoutReview {
        guard let visit = visit(visitID) else {
            return ScoutReview(
                blocksAssessed: 0,
                blocksIncomplete: 0,
                growthStageObservations: 0,
                attentionItems: 0,
                photoCount: 0,
                otherIssues: 0,
                generalRecommendations: 0,
                incompletePaddockIDs: []
            )
        }
        return ScoutReview.of(visit)
    }

    /// Complete a visit, refusing when the review rule is not satisfied.
    @discardableResult
    func completeVisit(_ visitID: UUID) -> Bool {
        guard var visit = visit(visitID), ScoutReview.of(visit).canComplete else { return false }
        visit.status = .completed
        return persist(visit)
    }

    /// Deliberately return a completed visit to Draft, with caller confirmation.
    @discardableResult
    func reopenVisit(_ visitID: UUID) -> Bool {
        guard var visit = visit(visitID) else { return false }
        visit.status = .draft
        return persist(visit)
    }

    /// Delete a Scout. Canonical Growth Stage records it created are RETAINED —
    /// the returned links are what the caller should unlink, never delete.
    @discardableResult
    func deleteVisit(_ visitID: UUID) -> [ScoutGrowthStageLink] {
        guard let visit = visit(visitID) else { return [] }
        let retained = ScoutGrowthStageLink.onScoutDeleted(visit)
        if record(store.deleteVisit(id: visitID)) {
            visits = store.loadVisits()
            if openVisitID == visitID { openVisitID = nil }
        }
        return retained
    }

    @discardableResult
    private func persist(_ visit: ScoutVisit) -> Bool {
        var stamped = visit
        stamped.clientUpdatedAt = now()
        let saved = store.saveVisit(stamped)
        if saved {
            visits = store.loadVisits()
            store.enqueue(
                recordID: stamped.id,
                vineyardID: stamped.vineyardID,
                entity: .scoutVisit,
                operation: .upsert,
                clientUpdatedAt: stamped.clientUpdatedAt
            )
        }
        return record(saved)
    }

    // MARK: - Vintage Notes

    func notes(vintageYear: Int) -> [VintageNote] {
        VintageNoteRules.forVintage(notes, vintageYear: vintageYear)
    }

    func customNoteTypes(vineyardID: UUID) -> [VintageNoteType] {
        store.customNoteTypes(vineyardID: vineyardID)
    }

    @discardableResult
    func addCustomNoteType(
        vineyardID: UUID,
        label: String,
        group: VintageNoteGroup = .other
    ) -> VintageNoteType? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let type = VintageNoteType(
            code: "custom_\(UUID().uuidString.prefix(8).lowercased())",
            group: group,
            label: trimmed,
            sortOrder: 1_000,
            isCustom: true
        )
        return record(store.saveCustomNoteType(vineyardID: vineyardID, type: type)) ? type : nil
    }

    /// Create or update a note from the form draft.
    ///
    /// Returns nil when the draft is empty — the rule lives on
    /// `VintageNoteDraft` so the form, this path and the server all state it
    /// the same way. The vintage written here is the local mirror for display;
    /// the server recomputes it from the date and its answer wins.
    @discardableResult
    func saveNote(
        draft: VintageNoteDraft,
        vineyardID: UUID,
        observedByUserID: UUID?,
        observerName: String?,
        seasonStartMonth: Int,
        seasonStartDay: Int
    ) -> VintageNote? {
        guard draft.canSave else { return nil }
        let timestamp = now()
        let existing = notes.first { $0.id == draft.id }
        let note = VintageNote(
            id: draft.id,
            vineyardID: vineyardID,
            noteDate: draft.date,
            vintageYear: draft.resolvedVintage(
                seasonStartMonth: seasonStartMonth,
                seasonStartDay: seasonStartDay
            ),
            noteTypeID: draft.noteTypeID,
            // Only overwrite the historical snapshot when the form carries a
            // label. An edit that does not touch the type must not blank what
            // the original observer chose.
            noteTypeLabelSnapshot: draft.noteTypeLabel ?? existing?.noteTypeLabelSnapshot,
            notes: draft.notes.isEmpty ? nil : draft.notes,
            observedByUserID: existing?.observedByUserID ?? observedByUserID,
            observerNameSnapshot: existing?.observerNameSnapshot ?? observerName,
            createdAt: existing?.createdAt ?? timestamp,
            updatedAt: timestamp,
            clientUpdatedAt: timestamp,
            syncVersion: existing?.syncVersion ?? 0,
            deletedAt: nil
        )
        guard record(store.saveNote(note)) else { return nil }
        notes = store.loadNotes()
        store.enqueue(
            recordID: note.id,
            vineyardID: note.vineyardID,
            entity: .vintageNote,
            operation: .upsert,
            clientUpdatedAt: note.clientUpdatedAt
        )
        return note
    }

    /// Soft delete — the row is tombstoned locally so sync can reconcile it.
    @discardableResult
    func deleteNote(_ noteID: UUID) -> Bool {
        guard var note = notes.first(where: { $0.id == noteID }) else { return false }
        let timestamp = now()
        note.deletedAt = timestamp
        note.updatedAt = timestamp
        note.clientUpdatedAt = timestamp
        guard record(store.saveNote(note)) else { return false }
        notes = store.loadNotes()
        store.enqueue(
            recordID: note.id,
            vineyardID: note.vineyardID,
            entity: .vintageNote,
            operation: .delete,
            clientUpdatedAt: timestamp
        )
        return true
    }

    // MARK: - Session

    /// Drop every locally held preview record on sign-out.
    func clearOnSignOut() {
        store.clearForSignOut()
        visits = []
        notes = []
        openVisitID = nil
        lastWriteFailed = false
    }
}

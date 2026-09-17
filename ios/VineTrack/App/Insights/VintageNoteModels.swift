import Foundation

/// Vintage Notes domain — pure data and pure rules, mirroring the Android
/// `VintageNoteModels.kt`.

/// A single vineyard-wide note about the vintage.
///
/// ## Why both a type id and a label snapshot
///
/// `noteTypeID` groups and filters; `noteTypeLabelSnapshot` is what the
/// observer actually chose on the day. Renaming or retiring a type later must
/// not rewrite the historical record — see `VintageNoteCatalog`.
///
/// ## Why the vintage is not authoritative here
///
/// `vintageYear` is resolved locally from the vineyard's season-start setting
/// so the form can show the operator which vintage they are filing against. It
/// is DISPLAY ONLY. The server recomputes it from `note_date` on every insert
/// and update (SQL 236) and its answer replaces this one. A client clock, a
/// stale cached season setting or a hand-edited payload must never be able to
/// file a note into the wrong vintage — that would quietly corrupt every future
/// report for that season.
nonisolated struct VintageNote: Identifiable, Equatable, Sendable {
    /// Client-generated UUID — the offline idempotency key.
    let id: UUID
    let vineyardID: UUID
    var noteDate: Date
    /// Locally resolved for display; the server's value wins after sync.
    var vintageYear: Int
    var noteTypeID: String?
    var noteTypeLabelSnapshot: String?
    var notes: String?
    let observedByUserID: UUID?
    let observerNameSnapshot: String?
    let createdAt: Date
    var updatedAt: Date
    var clientUpdatedAt: Date
    var syncVersion: Int
    var deletedAt: Date?

    var isDeleted: Bool { deletedAt != nil }

    /// True when the note was changed after it was first written. Compared on
    /// whole seconds: a create path that stamps `createdAt` and `updatedAt`
    /// microseconds apart must not label a brand-new note as edited.
    var isEdited: Bool {
        Int(updatedAt.timeIntervalSince1970) > Int(createdAt.timeIntervalSince1970)
    }

    /// Short single-line preview for the list.
    func preview(maxLength: Int = 80) -> String {
        let text = (notes ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return "" }
        guard text.count > maxLength else { return text }
        let clipped = text.prefix(maxLength - 1).trimmingCharacters(in: .whitespaces)
        return clipped + "\u{2026}"
    }

    /// What the list shows as the note's heading.
    func displayType() -> String {
        guard let label = noteTypeLabelSnapshot, !label.isEmpty else { return "Note" }
        return label
    }
}

/// The editable state of the Vintage Note form.
nonisolated struct VintageNoteDraft: Equatable, Sendable {
    var id: UUID = UUID()
    var date: Date = Date()
    var noteTypeID: String?
    var noteTypeLabel: String?
    var notes: String = ""

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        noteTypeID: String? = nil,
        noteTypeLabel: String? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.date = date
        self.noteTypeID = noteTypeID
        self.noteTypeLabel = noteTypeLabel
        self.notes = notes
    }

    /// The save rule: a note needs a type OR some text.
    ///
    /// Only the both-empty case is refused. A type on its own is a legitimate
    /// record ("Frost", on this date, is a complete and useful statement), and
    /// text on its own is equally legitimate when nothing in the catalogue
    /// fits. Refusing either would push observers into picking an inaccurate
    /// type just to get past validation.
    var canSave: Bool {
        let hasType = !(noteTypeID ?? "").isEmpty
        let hasNotes = !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasType || hasNotes
    }

    var blockedReason: String? { canSave ? nil : VintageNoteRules.emptyMessage }

    /// Vintage shown in the form, resolved exactly as the server will.
    func resolvedVintage(seasonStartMonth: Int, seasonStartDay: Int) -> Int {
        VintageResolver.vintageYear(
            for: date,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay
        )
    }
}

nonisolated enum VintageNoteRules {
    static let emptyMessage = "Add a note type or some notes before saving."

    static let vintageServerNote =
        "Vintage is set from the date by the server using this vineyard's season settings."

    /// Newest first; ties broken by creation time so the order is stable.
    static func sortedForDisplay(_ notes: [VintageNote]) -> [VintageNote] {
        notes
            .filter { !$0.isDeleted }
            .sorted { lhs, rhs in
                if lhs.noteDate != rhs.noteDate { return lhs.noteDate > rhs.noteDate }
                return lhs.createdAt > rhs.createdAt
            }
    }

    /// Notes belonging to one vintage, newest first.
    static func forVintage(_ notes: [VintageNote], vintageYear: Int) -> [VintageNote] {
        sortedForDisplay(notes).filter { $0.vintageYear == vintageYear }
    }

    /// Vineyard-scoped history; nil means All vintages.
    static func history(
        _ notes: [VintageNote],
        vineyardID: UUID,
        vintageYear: Int?
    ) -> [VintageNote] {
        sortedForDisplay(notes)
            .filter { $0.vineyardID == vineyardID }
            .filter { vintageYear == nil || $0.vintageYear == vintageYear }
    }
}

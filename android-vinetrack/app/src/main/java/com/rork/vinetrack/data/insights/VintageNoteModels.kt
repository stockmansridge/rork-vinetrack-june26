package com.rork.vinetrack.data.insights

import com.rork.vinetrack.data.VintageResolver
import java.time.LocalDate
import java.util.UUID

/**
 * Vintage Notes domain — pure data and pure rules, mirrored by iOS
 * `VintageNoteModels.swift`.
 */

/**
 * A single vineyard-wide note about the vintage.
 *
 * ## Why both a type id and a label snapshot
 *
 * [noteTypeId] groups and filters; [noteTypeLabelSnapshot] is what the observer
 * actually chose on the day. Renaming or retiring a type later must not rewrite
 * the historical record — see [VintageNoteCatalog].
 *
 * ## Why the vintage is not authoritative here
 *
 * [vintageYear] is resolved locally from the vineyard's season-start setting so
 * the form can show the operator which vintage they are filing against. It is
 * DISPLAY ONLY. The server recomputes it from `note_date` on every insert and
 * update (SQL 236) and its answer replaces this one. A client clock, a stale
 * cached season setting or a hand-edited payload must never be able to file a
 * note into the wrong vintage — that would quietly corrupt every future report
 * for that season.
 */
data class VintageNote(
    /** Client-generated UUID — the offline idempotency key. */
    val id: String,
    val vineyardId: String,
    val noteDateIso: String,
    /** Locally resolved for display; the server's value wins after sync. */
    val vintageYear: Int,
    val noteTypeId: String?,
    val noteTypeLabelSnapshot: String?,
    val notes: String?,
    val observedByUserId: String?,
    val observerNameSnapshot: String?,
    val createdAtIso: String,
    val updatedAtIso: String,
    val clientUpdatedAtIso: String,
    val syncVersion: Long = 0,
    val deletedAtIso: String? = null,
) {
    val isDeleted: Boolean get() = deletedAtIso != null

    /**
     * True when the note was changed after it was first written. Compared on
     * whole seconds: a create path that stamps `created_at` and `updated_at`
     * microseconds apart must not label a brand-new note as edited.
     */
    val isEdited: Boolean
        get() = updatedAtIso.take(19) > createdAtIso.take(19)

    /** Short single-line preview for the list. */
    fun preview(maxLength: Int = 80): String {
        val text = notes?.replace(Regex("\\s+"), " ")?.trim().orEmpty()
        if (text.isEmpty()) return ""
        return if (text.length <= maxLength) text else text.take(maxLength - 1).trimEnd() + "\u2026"
    }

    /** What the list shows as the note's heading. */
    fun displayType(): String = noteTypeLabelSnapshot?.takeIf { it.isNotBlank() } ?: "Note"
}

/** The editable state of the Vintage Note form. */
data class VintageNoteDraft(
    val id: String = UUID.randomUUID().toString(),
    val date: LocalDate = LocalDate.now(),
    val noteTypeId: String? = null,
    val noteTypeLabel: String? = null,
    val notes: String = "",
) {
    /**
     * The save rule: a note needs a type OR some text.
     *
     * Only the both-empty case is refused. A type on its own is a legitimate
     * record ("Frost", on this date, is a complete and useful statement), and
     * text on its own is equally legitimate when nothing in the catalogue
     * fits. Refusing either would push observers into picking an inaccurate
     * type just to get past validation.
     */
    val canSave: Boolean
        get() = !noteTypeId.isNullOrBlank() || notes.isNotBlank()

    val blockedReason: String?
        get() = if (canSave) null else VintageNoteRules.EMPTY_MESSAGE

    /** Vintage shown in the form, resolved exactly as the server will. */
    fun resolvedVintage(seasonStartMonth: Int, seasonStartDay: Int): Int =
        VintageResolver.vintageYear(date, seasonStartMonth, seasonStartDay)
}

object VintageNoteRules {
    const val EMPTY_MESSAGE: String =
        "Add a note type or some notes before saving."

    const val VINTAGE_SERVER_NOTE: String =
        "Vintage is set from the date by the server using this vineyard's season settings."

    /** Newest first; ties broken by creation time so the order is stable. */
    fun sortedForDisplay(notes: List<VintageNote>): List<VintageNote> =
        notes.filterNot { it.isDeleted }
            .sortedWith(
                compareByDescending<VintageNote> { it.noteDateIso }
                    .thenByDescending { it.createdAtIso },
            )

    /** Notes belonging to one vintage, newest first. */
    fun forVintage(notes: List<VintageNote>, vintageYear: Int): List<VintageNote> =
        sortedForDisplay(notes).filter { it.vintageYear == vintageYear }

    /** Vineyard-scoped history; a null vintage means All vintages. */
    fun history(
        notes: List<VintageNote>,
        vineyardId: String,
        vintageYear: Int?,
    ): List<VintageNote> = sortedForDisplay(notes)
        .filter { it.vineyardId == vineyardId }
        .filter { vintageYear == null || it.vintageYear == vintageYear }
}

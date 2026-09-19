package com.rork.vinetrack.data.insights

import com.rork.vinetrack.data.VintageResolver
import java.time.Instant
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Vintage Notes capture rules.
 *
 * The recurring theme is that a note is a HISTORICAL CLAIM about a season: once
 * written it must keep saying what the observer said, and it must be filed
 * against the vintage the server decides, not the one a device happened to
 * calculate.
 */
class VintageNotesTest {

    private val vineyardId = "vineyard-1"
    private val otherVineyardId = "vineyard-2"

    /** In-memory storage so the durability rules run without Android. */
    private class MemoryStore : InsightsKeyValueStore {
        val values = mutableMapOf<String, String>()
        val removedKeys = mutableListOf<String>()
        var failWrites = false

        override fun read(key: String): String? = values[key]

        override fun write(key: String, value: String): Boolean {
            if (failWrites) return false
            values[key] = value
            return true
        }

        override fun remove(key: String): Boolean {
            removedKeys += key
            values.remove(key)
            return true
        }
    }

    private val raw = MemoryStore()
    private var clockMillis = 1_757_000_000_000L
    private val store = VineyardInsightsStore(raw)
    private val controller = VineyardInsightsController(store) { Instant.ofEpochMilli(clockMillis) }

    private fun tick(millis: Long = 1_000L) {
        clockMillis += millis
    }

    private fun save(
        draft: VintageNoteDraft,
        seasonStartMonth: Int = 7,
        seasonStartDay: Int = 1,
        vineyard: String = vineyardId,
    ): VintageNote? = controller.saveNote(
        draft = draft,
        vineyardId = vineyard,
        observedByUserId = "user-1",
        observerName = "Jonathan",
        seasonStartMonth = seasonStartMonth,
        seasonStartDay = seasonStartDay,
    )

    // --- Vintage resolution -----------------------------------------------

    @Test
    fun `the vintage follows the configured season boundary not the calendar year`() {
        // 1 July start: the season is labelled with the year it ENDS.
        val june = VintageNoteDraft(date = LocalDate.of(2026, 6, 30))
        val july = VintageNoteDraft(date = LocalDate.of(2026, 7, 1))

        assertEquals(2026, june.resolvedVintage(7, 1))
        assertEquals(2027, july.resolvedVintage(7, 1))
    }

    @Test
    fun `a january season start labels the vintage with its own calendar year`() {
        // A season contained in one calendar year IS that year — the one case
        // where the season-end-year rule collapses to the calendar year.
        val draft = VintageNoteDraft(date = LocalDate.of(2026, 2, 15))

        assertEquals(2026, draft.resolvedVintage(1, 1))
    }

    @Test
    fun `changing the note date recalculates the vintage`() {
        var draft = VintageNoteDraft(date = LocalDate.of(2026, 6, 30), notes = "Frost damage")
        val before = save(draft)
        assertEquals(2026, before?.vintageYear)

        tick()
        draft = draft.copy(date = LocalDate.of(2026, 7, 2))
        val after = save(draft)

        assertEquals(
            "moving the date across the season boundary must move the vintage",
            2027,
            after?.vintageYear,
        )
        assertEquals("and must edit the same note, not create a second", 1, controller.notes.value.size)
    }

    @Test
    fun `the client vintage mirrors the authoritative resolver exactly`() {
        // This value is display-only; the server recomputes it. The mirror
        // still has to agree, or the operator is shown one vintage and the
        // record is filed under another.
        val date = LocalDate.of(2026, 11, 15)
        val draft = VintageNoteDraft(date = date)

        assertEquals(
            VintageResolver.vintageYear(date, 11, 1),
            draft.resolvedVintage(11, 1),
        )
    }

    // --- The save rule ----------------------------------------------------

    @Test
    fun `an empty type and empty notes cannot save`() {
        val draft = VintageNoteDraft()

        assertFalse(draft.canSave)
        assertEquals(VintageNoteRules.EMPTY_MESSAGE, draft.blockedReason)
        assertNull("a note recording nothing must not reach storage", save(draft))
        assertTrue(controller.notes.value.isEmpty())
    }

    @Test
    fun `whitespace-only notes with no type cannot save`() {
        assertFalse(VintageNoteDraft(notes = "   \n  ").canSave)
    }

    @Test
    fun `notes alone can save`() {
        // Legitimate when nothing in the catalogue fits. Refusing this would
        // push observers into picking an inaccurate type to get past validation.
        val draft = VintageNoteDraft(notes = "Heavy dew through the low block all week")

        assertTrue(draft.canSave)
        assertNotNull(save(draft))
        assertEquals(1, controller.notes.value.size)
    }

    @Test
    fun `a type alone can save`() {
        // "Frost", on this date, is a complete and useful statement.
        val frost = VintageNoteCatalog.systemType("frost")
        requireNotNull(frost)
        val draft = VintageNoteDraft(noteTypeId = frost.code, noteTypeLabel = frost.label)

        assertTrue(draft.canSave)
        val saved = save(draft)
        assertEquals("Frost", saved?.noteTypeLabelSnapshot)
    }

    // --- Label snapshots --------------------------------------------------

    @Test
    fun `a historical label survives the type being renamed`() {
        val frost = VintageNoteCatalog.systemType("frost")
        requireNotNull(frost)
        val saved = save(
            VintageNoteDraft(noteTypeId = frost.code, noteTypeLabel = frost.label, notes = "Low block"),
        )
        requireNotNull(saved)

        // The vineyard later renames the type. The catalogue changes; the note
        // must not — it records what the observer actually chose.
        val renamed = frost.copy(label = "Frost event (severe)")
        controller.addCustomNoteType(vineyardId, renamed.label)

        val reloaded = controller.notes.value.single()
        assertEquals("Frost", reloaded.noteTypeLabelSnapshot)
        assertEquals(frost.code, reloaded.noteTypeId)
    }

    @Test
    fun `an edit that does not touch the type keeps the original label snapshot`() {
        val hail = VintageNoteCatalog.systemType("hail")
        requireNotNull(hail)
        val saved = save(VintageNoteDraft(noteTypeId = hail.code, noteTypeLabel = hail.label))
        requireNotNull(saved)

        tick()
        // The form carries no label this time — a blank must not erase history.
        val edited = save(
            VintageNoteDraft(id = saved.id, noteTypeId = hail.code, notes = "Northern rows only"),
        )

        assertEquals("Hail", edited?.noteTypeLabelSnapshot)
    }

    @Test
    fun `a retired type stays readable on an existing note but leaves the picker`() {
        val custom = controller.addCustomNoteType(vineyardId, "Contractor delay")
        requireNotNull(custom)
        val saved = save(VintageNoteDraft(noteTypeId = custom.code, noteTypeLabel = custom.label))
        requireNotNull(saved)

        val retired = custom.copy(isActive = false)
        val selectable = VintageNoteCatalog.selectable(listOf(retired))

        assertFalse(
            "a retired type is not offered for new notes",
            selectable.any { it.code == custom.code },
        )
        assertEquals(
            "but the existing note still says what was chosen",
            "Contractor delay",
            controller.notes.value.single().noteTypeLabelSnapshot,
        )
    }

    // --- Custom types -----------------------------------------------------

    @Test
    fun `a custom type stays scoped to its own vineyard`() {
        controller.addCustomNoteType(vineyardId, "Creek crossing washed out")

        assertEquals(1, controller.noteTypes(vineyardId).size)
        assertTrue(
            "another vineyard must never see it",
            controller.noteTypes(otherVineyardId).isEmpty(),
        )
    }

    @Test
    fun `a blank custom type label is refused`() {
        assertNull(controller.addCustomNoteType(vineyardId, "   "))
    }

    // --- Offline behaviour ------------------------------------------------

    @Test
    fun `an offline retry of the same capture creates one note only`() {
        // The draft id is the idempotency key. A replay of the same capture is
        // an update of one row, never a second note about the same event.
        val draft = VintageNoteDraft(notes = "Hail through Block 4")

        save(draft)
        tick()
        save(draft)
        tick()
        save(draft)

        assertEquals(1, controller.notes.value.size)
    }

    @Test
    fun `each queued operation carries its own vineyard`() {
        // Replay must never consult the currently selected vineyard: an
        // operator who captures, drives home and switches vineyards would
        // otherwise file the morning's work against someone else's business.
        save(VintageNoteDraft(notes = "First vineyard"), vineyard = vineyardId)
        tick()
        save(VintageNoteDraft(notes = "Second vineyard"), vineyard = otherVineyardId)

        val queued = store.loadQueue()
        assertEquals(2, queued.size)
        assertEquals(setOf(vineyardId, otherVineyardId), queued.map { it.vineyardId }.toSet())
    }

    @Test
    fun `repeated offline edits collapse to one pending upsert`() {
        val draft = VintageNoteDraft(notes = "First")
        save(draft)
        tick()
        save(draft.copy(notes = "Second"))
        tick()
        save(draft.copy(notes = "Third"))

        val queued = store.loadQueue()
        assertEquals("five races into a different final answer; one does not", 1, queued.size)
        assertEquals(VineyardInsightsStore.QueuedOperation.Operation.UPSERT, queued.single().operation)
    }

    @Test
    fun `a delete supersedes a pending upsert for the same note`() {
        val saved = save(VintageNoteDraft(notes = "Mistaken entry"))
        requireNotNull(saved)
        tick()

        controller.deleteNote(saved.id)

        val queued = store.loadQueue()
        assertEquals(1, queued.size)
        assertEquals(VineyardInsightsStore.QueuedOperation.Operation.DELETE, queued.single().operation)
    }

    @Test
    fun `deletion physically removes the local note`() {
        val saved = save(VintageNoteDraft(notes = "Wrong date"))
        requireNotNull(saved)
        tick()

        controller.deleteNote(saved.id)

        assertTrue(controller.notes.value.isEmpty())
        assertTrue(controller.notesForVintage(saved.vintageYear).isEmpty())
    }

    @Test
    fun `a failed local write is reported rather than silently accepted`() {
        raw.failWrites = true

        val result = save(VintageNoteDraft(notes = "Frost"))

        assertNull(result)
        assertTrue(
            "the operator must be told a capture did not save",
            controller.lastWriteFailed.value,
        )
    }

    @Test
    fun `sign out removes every locally held note`() = kotlinx.coroutines.test.runTest {
        save(VintageNoteDraft(notes = "Preview data"))
        assertEquals(1, controller.notes.value.size)

        controller.clearForSignOut()

        assertTrue(controller.notes.value.isEmpty())
        assertTrue(store.loadNotes().isEmpty())
    }

    // --- Display ----------------------------------------------------------

    @Test
    fun `notes list newest first`() {
        save(VintageNoteDraft(date = LocalDate.of(2026, 8, 1), notes = "Older"))
        tick()
        save(VintageNoteDraft(date = LocalDate.of(2026, 9, 1), notes = "Newer"))

        val ordered = controller.notesForVintage(2027)

        assertEquals(listOf("Newer", "Older"), ordered.map { it.notes })
    }

    @Test
    fun `a brand new note is not marked as edited`() {
        val saved = save(VintageNoteDraft(notes = "Fresh"))

        assertFalse(saved?.isEdited ?: true)
    }

    @Test
    fun `an edited note is marked as edited`() {
        val saved = save(VintageNoteDraft(notes = "Original"))
        requireNotNull(saved)

        tick(5_000L)
        val edited = save(VintageNoteDraft(id = saved.id, notes = "Amended"))

        assertTrue(edited?.isEdited ?: false)
    }

    @Test
    fun `the preview collapses whitespace and truncates long notes`() {
        val saved = save(VintageNoteDraft(notes = "a".repeat(200)))
        requireNotNull(saved)

        assertEquals(80, saved.preview().length)
        assertTrue(saved.preview().endsWith("\u2026"))
    }

    // --- Catalogue parity -------------------------------------------------

    @Test
    fun `the seeded catalogue matches the count seeded by SQL 236`() {
        assertEquals(39, VintageNoteCatalog.systemTypes.size)
    }

    @Test
    fun `weather types lead the grouped picker`() {
        // The most commonly recorded events must be reachable first.
        val groups = VintageNoteCatalog.grouped(emptyList()).map { it.first }

        assertEquals(
            listOf(
                VintageNoteGroup.WEATHER,
                VintageNoteGroup.PHENOLOGY,
                VintageNoteGroup.DISEASE,
                VintageNoteGroup.ACTIVITY,
                VintageNoteGroup.OTHER,
            ),
            groups,
        )
        assertEquals("Frost", VintageNoteCatalog.grouped(emptyList()).first().second.first().label)
    }

    @Test
    fun `search is case insensitive and a blank query returns everything`() {
        assertTrue(VintageNoteCatalog.search("HAIL", emptyList()).any { it.code == "hail" })
        assertEquals(
            VintageNoteCatalog.systemTypes.size,
            VintageNoteCatalog.search("  ", emptyList()).size,
        )
    }

    @Test
    fun `custom types appear in the picker alongside the seeded ones`() {
        val custom = controller.addCustomNoteType(vineyardId, "Contractor delay")
        requireNotNull(custom)

        val selectable = VintageNoteCatalog.selectable(listOf(custom))

        assertTrue(selectable.any { it.code == custom.code })
        assertTrue(selectable.any { it.code == "frost" })
    }
}

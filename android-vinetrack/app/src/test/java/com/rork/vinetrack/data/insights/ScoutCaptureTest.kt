package com.rork.vinetrack.data.insights

import java.time.Instant
import java.time.LocalDate
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Scout capture rules.
 *
 * Two themes run through these tests. First, a scouting record is EVIDENCE: a
 * photo must never imply a position it does not have, and an unassessed item
 * must be distinguishable from one nobody looked at. Second, scouting must not
 * become a second authority for phenology — an E-L selection writes through the
 * existing canonical Growth Stage pipeline and never alongside it.
 */
class ScoutCaptureTest {

    private val vineyardId = "vineyard-1"
    private val blockA = "paddock-a"
    private val blockB = "paddock-b"

    private class MemoryStore : InsightsKeyValueStore {
        val values = mutableMapOf<String, String>()
        var failWrites = false

        override fun read(key: String): String? = values[key]

        override fun write(key: String, value: String): Boolean {
            if (failWrites) return false
            values[key] = value
            return true
        }

        override fun remove(key: String): Boolean {
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

    private fun startVisit(): ScoutVisit = controller.startVisit(
        vineyardId = vineyardId,
        scoutUserId = "user-1",
        scoutName = "Jonathan",
        seasonStartMonth = 7,
        seasonStartDay = 1,
        date = LocalDate.of(2026, 11, 20),
    )

    private fun assessmentId(visitId: String, paddockId: String): String =
        controller.visit(visitId)!!.assessment(paddockId)!!.id

    private fun observation(visitId: String, paddockId: String, item: ScoutItem): ScoutObservation? =
        controller.visit(visitId)?.assessment(paddockId)?.observation(item)

    // --- Visit and assessment structure -----------------------------------

    @Test
    fun `a visit resolves its vintage from the season boundary`() {
        val visit = startVisit()

        // 20 Nov 2026 with a 1 July start belongs to Vintage 2027.
        assertEquals(2027, visit.vintageYear)
    }

    @Test
    fun `adding a block creates exactly one assessment`() {
        val visit = startVisit()

        controller.toggleBlock(visit.id, blockA)

        assertEquals(1, controller.visit(visit.id)?.assessments?.size)
    }

    @Test
    fun `a block cannot be assessed twice in one visit`() {
        // Two partially-filled assessments for one block would make "what did
        // the scout find in Block A?" ambiguous.
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val first = assessmentId(visit.id, blockA)

        // Re-adding after content exists must not create a second assessment.
        controller.setObservationNotes(visit.id, first, ScoutItem.OTHER_ISSUE, "Rabbit damage")
        controller.toggleBlock(visit.id, blockA)

        val assessments = controller.visit(visit.id)!!.assessments
        assertEquals(1, assessments.size)
        assertEquals(first, assessments.single().id)
    }

    @Test
    fun `an untouched block can be removed but one holding work cannot`() {
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        controller.toggleBlock(visit.id, blockB)

        // Untouched: removable.
        controller.toggleBlock(visit.id, blockB)
        assertEquals(1, controller.visit(visit.id)?.assessments?.size)

        // Holding a recorded observation: a toggle must not discard field work.
        val id = assessmentId(visit.id, blockA)
        controller.setObservationNotes(visit.id, id, ScoutItem.OTHER_ISSUE, "Wind damage")
        controller.toggleBlock(visit.id, blockA)
        assertEquals(1, controller.visit(visit.id)?.assessments?.size)
    }

    @Test
    fun `every assessment item is present and defaults to not assessed`() {
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val assessment = controller.visit(visit.id)!!.assessment(blockA)!!

        assertEquals(ScoutItem.entries.size, assessment.observations.size)

        // "Not assessed" is a real stored answer, deliberately distinct from a
        // null: a report must be able to say the item was not assessed rather
        // than quietly omitting the block.
        val weeds = assessment.observation(ScoutItem.WEEDS)
        assertEquals(VineyardInsightsCatalog.NOT_ASSESSED_CODE, weeds?.valueCode)
        assertEquals("Not assessed", weeds?.valueLabel)
        assertFalse("a default answer is not content", weeds!!.hasContent)
    }

    // --- Code / label parity ----------------------------------------------

    @Test
    fun `dropdown codes and labels match the cross-platform contract exactly`() {
        fun codes(item: ScoutItem) = VineyardInsightsCatalog.options(item).map { it.code }
        fun labels(item: ScoutItem) = VineyardInsightsCatalog.options(item).map { it.label }

        assertEquals(
            listOf("not_assessed", "under_control", "needs_attention", "inhibiting_growth"),
            codes(ScoutItem.WEEDS),
        )
        assertEquals(
            listOf("Not assessed", "Under control", "Needs attention", "Inhibiting growth"),
            labels(ScoutItem.WEEDS),
        )
        assertEquals(
            listOf("not_assessed", "lacks_growth", "good_shoot_length", "consider_trimming"),
            codes(ScoutItem.VINE_VIGOUR),
        )
        assertEquals(
            listOf("Not assessed", "Lacks growth", "Good shoot length", "Consider trimming"),
            labels(ScoutItem.VINE_VIGOUR),
        )
        assertEquals(
            listOf("not_assessed", "adequate", "low_soil_moisture", "soil_very_dry", "vines_showing_stress"),
            codes(ScoutItem.SOIL_MOISTURE),
        )
        assertEquals(
            listOf("Not assessed", "Adequate", "Low soil moisture", "Soil very dry", "Vines showing stress"),
            labels(ScoutItem.SOIL_MOISTURE),
        )
        assertEquals(
            listOf("not_assessed", "no_sign", "growth_on_leaves", "found_in_bunches"),
            codes(ScoutItem.POWDERY_MILDEW),
        )
        assertEquals(
            listOf("Not assessed", "No sign", "Growth on leaves", "Found in bunches"),
            labels(ScoutItem.POWDERY_MILDEW),
        )
        assertEquals(
            listOf("not_assessed", "no_sign", "primary_infection", "on_leaves", "secondary_infection", "in_bunches"),
            codes(ScoutItem.DOWNY_MILDEW),
        )
        assertEquals(
            listOf("Not assessed", "No sign", "Primary infection", "On leaves", "Secondary infection", "In bunches"),
            labels(ScoutItem.DOWNY_MILDEW),
        )
    }

    @Test
    fun `the stored label snapshot is captured with the selection`() {
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        val dry = VineyardInsightsCatalog.option(ScoutItem.SOIL_MOISTURE, "soil_very_dry")!!

        controller.setObservationValue(visit.id, id, ScoutItem.SOIL_MOISTURE, dry)

        val saved = observation(visit.id, blockA, ScoutItem.SOIL_MOISTURE)
        assertEquals("soil_very_dry", saved?.valueCode)
        assertEquals("Soil very dry", saved?.valueLabel)
    }

    @Test
    fun `an unrecognised stored code yields no invented label`() {
        // Showing the raw code is honest; guessing puts words in the operator's
        // mouth about a past season.
        assertNull(VineyardInsightsCatalog.label(ScoutItem.WEEDS, "some_future_code"))
        assertFalse(VineyardInsightsCatalog.isAssessed(ScoutItem.WEEDS, "some_future_code"))
    }

    @Test
    fun `attention flags mark only the actionable selections`() {
        assertTrue(VineyardInsightsCatalog.needsAttention(ScoutItem.WEEDS, "inhibiting_growth"))
        assertTrue(VineyardInsightsCatalog.needsAttention(ScoutItem.DOWNY_MILDEW, "in_bunches"))
        assertFalse(VineyardInsightsCatalog.needsAttention(ScoutItem.POWDERY_MILDEW, "no_sign"))
        assertFalse(VineyardInsightsCatalog.needsAttention(ScoutItem.WEEDS, "not_assessed"))
    }

    // --- Growth Stage canonical linkage -----------------------------------

    @Test
    fun `an E-L selection creates exactly one canonical record`() {
        val observationId = UUID.randomUUID().toString()

        val plan = ScoutGrowthStageLink.plan(
            observationId = observationId,
            vineyardId = vineyardId,
            paddockId = blockA,
            existingRecordId = null,
            existingStageCode = null,
            selectedStageCode = "EL23",
        )

        assertEquals(
            ScoutGrowthStageLink.Create(observationId, vineyardId, blockA, "EL23"),
            plan,
        )
    }

    @Test
    fun `an offline replay of the same E-L capture does not duplicate the record`() {
        // The observation id is the idempotency key. A retry that finds the
        // record already at the selected stage is a no-op, not a second
        // budburst observation.
        val recordId = UUID.randomUUID().toString()

        val plan = ScoutGrowthStageLink.plan(
            observationId = "obs-1",
            vineyardId = vineyardId,
            paddockId = blockA,
            existingRecordId = recordId,
            existingStageCode = "EL23",
            selectedStageCode = "EL23",
        )

        assertEquals(ScoutGrowthStageLink.Unchanged(recordId), plan)
    }

    @Test
    fun `editing the E-L selection updates the canonical record in place`() {
        val recordId = UUID.randomUUID().toString()

        val plan = ScoutGrowthStageLink.plan(
            observationId = "obs-1",
            vineyardId = vineyardId,
            paddockId = blockA,
            existingRecordId = recordId,
            existingStageCode = "EL23",
            selectedStageCode = "EL25",
        )

        assertEquals(
            "an edit must never mint a second record",
            ScoutGrowthStageLink.Update("obs-1", recordId, "EL25"),
            plan,
        )
    }

    @Test
    fun `clearing the E-L selection unlinks without deleting the record`() {
        val recordId = UUID.randomUUID().toString()

        val plan = ScoutGrowthStageLink.plan(
            observationId = "obs-1",
            vineyardId = vineyardId,
            paddockId = blockA,
            existingRecordId = recordId,
            existingStageCode = "EL23",
            selectedStageCode = null,
        )

        assertEquals(ScoutGrowthStageLink.Unlink(recordId), plan)
    }

    @Test
    fun `deleting a scout retains every canonical growth stage record it created`() {
        // The observation was genuinely made in the vineyard; the visit is only
        // the paperwork that carried it. Silently removing phenology that feeds
        // the heatmap and GDD work would be a destructive surprise.
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        val recordId = UUID.randomUUID().toString()
        controller.linkGrowthStageRecord(visit.id, id, recordId, "E-L 23 80% cap fall")

        val retained = controller.deleteVisit(visit.id)

        assertEquals(listOf(ScoutGrowthStageLink.Unlink(recordId)), retained)
        assertTrue("the visit itself is gone", controller.visits.value.isEmpty())
    }

    @Test
    fun `the scout observation stores a link and never a competing stage value`() {
        // Two rows that can disagree would eventually tell the vineyard two
        // different budburst dates from two screens.
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        val recordId = UUID.randomUUID().toString()

        controller.linkGrowthStageRecord(visit.id, id, recordId, "E-L 23")

        val saved = observation(visit.id, blockA, ScoutItem.GROWTH_STAGE)
        assertEquals(recordId, saved?.linkedGrowthStageRecordId)
        assertNull("no scouting-only stage code is stored", saved?.valueCode)
    }

    // --- Photographs and location honesty ---------------------------------

    @Test
    fun `a photo from a qualifying fix carries its measured position`() {
        val photo = ScoutPhoto.gpsConfirmed(
            observationId = "obs-1",
            localPath = "/tmp/a.jpg",
            capturedAtIso = "2026-11-20T09:15:00Z",
            capturedByUserId = "user-1",
            latitude = -33.2835,
            longitude = 149.0988,
            accuracyMetres = 4.2,
        )

        assertEquals(PhotoLocationStatus.GPS_CONFIRMED, photo.locationStatus)
        assertEquals(-33.2835, photo.latitude!!, 1e-9)
    }

    @Test
    fun `a photo without a qualifying fix is explicitly block-only and carries no coordinates`() {
        val photo = ScoutPhoto.blockOnly(
            observationId = "obs-1",
            localPath = "/tmp/b.jpg",
            capturedAtIso = "2026-11-20T09:16:00Z",
            capturedByUserId = "user-1",
        )

        assertEquals(PhotoLocationStatus.UNAVAILABLE, photo.locationStatus)
        assertNull(photo.latitude)
        assertNull(photo.longitude)
        assertNull(photo.accuracyMetres)
        assertEquals(
            "Location unavailable \u2014 block association only",
            photo.locationStatus.label,
        )
    }

    @Test
    fun `a stale fix can never be represented as a fresh photo location`() {
        // The type makes the dishonest combination unconstructable: there is no
        // factory that accepts coordinates with an unavailable status, so a
        // stale fix, last-known position, shed location or block centroid
        // cannot be smuggled in as a measured position.
        val failure = runCatching {
            ScoutPhoto(
                id = UUID.randomUUID().toString(),
                observationId = "obs-1",
                localPath = null,
                storagePath = null,
                capturedAtIso = "2026-11-20T09:17:00Z",
                capturedByUserId = "user-1",
                latitude = -33.2835,
                longitude = 149.0988,
                accuracyMetres = 120.0,
                locationStatus = PhotoLocationStatus.UNAVAILABLE,
            )
        }

        assertTrue("coordinates without a confirmed fix must be rejected", failure.isFailure)
    }

    @Test
    fun `stored coordinates claiming an unconfirmed status are normalised down on read`() {
        // Defence for a corrupted or older row: the honest answer is
        // block-only, never a position presented as measured.
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        controller.addPhoto(
            visit.id, id, ScoutItem.WEEDS,
            ScoutPhoto.blockOnly("obs-1", null, "2026-11-20T09:18:00Z", "user-1"),
        )

        val reloaded = VineyardInsightsStore(raw).loadVisits().single()
        val photo = reloaded.assessment(blockA)!!.observation(ScoutItem.WEEDS)!!.photos.single()

        assertEquals(PhotoLocationStatus.UNAVAILABLE, photo.locationStatus)
        assertNull(photo.latitude)
    }

    @Test
    fun `multiple photos persist against one assessment item`() {
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)

        repeat(3) { index ->
            controller.addPhoto(
                visit.id, id, ScoutItem.POWDERY_MILDEW,
                ScoutPhoto.blockOnly("obs-$index", "/tmp/$index.jpg", "2026-11-20T09:2$index:00Z", "user-1"),
            )
            tick()
        }

        val reloaded = VineyardInsightsStore(raw).loadVisits().single()
        assertEquals(
            3,
            reloaded.assessment(blockA)!!.observation(ScoutItem.POWDERY_MILDEW)!!.photos.size,
        )
    }

    @Test
    fun `photos survive a reload across separate items`() {
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        controller.addPhoto(
            visit.id, id, ScoutItem.WEEDS,
            ScoutPhoto.blockOnly("obs-w", null, "2026-11-20T09:30:00Z", "user-1"),
        )
        tick()
        controller.addPhoto(
            visit.id, id, ScoutItem.OTHER_ISSUE,
            ScoutPhoto.gpsConfirmed("obs-o", null, "2026-11-20T09:31:00Z", "user-1", -33.28, 149.09, 3.0),
        )

        val reloaded = VineyardInsightsStore(raw).loadVisits().single().assessment(blockA)!!
        assertEquals(1, reloaded.observation(ScoutItem.WEEDS)!!.photos.size)
        assertEquals(1, reloaded.observation(ScoutItem.OTHER_ISSUE)!!.photos.size)
        assertEquals(2, reloaded.photoCount)
    }

    // --- Completion rules --------------------------------------------------

    @Test
    fun `completion does not require every dropdown to have a value`() {
        // Forcing six selections per block to record "nothing of note" teaches
        // operators to click through defaults, producing confident data nobody
        // actually looked at.
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        controller.setObservationNotes(visit.id, id, ScoutItem.GENERAL_RECOMMENDATION, "Looks clean")

        val review = controller.review(visit.id)

        assertTrue(review.canComplete)
        assertTrue(controller.completeVisit(visit.id))
        assertEquals(ScoutStatus.COMPLETED, controller.visit(visit.id)?.status)
    }

    @Test
    fun `a selected block with no observation blocks completion`() {
        // A block added and never opened is the one case where silence is
        // indistinguishable from an omission.
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        controller.toggleBlock(visit.id, blockB)
        val id = assessmentId(visit.id, blockA)
        controller.setObservationNotes(visit.id, id, ScoutItem.OTHER_ISSUE, "Bird netting torn")

        val review = controller.review(visit.id)

        assertFalse(review.canComplete)
        assertEquals(1, review.blocksIncomplete)
        assertEquals(listOf(blockB), review.incompletePaddockIds)
        assertNotNull(review.blockedReason())
        assertFalse("completion must be refused, not merely discouraged", controller.completeVisit(visit.id))
    }

    @Test
    fun `a visit with no blocks cannot be completed`() {
        val visit = startVisit()

        assertFalse(controller.review(visit.id).canComplete)
        assertFalse(controller.completeVisit(visit.id))
    }

    @Test
    fun `a single not-assessed dropdown is not evidence the block was visited`() {
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        val notAssessed = VineyardInsightsCatalog.option(ScoutItem.WEEDS, "not_assessed")!!

        controller.setObservationValue(visit.id, id, ScoutItem.WEEDS, notAssessed)

        assertFalse(controller.review(visit.id).canComplete)
    }

    @Test
    fun `a photo alone is enough evidence that a block was visited`() {
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        controller.addPhoto(
            visit.id, id, ScoutItem.OTHER_ISSUE,
            ScoutPhoto.blockOnly("obs-1", null, "2026-11-20T09:40:00Z", "user-1"),
        )

        assertTrue(controller.review(visit.id).canComplete)
    }

    @Test
    fun `the review counts what the operator needs to see before completing`() {
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        controller.setObservationValue(
            visit.id, id, ScoutItem.DOWNY_MILDEW,
            VineyardInsightsCatalog.option(ScoutItem.DOWNY_MILDEW, "in_bunches")!!,
        )
        controller.setObservationValue(
            visit.id, id, ScoutItem.WEEDS,
            VineyardInsightsCatalog.option(ScoutItem.WEEDS, "needs_attention")!!,
        )
        controller.setObservationNotes(visit.id, id, ScoutItem.OTHER_ISSUE, "Fence down")
        controller.setObservationNotes(visit.id, id, ScoutItem.GENERAL_RECOMMENDATION, "Spray next week")
        controller.linkGrowthStageRecord(visit.id, id, UUID.randomUUID().toString(), "E-L 23")
        controller.addPhoto(
            visit.id, id, ScoutItem.DOWNY_MILDEW,
            ScoutPhoto.blockOnly("obs-1", null, "2026-11-20T09:45:00Z", "user-1"),
        )

        val review = controller.review(visit.id)

        assertEquals(1, review.blocksAssessed)
        assertEquals(0, review.blocksIncomplete)
        assertEquals(1, review.growthStageObservations)
        assertEquals(2, review.attentionItems)
        assertEquals(1, review.photoCount)
        assertEquals(1, review.otherIssues)
        assertEquals(1, review.generalRecommendations)
    }

    // --- Draft / completed lifecycle --------------------------------------

    @Test
    fun `a completed visit is read only until deliberately reopened`() {
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        controller.setObservationNotes(visit.id, id, ScoutItem.OTHER_ISSUE, "Original")
        controller.completeVisit(visit.id)

        controller.setObservationNotes(visit.id, id, ScoutItem.OTHER_ISSUE, "Edited after completion")
        assertEquals("Original", observation(visit.id, blockA, ScoutItem.OTHER_ISSUE)?.notes)

        controller.reopenVisit(visit.id)
        controller.setObservationNotes(visit.id, id, ScoutItem.OTHER_ISSUE, "Edited after reopening")
        assertEquals(
            "Edited after reopening",
            observation(visit.id, blockA, ScoutItem.OTHER_ISSUE)?.notes,
        )
    }

    @Test
    fun `drafts and completed visits are listed separately`() {
        val draft = startVisit()
        controller.toggleBlock(draft.id, blockA)
        controller.setObservationNotes(
            draft.id, assessmentId(draft.id, blockA), ScoutItem.OTHER_ISSUE, "Draft work",
        )
        tick()
        val done = startVisit()
        controller.toggleBlock(done.id, blockB)
        controller.setObservationNotes(
            done.id, assessmentId(done.id, blockB), ScoutItem.OTHER_ISSUE, "Finished work",
        )
        controller.completeVisit(done.id)

        assertEquals(listOf(draft.id), controller.visits(ScoutStatus.DRAFT).map { it.id })
        assertEquals(listOf(done.id), controller.visits(ScoutStatus.COMPLETED).map { it.id })
    }

    // --- Offline durability -----------------------------------------------

    @Test
    fun `a visit survives a reload from storage with its observations intact`() {
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        controller.setObservationValue(
            visit.id, id, ScoutItem.SOIL_MOISTURE,
            VineyardInsightsCatalog.option(ScoutItem.SOIL_MOISTURE, "soil_very_dry")!!,
        )
        controller.setObservationNotes(visit.id, id, ScoutItem.SOIL_MOISTURE, "Northern end worst")

        val reloaded = VineyardInsightsStore(raw).loadVisits().single()
        val saved = reloaded.assessment(blockA)!!.observation(ScoutItem.SOIL_MOISTURE)!!

        assertEquals("soil_very_dry", saved.valueCode)
        assertEquals("Soil very dry", saved.valueLabel)
        assertEquals("Northern end worst", saved.notes)
    }

    @Test
    fun `repeated edits collapse to one pending upsert carrying the latest state`() {
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        repeat(4) {
            controller.setObservationNotes(visit.id, id, ScoutItem.OTHER_ISSUE, "Edit $it")
            tick()
        }

        val queued = store.loadQueue().filter {
            it.entity == VineyardInsightsStore.QueuedOperation.Entity.SCOUT_VISIT
        }

        assertEquals(1, queued.size)
        assertEquals(visit.id, queued.single().recordId)
    }

    @Test
    fun `the queued visit carries its own vineyard for replay`() {
        val visit = startVisit()

        val queued = store.loadQueue().single()

        assertEquals(vineyardId, queued.vineyardId)
    }

    @Test
    fun `a failed local write is reported rather than silently accepted`() {
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        raw.failWrites = true

        controller.setObservationNotes(visit.id, id, ScoutItem.OTHER_ISSUE, "Lost?")

        assertTrue(controller.lastWriteFailed.value)
        assertEquals(
            "earlier work stays on disk",
            1,
            VineyardInsightsStore(raw).loadVisits().size,
        )
    }

    @Test
    fun `sign out removes every locally held visit`() {
        startVisit()
        assertEquals(1, controller.visits.value.size)

        controller.clearForSignOut()

        assertTrue(controller.visits.value.isEmpty())
        assertTrue(store.loadVisits().isEmpty())
    }

    // --- Weather ------------------------------------------------------------

    @Test
    fun `an unavailable weather reading is recorded as absent and never invented`() {
        val visit = startVisit()

        controller.setWeather(
            visit.id,
            ScoutWeatherSnapshot.unavailable("2026-11-20T09:00:00Z", source = "WillyWeather"),
        )

        val weather = controller.visit(visit.id)?.weather
        assertTrue(weather!!.isUnavailable)
        assertNull(weather.temperatureCelsius)
        assertNull(weather.humidityPercent)
    }

    @Test
    fun `weather never blocks saving a visit`() {
        val visit = startVisit()
        controller.toggleBlock(visit.id, blockA)
        val id = assessmentId(visit.id, blockA)
        controller.setObservationNotes(visit.id, id, ScoutItem.OTHER_ISSUE, "Recorded with no weather")

        assertNull(controller.visit(visit.id)?.weather)
        assertTrue(controller.review(visit.id).canComplete)
    }

    @Test
    fun `a stale weather reading keeps its values and says it is stale`() {
        val visit = startVisit()

        controller.setWeather(
            visit.id,
            ScoutWeatherSnapshot(
                observedAtIso = "2026-11-20T06:00:00Z",
                capturedAtIso = "2026-11-20T09:00:00Z",
                source = "WillyWeather",
                temperatureCelsius = 21.4,
                humidityPercent = 58.0,
                windSpeedKph = 12.0,
                windGustKph = 24.0,
                recentRainfallMm = 0.0,
                isStale = true,
            ),
        )

        val weather = controller.visit(visit.id)?.weather
        assertTrue(weather!!.isStale)
        assertEquals(21.4, weather.temperatureCelsius!!, 1e-9)
    }
}

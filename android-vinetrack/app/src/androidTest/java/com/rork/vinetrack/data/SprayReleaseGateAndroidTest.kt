package com.rork.vinetrack.data

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfDocument
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.model.SprayRecord
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.reporting.SprayReportPayloadV1
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

/** Offline native render/receipt assertions only; never starts a real job or contacts a backend. */
class SprayReleaseGateAndroidTest {
    @Test fun configuredSingleAndOverRowRetainExactSetupThroughReceiptAndReload() {
        val session = com.rork.vinetrack.data.auth.SessionStore(InstrumentationRegistry.getInstrumentation().targetContext)
        for (pass in com.rork.vinetrack.data.spray.SprayPassConfiguration.entries) {
            val intent = com.rork.vinetrack.data.spray.SprayPlanningIntent(pass, com.rork.vinetrack.data.spray.SprayPlanningMethod.BY_AREA, calibratedLitresPerHectare = 600.0)
            val resolved = requireNotNull(intent.resolve(1.0, 2.8, 612.0))
            assertEquals(16.8, resolved.physicalRowLitresPer100m!!, 1e-10)
            assertEquals(16.8 * pass.rowEquivalents, resolved.controllerLitresPer100mTravel!!, 1e-10)
            assertEquals(1.02, resolved.concentrationFactor, 0.0)
            val tank = com.rork.vinetrack.data.model.SprayTank(UUID.randomUUID().toString(), tankNumber = 1, waterVolume = 600.0, concentrationFactor = 1.02,
                chemicals = listOf(com.rork.vinetrack.data.model.SprayChemical(UUID.randomUUID().toString(), name = "Dilute", volumePerTank = 612.0, ratePer100L = 100.0, unit = "g"),
                    com.rork.vinetrack.data.model.SprayChemical(UUID.randomUUID().toString(), name = "Area", volumePerTank = 200.0, ratePerHa = 200.0, unit = "g")))
            val geometry = com.rork.vinetrack.data.spray.SprayApplicationSnapshot(grossAreaHa = 1.0, rowSpacingMetres = 2.8, totalCarrierLitres = 600.0,
                carrierLitresPerHectare = 600.0, appliedLitresPer100m = resolved.physicalRowLitresPer100m, concentrationFactor = 1.02,
                planningIntent = intent, planningResolution = resolved,
                targets = listOf(com.rork.vinetrack.data.spray.SprayTarget.POWDERY_MILDEW), sprayHeadTarget = com.rork.vinetrack.data.spray.SprayHeadTarget.FULL_CANOPY)
            val input = SprayRecordRepository.SprayInput("2026-10-15", "2026-10-15T08:00:00Z", null, null, null, null, "Configured", "Keep notes", null, null, null, null, null, null,
                sprayEquipmentId = null, operationType = "foliar_spray", tripId = UUID.randomUUID().toString(), tanks = listOf(tank), applicationGeometry = geometry)
            assertNull(input.operationalBlocker())
            assertNull(com.rork.vinetrack.data.spray.SprayStartRecipeValidation.blocker(input.tanks))
            val fields = SprayRecordRepository(session).legacyReceiptInsert(UUID.randomUUID().toString(), input, UUID.randomUUID().toString(), input.startTime, UUID.randomUUID().toString())
            assertTrue(fields.keys.all { it in LegacySprayPairReceipt.recordKeys })
            val remote = SupabaseClient.json.decodeFromJsonElement(SprayRecord.serializer(), fields)
            assertEquals(intent, remote.applicationGeometry!!.planningIntent)
            assertEquals(resolved, remote.applicationGeometry!!.planningResolution)
            assertEquals(listOf(tank), remote.tanks)
            assertTrue(remote.notes!!.startsWith("Keep notes"))
            assertNull(com.rork.vinetrack.data.spray.SprayPlanningOperationalGate.tankConfirmationBlocker(remote, remote))
            val saved = SupabaseClient.json.encodeToString(SprayRecord.serializer(), remote)
            assertEquals(resolved, SupabaseClient.json.decodeFromString(SprayRecord.serializer(), saved).applicationGeometry!!.planningResolution)
            for (factor in listOf(0.99, Double.NaN, Double.POSITIVE_INFINITY)) assertNotNull(com.rork.vinetrack.data.spray.SprayPlanningOperationalGate.blocker(false, factor, true))
            assertNotNull(com.rork.vinetrack.data.spray.SprayStartRecipeValidation.blocker(listOf(tank.copy(chemicals = listOf(tank.chemicals.first().copy(ratePer100L = 0.0))))))
        }
    }

    @Test fun freshLegacyRecipeAdmitsRecordedIntentWithoutPlanningFields() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val session = com.rork.vinetrack.data.auth.SessionStore(context)
        val tank = com.rork.vinetrack.data.model.SprayTank(id = UUID.randomUUID().toString(), tankNumber = 1, waterVolume = 420.0,
            chemicals = listOf(com.rork.vinetrack.data.model.SprayChemical(id = UUID.randomUUID().toString(), name = "Fixture", volumePerTank = 1500.0, ratePerHa = 750.0, unit = "g")))
        val input = SprayRecordRepository.SprayInput("2026-10-15", "2026-10-15T08:00:00Z",
            null, null, null, null, "Fresh legacy", null, null, null, null, null, null, null,
            sprayEquipmentId = null, operationType = "foliar_spray", tripId = UUID.randomUUID().toString(), tanks = listOf(tank),
            applicationGeometry = com.rork.vinetrack.data.spray.SprayApplicationSnapshot(
                targets = listOf(com.rork.vinetrack.data.spray.SprayTarget.POWDERY_MILDEW, com.rork.vinetrack.data.spray.SprayTarget.DOWNY_MILDEW),
                sprayHeadTarget = com.rork.vinetrack.data.spray.SprayHeadTarget.FULL_CANOPY))
        assertNull(com.rork.vinetrack.data.spray.SprayStartRecipeValidation.blocker(input.tanks))
        assertNull(input.operationalBlocker())
        val fields = SprayRecordRepository(session).legacyReceiptInsert(UUID.randomUUID().toString(), input,
            UUID.randomUUID().toString(), input.startTime, UUID.randomUUID().toString())
        assertTrue(fields.keys.all { it in LegacySprayPairReceipt.recordKeys })
        assertFalse(fields.containsKey("sprayer_configuration"))
        assertFalse(fields.containsKey("spray_planning_method"))
        assertEquals("\"full_canopy\"", fields["spray_head_target"].toString())
        assertTrue(fields["targets"].toString().contains("downy_mildew"))
    }

    @Test fun inactivePlaceholderAndDifferentEndCannotAcknowledgeOriginalIntent() {
        val time = "2026-10-15T08:00:00Z"
        val payload = TripEndSync.Payload("trip", "Recorded notes", 120.5, time, clientUpdatedAt = time, savedAt = 1)
        val ended = Trip("trip", "vineyard", endTime = time, completionNotes = "Recorded notes", endEngineHours = 120.5)
        assertTrue(TripEndSync.acknowledgesEnd(ended, payload))
        assertTrue(TripEndSync.acknowledgesEnd(ended.copy(endTime = "2026-10-15T08:00:00.000+00:00"), payload))
        for (wrong in listOf(ended.copy(endTime = null), ended.copy(isActive = true),
            ended.copy(completionNotes = null), ended.copy(endEngineHours = 120.0),
            ended.copy(endTime = "2026-10-15T08:01:00Z"), ended.copy(id = "other"))) {
            assertFalse(TripEndSync.acknowledgesEnd(wrong, payload))
        }
    }

    @Test fun recordAndPaginatedProgramPdfsRenderAllRecordedTargetsAndLocations() {
        check(Build.VERSION.SDK_INT >= 35) { "PDF text/bounds acceptance requires API 35+; not accepted on an older runner" }
        val id = UUID.randomUUID().toString()
        val trip = Trip(id, UUID.randomUUID().toString(), endTime = "2026-10-15T10:00:00Z", tripFunction = "spraying")
        val record = SprayRecord(id = UUID.randomUUID().toString(), vineyardId = trip.vineyardId, tripId = trip.id,
            targets = listOf("powdery_mildew", "downy_mildew", "Recorded target Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda"),
            sprayHeadTarget = "full_canopy", groundApplicationTarget = "undervine", applicationMode = "whole_block")
        val expected = listOf("Powdery Mildew", "Downy Mildew", "Recorded target Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda", "Full Canopy", "Undervine")
        val payload = SprayReportPayloadV1.offlineProjection(trip, record, "Isolated PDF fixture", "UTC",
            emptyList(), emptyList(), emptyList(), emptyList(), 0)
        val recordDoc = PdfDocument()
        try {
            val state = SprayRecordPdfExporter.PageState(recordDoc, null, false)
            SprayRecordPdfExporter.render(state, payload, record, "Isolated PDF fixture", emptyList(), emptyList(), trip,
                null, false, emptyList(), emptyList(), emptyList(), null, emptyList(), RegionFormatter(), null, null)
            state.finish()
            verifyPdf(recordDoc, expected, false)
        } finally { recordDoc.close() }
        val programDoc = PdfDocument()
        try {
            val state = SprayProgramPdfExporter.PageState(programDoc, null)
            SprayProgramPdfExporter.render(state, List(12) { record.copy(id = UUID.randomUUID().toString()) }, listOf(trip),
                "Isolated PDF fixture", false, emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), null,
                emptyMap(), null, RegionFormatter())
            state.finish()
            verifyPdf(programDoc, expected, true)
        } finally { programDoc.close() }
        val csv = SprayProgramCsvExporter.buildCsv(listOf(record), listOf(trip), false, emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyMap(), null)
        expected.forEach { assertTrue("CSV missing $it", csv.contains(it)) }
        assertEquals(listOf("powdery_mildew", "downy_mildew", "Recorded target Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda"), record.targets)
    }

    @android.annotation.TargetApi(35)
    private fun verifyPdf(document: PdfDocument, expected: List<String>, mustPaginate: Boolean) {
        val file = File.createTempFile("spray-gate-", ".pdf", InstrumentationRegistry.getInstrumentation().targetContext.cacheDir)
        try {
            file.outputStream().use(document::writeTo)
            PdfRenderer(ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)).use { renderer ->
                assertTrue(renderer.pageCount > 0)
                if (mustPaginate) assertTrue("Program fixture must exercise pagination", renderer.pageCount > 1)
                val text = StringBuilder()
                for (index in 0 until renderer.pageCount) renderer.openPage(index).use { page ->
                    for (content in page.textContents) {
                        text.append(content.text).append(' ')
                        for (bounds in content.bounds) {
                            assertTrue("Text clipped horizontally on page $index: $bounds", bounds.left >= 0 && bounds.right <= page.width + 1)
                            assertTrue("Text clipped vertically on page $index: $bounds", bounds.top >= 0 && bounds.bottom <= page.height + 1)
                        }
                    }
                    val bitmap = Bitmap.createBitmap(page.width, page.height, Bitmap.Config.ARGB_8888)
                    try {
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        val pixels = IntArray(bitmap.width * bitmap.height)
                        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                        assertTrue("Blank rendered page $index", pixels.count { Color.alpha(it) > 0 && (Color.red(it) < 240 || Color.green(it) < 240 || Color.blue(it) < 240) } > 100)
                    } finally { bitmap.recycle() }
                }
                val normalized = text.toString().filterNot(Char::isWhitespace)
                expected.forEach {
                    val needle = it.filterNot(Char::isWhitespace)
                    val count = normalized.windowed(needle.length).count { window -> window == needle }
                    assertEquals("PDF must retain every recorded value on every record: $it", if (mustPaginate) 12 else 1, count)
                }
            }
        } finally { file.delete() }
    }
}

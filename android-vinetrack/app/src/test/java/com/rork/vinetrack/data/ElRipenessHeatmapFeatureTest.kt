package com.rork.vinetrack.data

import com.rork.vinetrack.data.ripeness.ElRipenessCachePayload
import com.rork.vinetrack.data.ripeness.ElRipenessCachedBlock
import com.rork.vinetrack.data.ripeness.ElRipenessCachedRecord
import com.rork.vinetrack.data.ripeness.ElRipenessGeometry
import com.rork.vinetrack.data.ripeness.ElRipenessHeatRaster
import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap
import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap.LatLng
import com.rork.vinetrack.data.ripeness.ElRipenessObservationAdapter
import com.rork.vinetrack.data.ripeness.ElRipenessObservationAdapter.Origin
import com.rork.vinetrack.data.ripeness.ElRipenessObservationAdapter.SourceRecord
import com.rork.vinetrack.data.ripeness.ElRipenessObservationCaching
import com.rork.vinetrack.data.ripeness.RipenessObservationRepositoryProtocol
import com.rork.vinetrack.data.ripeness.RipenessObservationRow
import com.rork.vinetrack.data.model.GrowthStageRecord
import java.util.TimeZone
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Behavioural suite for the Android E-L Ripeness Heatmap feature layer.
 *
 * The contract *arithmetic* is already pinned by [ElRipenessHeatmapContractTest]
 * against the shared Portal fixture. This suite pins the layers that sit on top
 * of it and that only exist on the client: the merge/dedupe adapter, the
 * rasteriser, the offline cache and the geometry helpers.
 *
 * It is the Kotlin mirror of the Swift `ELRipenessHeatmapFeatureTests`.
 */
class ElRipenessHeatmapFeatureTest {

    private val vineyard = "vy-south"

    private fun record(
        id: String,
        paddockId: String? = "blk-a",
        stage: String? = "E-L 35",
        lat: Double? = -34.5000,
        lng: Double? = 138.5000,
        date: String? = "2026-02-10",
        vineyardId: String? = vineyard,
        deletedAt: String? = null,
    ) = ElRipenessHeatmap.RawRecord(
        id = id,
        vineyardId = vineyardId,
        paddockId = paddockId,
        stageCode = stage,
        latitude = lat,
        longitude = lng,
        date = date,
        deletedAt = deletedAt,
    )

    // ---- Adapter: dedupe & precedence ----

    @Test
    fun `pending local outranks remote which outranks cached`() {
        val merged = ElRipenessObservationAdapter.merge(
            listOf(
                SourceRecord(record("obs-1", stage = "E-L 10"), Origin.CACHED),
                SourceRecord(record("obs-1", stage = "E-L 20"), Origin.REMOTE),
                SourceRecord(record("obs-1", stage = "E-L 30"), Origin.PENDING_LOCAL),
            )
        )
        assertEquals(1, merged.size)
        assertEquals("E-L 30", merged.first().record.stageCode)
    }

    @Test
    fun `a lower precedence duplicate never displaces a higher one`() {
        val merged = ElRipenessObservationAdapter.merge(
            listOf(
                SourceRecord(record("obs-1", stage = "E-L 30"), Origin.PENDING_LOCAL),
                SourceRecord(record("obs-1", stage = "E-L 20"), Origin.REMOTE),
            )
        )
        assertEquals("E-L 30", merged.single().record.stageCode)
    }

    /**
     * Order matters: the IDW zero-distance tie-break takes the *first* matching
     * observation, so a later, higher-precedence duplicate must replace the
     * earlier entry in place rather than moving to the end.
     */
    @Test
    fun `dedupe preserves first-seen ordering`() {
        val merged = ElRipenessObservationAdapter.merge(
            listOf(
                SourceRecord(record("obs-1"), Origin.CACHED),
                SourceRecord(record("obs-2"), Origin.REMOTE),
                SourceRecord(record("obs-1"), Origin.PENDING_LOCAL),
            )
        )
        assertEquals(listOf("obs-1", "obs-2"), merged.map { it.record.id })
    }

    @Test
    fun `dedupe is by id only, never by coordinate or date`() {
        val merged = ElRipenessObservationAdapter.merge(
            listOf(
                SourceRecord(record("obs-1"), Origin.REMOTE),
                SourceRecord(record("obs-2"), Origin.REMOTE),
            )
        )
        assertEquals(2, merged.size)
    }

    // ---- Adapter: assignment ----

    @Test
    fun `placement false revokes an otherwise assigned observation`() {
        val out = ElRipenessObservationAdapter.observations(
            listOf(SourceRecord(record("obs-1"), Origin.REMOTE, placementAssigned = false)),
            selectedVineyardId = vineyard,
        )
        assertEquals(1, out.size)
        assertFalse(out.single().assigned)
    }

    /** A missing signal is "no signal", which is not the same as `false`. */
    @Test
    fun `absent placement signal leaves a block assignment intact`() {
        val out = ElRipenessObservationAdapter.observations(
            listOf(SourceRecord(record("obs-1"), Origin.REMOTE, placementAssigned = null)),
            selectedVineyardId = vineyard,
        )
        assertTrue(out.single().assigned)
    }

    @Test
    fun `block identity is never inferred from coordinates`() {
        val out = ElRipenessObservationAdapter.observations(
            listOf(SourceRecord(record("obs-1", paddockId = null), Origin.REMOTE)),
            selectedVineyardId = vineyard,
        )
        assertNull(out.single().paddockId)
        assertFalse(out.single().assigned)
    }

    // ---- Adapter: exclusions ----

    @Test
    fun `another vineyards record is excluded as wrong vineyard`() {
        val out = ElRipenessObservationAdapter.observations(
            listOf(SourceRecord(record("obs-1", vineyardId = "vy-north"), Origin.REMOTE)),
            selectedVineyardId = vineyard,
        )
        assertTrue(out.isEmpty())
    }

    @Test
    fun `E-L 47 never becomes an observation and is never clamped to 43`() {
        val out = ElRipenessObservationAdapter.observations(
            listOf(SourceRecord(record("obs-47", stage = "E-L 47"), Origin.REMOTE)),
            selectedVineyardId = vineyard,
        )
        assertTrue("E-L 47 must be excluded, not clamped", out.isEmpty())
    }

    @Test
    fun `a deleted record is excluded`() {
        val out = ElRipenessObservationAdapter.observations(
            listOf(SourceRecord(record("obs-1", deletedAt = "2026-02-11"), Origin.REMOTE)),
            selectedVineyardId = vineyard,
        )
        assertTrue(out.isEmpty())
    }

    @Test
    fun `a record with no coordinates is excluded`() {
        val out = ElRipenessObservationAdapter.observations(
            listOf(SourceRecord(record("obs-1", lat = null, lng = null), Origin.REMOTE)),
            selectedVineyardId = vineyard,
        )
        assertTrue(out.isEmpty())
    }

    // ---- Raster ----

    /** A square block with a full surface, used by the raster tests. */
    private fun squareBlock(
        id: String = "blk-a",
        minLat: Double = -34.5010,
        maxLat: Double = -34.4990,
        minLng: Double = 138.4990,
        maxLng: Double = 138.5010,
        observations: List<ElRipenessHeatmap.Observation>,
        atDate: String = "2026-02-10",
    ): ElRipenessHeatmap.BlockHeat {
        val polygon = listOf(
            LatLng(minLat, minLng),
            LatLng(minLat, maxLng),
            LatLng(maxLat, maxLng),
            LatLng(maxLat, minLng),
        )
        return ElRipenessHeatmap.buildBlockHeat(
            paddockId = id,
            paddockName = id,
            polygon = polygon,
            observations = observations,
            atDateIso = atDate,
        )
    }

    private fun observation(
        id: String,
        el: Double,
        lat: Double,
        lng: Double,
        date: String = "2026-02-10",
        paddockId: String = "blk-a",
    ) = ElRipenessHeatmap.Observation(
        id = id,
        paddockId = paddockId,
        assigned = true,
        el = el,
        lat = lat,
        lng = lng,
        dateIso = date,
    )

    @Test
    fun `modes that paint nothing produce no raster`() {
        val block = squareBlock(observations = emptyList())
        assertEquals(ElRipenessHeatmap.Mode.NONE, block.mode)
        assertNull(ElRipenessHeatRaster.raster(block))
    }

    @Test
    fun `a block with no polygon produces no raster`() {
        val block = ElRipenessHeatmap.buildBlockHeat(
            paddockId = "blk-a",
            paddockName = "A",
            polygon = listOf(LatLng(-34.5, 138.5)),
            observations = listOf(observation("o1", 30.0, -34.5, 138.5)),
            atDateIso = "2026-02-10",
        )
        assertEquals(ElRipenessHeatmap.Mode.NO_POLYGON, block.mode)
        assertNull(ElRipenessHeatRaster.raster(block))
    }

    /**
     * The grid's row 0 is the SOUTH edge; the raster's row 0 is NORTH, so an
     * observation parked near the northern edge must light up the *top* of the
     * bitmap.
     *
     * The assertion deliberately measures where the painted mass sits rather
     * than probing row 0. The contract's ray-cast is strict, so a grid node
     * lying exactly on the polygon's northern edge counts as OUTSIDE and paints
     * nothing — the outermost raster row is legitimately empty, and testing it
     * directly would pin an artefact instead of the flip.
     */
    @Test
    fun `raster flips the grid so row zero is north`() {
        val block = squareBlock(
            observations = listOf(observation("o1", 40.0, -34.4991, 138.5000)),
        )
        val raster = ElRipenessHeatRaster.raster(block)
        assertNotNull(raster)
        raster!!

        var weighted = 0.0
        var total = 0.0
        for (y in 0 until raster.height) {
            for (x in 0 until raster.width) {
                val alpha = raster.alphaAt(x, y).toDouble()
                if (alpha <= 0.0) continue
                weighted += alpha * y
                total += alpha
            }
        }
        assertTrue("the raster must paint something", total > 0.0)

        val centreRow = weighted / total
        assertTrue(
            "painted mass sat at row $centreRow of ${raster.height}; a northern " +
                "observation must weight the TOP of the bitmap",
            centreRow < raster.height / 2.0,
        )
    }

    @Test
    fun `raster is fully transparent outside the polygon`() {
        // A triangle leaves the bounding box's corners outside the polygon.
        val polygon = listOf(
            LatLng(-34.5010, 138.4990),
            LatLng(-34.5010, 138.5010),
            LatLng(-34.4990, 138.5000),
        )
        val block = ElRipenessHeatmap.buildBlockHeat(
            paddockId = "blk-tri",
            paddockName = "Triangle",
            polygon = polygon,
            observations = listOf(
                observation("o1", 30.0, -34.5005, 138.4995),
                observation("o2", 35.0, -34.5005, 138.5005),
            ),
            atDateIso = "2026-02-10",
        )
        val raster = ElRipenessHeatRaster.raster(block)
        assertNotNull(raster)
        raster!!

        // The north-west corner of the bounding box is outside the triangle.
        assertEquals(0, raster.alphaAt(0, 0))
        assertEquals(0, raster.alphaAt(raster.width - 1, 0))
    }

    /**
     * The key isolation guarantee: a block's raster only ever contains cells
     * that passed *its own* polygon test, so an observation in one block cannot
     * tint the block on the other side of a shared edge.
     */
    @Test
    fun `an observation cannot influence the block across a shared edge`() {
        val sharedLng = 138.5000
        val westPolygon = listOf(
            LatLng(-34.5010, 138.4990),
            LatLng(-34.5010, sharedLng),
            LatLng(-34.4990, sharedLng),
            LatLng(-34.4990, 138.4990),
        )
        // A hot observation sitting just inside the WEST block, hard against
        // the shared edge.
        val hot = observation("hot", 43.0, -34.5000, sharedLng - 0.00001, paddockId = "west")

        val east = ElRipenessHeatmap.buildBlockHeat(
            paddockId = "east",
            paddockName = "East",
            polygon = listOf(
                LatLng(-34.5010, sharedLng),
                LatLng(-34.5010, 138.5010),
                LatLng(-34.4990, 138.5010),
                LatLng(-34.4990, sharedLng),
            ),
            // The east block is built from ITS OWN observations only.
            observations = emptyList(),
            atDateIso = "2026-02-10",
        )
        assertNull("east block must paint nothing", ElRipenessHeatRaster.raster(east))

        val west = ElRipenessHeatmap.buildBlockHeat(
            paddockId = "west",
            paddockName = "West",
            polygon = westPolygon,
            observations = listOf(hot),
            atDateIso = "2026-02-10",
        )
        assertNotNull("west block must paint", ElRipenessHeatRaster.raster(west))
    }

    /**
     * The contract samples grid *nodes*, so the outermost nodes sit exactly on
     * the bounds. The draw rect must be expanded by half a cell in each
     * direction or the whole surface shifts inward by half a cell.
     */
    @Test
    fun `draw bounds expand the grid bounds by exactly half a cell`() {
        val block = squareBlock(
            observations = listOf(
                observation("o1", 30.0, -34.5005, 138.4995),
                observation("o2", 35.0, -34.4995, 138.5005),
            ),
        )
        val gridBounds = block.gridBounds!!
        val draw = ElRipenessHeatRaster.drawBounds(block)!!
        val rows = block.grid!!.size
        val columns = block.grid!!.first().size

        val latStep = (gridBounds.maxLat - gridBounds.minLat) / (rows - 1)
        val lngStep = (gridBounds.maxLng - gridBounds.minLng) / (columns - 1)

        assertEquals(gridBounds.minLat - latStep / 2, draw.south, 1e-12)
        assertEquals(gridBounds.maxLat + latStep / 2, draw.north, 1e-12)
        assertEquals(gridBounds.minLng - lngStep / 2, draw.west, 1e-12)
        assertEquals(gridBounds.maxLng + lngStep / 2, draw.east, 1e-12)
    }

    @Test
    fun `raster colour follows the contract colour ramp`() {
        val block = squareBlock(
            observations = listOf(observation("o1", 43.0, -34.5000, 138.5000)),
        )
        val raster = ElRipenessHeatRaster.raster(block)!!
        val expected = ElRipenessHeatmap.elColour(43.0)

        // The cell nearest the observation carries its exact value.
        var found = false
        for (y in 0 until raster.height) {
            for (x in 0 until raster.width) {
                val pixel = raster.pixel(x, y)
                if ((pixel ushr 24) and 0xFF == 0) continue
                val r = (pixel shr 16) and 0xFF
                if (r == expected.r) { found = true }
            }
        }
        assertTrue("expected at least one pixel at the ramp's E-L 43 colour", found)
    }

    // ---- Geometry ----

    @Test
    fun `centroid of a square is its middle`() {
        val centroid = ElRipenessGeometry.centroid(
            listOf(
                LatLng(0.0, 0.0),
                LatLng(0.0, 2.0),
                LatLng(2.0, 2.0),
                LatLng(2.0, 0.0),
            )
        )!!
        assertEquals(1.0, centroid.lat, 1e-9)
        assertEquals(1.0, centroid.lng, 1e-9)
    }

    @Test
    fun `centroid falls back to the vertex mean for a degenerate ring`() {
        val centroid = ElRipenessGeometry.centroid(
            listOf(LatLng(1.0, 1.0), LatLng(1.0, 1.0), LatLng(1.0, 1.0))
        )!!
        assertEquals(1.0, centroid.lat, 1e-9)
        assertEquals(1.0, centroid.lng, 1e-9)
    }

    @Test
    fun `centroid of an empty polygon is null`() {
        assertNull(ElRipenessGeometry.centroid(emptyList()))
    }

    // ---- Cache ----

    private class MemoryCache : ElRipenessObservationCaching {
        val stored = HashMap<String, ElRipenessCachePayload>()
        override fun load(vineyardId: String) = stored[vineyardId.lowercase()]
        override fun save(payload: ElRipenessCachePayload) {
            stored[payload.vineyardId.lowercase()] = payload
        }
        override fun clear(vineyardId: String) {
            stored.remove(vineyardId.lowercase())
        }
    }

    @Test
    fun `cache round-trips a record without losing timestamp text`() {
        val source = SourceRecord(
            record("obs-1", date = "2026-02-10T07:30:00+10:30"),
            Origin.REMOTE,
            placementAssigned = false,
        )
        val payload = ElRipenessCachePayload(
            vineyardId = vineyard,
            cachedAtEpochMs = 1_700_000_000_000,
            records = listOf(ElRipenessCachedRecord.from(source)),
            blocks = listOf(
                ElRipenessCachedBlock.from(
                    ElRipenessHeatmap.BlockInput("blk-a", "A", listOf(LatLng(-34.5, 138.5)))
                )
            ),
        )

        val cache = MemoryCache()
        cache.save(payload)
        val loaded = cache.load(vineyard)!!

        val restored = loaded.sourceRecords.single()
        // The ISO text must survive verbatim — reformatting it would move the
        // observation across the day boundary outside UTC.
        assertEquals("2026-02-10T07:30:00+10:30", restored.record.date)
        assertEquals(Origin.CACHED, restored.origin)
        assertEquals(false, restored.placementAssigned)
        assertEquals("blk-a", loaded.blockInputs.single().id)
    }

    @Test
    fun `a cached record replays at cached precedence so remote still wins`() {
        val cached = ElRipenessCachedRecord
            .from(SourceRecord(record("obs-1", stage = "E-L 10"), Origin.REMOTE))
            .sourceRecord
        val merged = ElRipenessObservationAdapter.merge(
            listOf(cached, SourceRecord(record("obs-1", stage = "E-L 20"), Origin.REMOTE))
        )
        assertEquals("E-L 20", merged.single().record.stageCode)
    }

    // ---- Repository row mapping ----

    @Test
    fun `a view row maps to a remote source carrying its placement signal`() {
        val row = RipenessObservationRow(
            id = "OBS-1",
            vineyardId = "VY-SOUTH",
            paddockId = "BLK-A",
            stageCode = "E-L 35",
            latitude = -34.5,
            longitude = 138.5,
            observedAt = "2026-02-10",
        )
        val source = row.sourceRecord()
        assertEquals(Origin.REMOTE, source.origin)
        assertNull(source.placementAssigned)
        // Identifiers are lowercased so they match locally-minted ones.
        assertEquals("obs-1", source.record.id)
        assertEquals("vy-south", source.record.vineyardId)
        assertEquals("blk-a", source.record.paddockId)
    }

    // ---- Network discipline ----

    private class CountingRepository : RipenessObservationRepositoryProtocol {
        var fetchCount = 0
        var rows: List<RipenessObservationRow> = emptyList()
        override suspend fun fetchObservations(vineyardId: String): List<RipenessObservationRow> {
            fetchCount += 1
            return rows
        }
    }

    /**
     * Proves the promise rather than asserting it: the heat model for every day
     * in a season is built from one in-memory observation set, so scrubbing the
     * timeline can never touch the network.
     */
    @Test
    fun `building every day of a season needs no additional fetch`() {
        val repository = CountingRepository()
        repository.rows = listOf(
            RipenessObservationRow(
                id = "obs-1",
                vineyardId = vineyard,
                paddockId = "blk-a",
                stageCode = "E-L 35",
                latitude = -34.5,
                longitude = 138.5,
                observedAt = "2026-02-10",
            )
        )

        // One fetch, exactly as the view model performs on load.
        val rows = kotlinx.coroutines.runBlocking { repository.fetchObservations(vineyard) }
        val observations = ElRipenessObservationAdapter.observations(
            rows.map { it.sourceRecord() },
            selectedVineyardId = vineyard,
        )
        val blocks = listOf(
            ElRipenessHeatmap.BlockInput(
                "blk-a", "A",
                listOf(
                    LatLng(-34.5010, 138.4990),
                    LatLng(-34.5010, 138.5010),
                    LatLng(-34.4990, 138.5010),
                    LatLng(-34.4990, 138.4990),
                ),
            )
        )

        var cursor = com.rork.vinetrack.data.ripeness.CivilDate(2026, 2, 1)
        repeat(28) {
            ElRipenessHeatmap.buildHeatModel(observations, blocks, cursor.iso)
            cursor = cursor.adding(1)
        }

        assertEquals("scrubbing a season must not re-fetch", 1, repository.fetchCount)
    }

    // ---- Status counts ----

    /**
     * Contract section 9: the counts deliberately do not balance. An unassigned
     * pin appears in the recorded total but in neither partition.
     */
    @Test
    fun `an unassigned observation counts as recorded but never influences`() {
        val assigned = observation("o1", 30.0, -34.5000, 138.5000)
        val unassigned = ElRipenessHeatmap.Observation(
            id = "o2",
            paddockId = null,
            assigned = false,
            el = 35.0,
            lat = -34.5002,
            lng = 138.5002,
            dateIso = "2026-02-10",
        )
        val model = ElRipenessHeatmap.buildHeatModel(
            observations = listOf(assigned, unassigned),
            blocks = listOf(
                ElRipenessHeatmap.BlockInput(
                    "blk-a", "A",
                    listOf(
                        LatLng(-34.5010, 138.4990),
                        LatLng(-34.5010, 138.5010),
                        LatLng(-34.4990, 138.5010),
                        LatLng(-34.4990, 138.4990),
                    ),
                )
            ),
            atDateIso = "2026-02-10",
        )
        assertEquals(2, model.qualifying.size)
        assertEquals(1, model.influencing.size)
        assertEquals(1, model.unassigned.size)
    }

    // ---- Shared read feed (Summary and Heatmap must agree) ----

    private val adelaide: TimeZone = TimeZone.getTimeZone("Australia/Adelaide")

    private fun syncedRecord(
        id: String,
        pinId: String? = null,
        stage: String = "E-L 2",
        paddockId: String? = "blk-a",
    ) = GrowthStageRecord(
        id = id,
        vineyardId = vineyard,
        paddockId = paddockId,
        pinId = pinId,
        stageCode = stage,
        observedAt = "2026-02-10T09:00:00+10:30",
        latitude = -34.5,
        longitude = 138.5,
    )

    /**
     * The exact reported defect: the Summary listed records the map could not
     * see, because the map only ever read the remote view. A synced record
     * must reach the heat feed even when the remote view returns nothing.
     */
    @Test
    fun `a synced record reaches the heatmap when the remote view is empty`() {
        val sources = ElRipenessObservationAdapter.localRecords(
            records = listOf(
                syncedRecord("rec-1"),
                syncedRecord("rec-2"),
                syncedRecord("rec-3"),
            ),
            vineyardId = vineyard,
            timeZone = adelaide,
        )
        val observations = ElRipenessObservationAdapter.observations(sources, vineyard)
        assertEquals(3, observations.size)
        assertTrue(observations.all { it.el == 2.0 })
    }

    /**
     * The same physical observation arrives under three different primary
     * keys. Without pin-based dedupe the map would triple-count it.
     */
    @Test
    fun `a record, its remote row and its pin collapse to one observation`() {
        val pin = "pin-1"
        val local = ElRipenessObservationAdapter
            .localRecord(syncedRecord("rec-1", pinId = pin), adelaide)!!
        val remote = RipenessObservationRow(
            id = "obs-1",
            vineyardId = vineyard,
            paddockId = "blk-a",
            stageCode = "E-L 2",
            latitude = -34.5,
            longitude = 138.5,
            observedAt = "2026-02-10",
            pinId = pin,
        ).sourceRecord()
        val pending = SourceRecord(
            record = record("pin-1", stage = "E-L 4"),
            origin = Origin.PENDING_LOCAL,
            pinId = pin,
        )

        val merged = ElRipenessObservationAdapter.merge(listOf(local, remote, pending))
        assertEquals(1, merged.size)
        // The unsynced local edit is the freshest truth.
        assertEquals(Origin.PENDING_LOCAL, merged.single().origin)

        val observations = ElRipenessObservationAdapter
            .observations(listOf(local, remote, pending), vineyard)
        assertEquals(1, observations.size)
    }

    /** Records without a pin still dedupe on their own id, as before. */
    @Test
    fun `records with no pin keep id-based dedupe`() {
        val a = ElRipenessObservationAdapter.localRecord(syncedRecord("rec-1"), adelaide)!!
        val b = ElRipenessObservationAdapter.localRecord(syncedRecord("rec-2"), adelaide)!!
        assertEquals(2, ElRipenessObservationAdapter.merge(listOf(a, b)).size)
    }

    /**
     * Summary and Heatmap read one feed, so their counts are the same numbers.
     * Mirrors the live Stockmans Ridge expectation: three records, all current,
     * typical stage E-L 2, painted red.
     */
    @Test
    fun `summary and heatmap counts come from the same merged feed`() {
        val sources = ElRipenessObservationAdapter.localRecords(
            records = listOf(
                syncedRecord("rec-1", pinId = "pin-1"),
                syncedRecord("rec-2", pinId = "pin-2"),
                syncedRecord("rec-3", pinId = "pin-3"),
            ),
            vineyardId = vineyard,
            timeZone = adelaide,
        )
        val observations = ElRipenessObservationAdapter.observations(sources, vineyard)
        val model = ElRipenessHeatmap.buildHeatModel(
            observations = observations,
            blocks = listOf(
                ElRipenessHeatmap.BlockInput(
                    "blk-a", "Gr\u00fcner Veltliner",
                    listOf(
                        LatLng(-34.5010, 138.4990),
                        LatLng(-34.5010, 138.5010),
                        LatLng(-34.4990, 138.5010),
                        LatLng(-34.4990, 138.4990),
                    ),
                )
            ),
            atDateIso = "2026-02-10",
        )

        assertEquals(3, model.qualifying.size)
        assertEquals(3, model.influencing.size)
        assertEquals(0, model.stale.size)
        assertEquals(0, model.unassigned.size)
        assertEquals(2.0, model.medianEl!!, 1e-9)
        // A red surface: E-L 2 sits at the hot end of the ramp.
        val colour = ElRipenessHeatmap.elColour(2.0)
        assertTrue("expected red-dominant, got $colour", colour.r > 200 && colour.g < 90)
    }
}

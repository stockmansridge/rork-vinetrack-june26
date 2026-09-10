package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.CoordinatePoint
import com.rork.vinetrack.data.model.Paddock
import com.rork.vinetrack.data.model.PaddockRow
import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.ui.resolveTripPinAttribution
import kotlin.math.abs
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Core pin-location contract: an automatic Left/Right drop must identify the
 * actual aisle and attach to the physically adjacent vine row on the operator's
 * side for their recorded facing (docs/core-pin-location-contract.md).
 *
 * Fixture geometry: straight rows around latitude -33, spaced 0.00004° of
 * longitude (~3.7 m at this latitude). Row-number ordering is deliberately
 * varied between fixtures so nothing can pass by assuming "Left = lower row".
 */
class PinAisleAttachmentTest {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val rowSpacing = 0.00004
    private val southLat = -33.0010
    private val northLat = -32.9990

    /** Rows numbered west -> east (32 lies west of 33). */
    private fun eastwardBlock(
        id: String = "block-1",
        numbers: List<Int> = listOf(31, 32, 33, 34),
        reversedEndpoints: Boolean = false,
    ): Paddock = Paddock(
        id = id,
        vineyardId = "vineyard-1",
        name = "Block 1",
        rowWidth = 3.7,
        polygonPoints = listOf(
            CoordinatePoint(southLat, 148.99980),
            CoordinatePoint(southLat, 149.00060),
            CoordinatePoint(northLat, 149.00060),
            CoordinatePoint(northLat, 148.99980),
        ),
        rows = numbers.map { number ->
            val lon = 149.0 + (number - 32) * rowSpacing
            if (reversedEndpoints) {
                PaddockRow(
                    number = number,
                    startPoint = CoordinatePoint(northLat, lon),
                    endPoint = CoordinatePoint(southLat, lon),
                )
            } else {
                PaddockRow(
                    number = number,
                    startPoint = CoordinatePoint(southLat, lon),
                    endPoint = CoordinatePoint(northLat, lon),
                )
            }
        },
    )

    /** Same physical rows, numbered east -> west (33 lies WEST of 32). */
    private fun westwardBlock(id: String = "block-rev"): Paddock = Paddock(
        id = id,
        vineyardId = "vineyard-1",
        name = "Reversed numbering",
        rowWidth = 3.7,
        polygonPoints = listOf(
            CoordinatePoint(southLat, 148.99980),
            CoordinatePoint(southLat, 149.00060),
            CoordinatePoint(northLat, 149.00060),
            CoordinatePoint(northLat, 148.99980),
        ),
        rows = listOf(31, 32, 33, 34).map { number ->
            PaddockRow(
                number = number,
                startPoint = CoordinatePoint(southLat, 149.0 - (number - 32) * rowSpacing),
                endPoint = CoordinatePoint(northLat, 149.0 - (number - 32) * rowSpacing),
            )
        },
    )

    /** Rows running east-west, numbered south -> north (rotated 90°). */
    private fun rotatedBlock(id: String = "block-rot"): Paddock = Paddock(
        id = id,
        vineyardId = "vineyard-1",
        name = "Rotated",
        rowWidth = 3.7,
        polygonPoints = listOf(
            CoordinatePoint(-33.00120, 148.99900),
            CoordinatePoint(-33.00120, 149.00100),
            CoordinatePoint(-32.99880, 149.00100),
            CoordinatePoint(-32.99880, 148.99900),
        ),
        rows = listOf(31, 32, 33, 34).map { number ->
            val lat = -33.0 + (number - 32) * 0.0000336 // ~3.7 m of latitude
            PaddockRow(
                number = number,
                startPoint = CoordinatePoint(lat, 148.99920),
                endPoint = CoordinatePoint(lat, 149.00080),
            )
        },
    )

    /** Aisle 32.5: midway between rows 32 and 33. */
    private fun aisle32_5Longitude(): Double = 149.0 + rowSpacing / 2.0

    private fun automatic(
        block: Paddock,
        latitude: Double,
        longitude: Double,
        side: String?,
        heading: Double?,
    ) = PinPlacement.resolveAutomatic(
        paddocks = listOf(block),
        selectedPaddockId = block.id,
        latitude = latitude,
        longitude = longitude,
        side = side,
        headingDegrees = heading,
    )

    // MARK: - Fixture matrix: opposite sides select opposite adjacent rows

    @Test
    fun `facing north in aisle 32 point 5 attaches left to row 32 and right to row 33`() {
        val block = eastwardBlock()
        val lat = -33.0
        val lon = aisle32_5Longitude()

        val left = automatic(block, lat, lon, "left", 0.0)
        val right = automatic(block, lat, lon, "right", 0.0)

        assertEquals(PinSnapState.SNAPPED, left.snapState)
        assertEquals(32.0, left.pinRowNumber!!, 1e-9)
        assertEquals(32.5, left.drivingRowNumber!!, 1e-9)
        assertEquals("left", left.pinSide)
        assertEquals(0.0, left.headingDegrees!!, 1e-9)

        assertEquals(PinSnapState.SNAPPED, right.snapState)
        assertEquals(33.0, right.pinRowNumber!!, 1e-9)
        assertEquals(32.5, right.drivingRowNumber!!, 1e-9)
        assertEquals("right", right.pinSide)

        // The audited defect: two opposite presses at one fix resolving to the
        // same row. They must never agree.
        assertNotEquals(left.pinRowNumber, right.pinRowNumber)
    }

    @Test
    fun `reversing the heading reverses the sides and keeps the same aisle`() {
        val block = eastwardBlock()
        val lat = -33.0
        val lon = aisle32_5Longitude()

        val southLeft = automatic(block, lat, lon, "left", 180.0)
        val southRight = automatic(block, lat, lon, "right", 180.0)

        assertEquals(33.0, southLeft.pinRowNumber!!, 1e-9)
        assertEquals(32.0, southRight.pinRowNumber!!, 1e-9)
        assertEquals(32.5, southLeft.drivingRowNumber!!, 1e-9)
        assertEquals(32.5, southRight.drivingRowNumber!!, 1e-9)
        assertEquals("left", southLeft.pinSide)
        assertEquals("right", southRight.pinSide)
    }

    @Test
    fun `side follows physical geometry, not row-number ordering`() {
        // Physically identical aisle, but numbered the other way round: row 33
        // now lies west, so facing North the LEFT press must attach to row 33.
        val block = westwardBlock()
        val lon = 149.0 - rowSpacing / 2.0
        val left = automatic(block, -33.0, lon, "left", 0.0)
        val right = automatic(block, -33.0, lon, "right", 0.0)

        assertEquals(33.0, left.pinRowNumber!!, 1e-9)
        assertEquals(32.0, right.pinRowNumber!!, 1e-9)
        assertEquals(32.5, left.drivingRowNumber!!, 1e-9)
    }

    @Test
    fun `reversed row endpoint order produces the same physical answer`() {
        val lat = -33.0
        val lon = aisle32_5Longitude()
        val normal = automatic(eastwardBlock(), lat, lon, "left", 0.0)
        val reversed = automatic(
            eastwardBlock(reversedEndpoints = true),
            lat,
            lon,
            "left",
            0.0,
        )
        assertEquals(normal.pinRowNumber!!, reversed.pinRowNumber!!, 1e-9)
        assertEquals(normal.drivingRowNumber!!, reversed.drivingRowNumber!!, 1e-9)
        // Snapped onto the same vine row centreline either way.
        assertEquals(normal.snappedLongitude!!, reversed.snappedLongitude!!, 1e-9)
    }

    @Test
    fun `rotated rows resolve the side from the actual bearing`() {
        // Rows run east-west, numbered south -> north. Facing East (90°), left
        // is north, so the left press attaches to the higher-numbered row.
        val block = rotatedBlock()
        val lat = -33.0 + 0.0000168 // midway between rows 32 and 33
        val left = automatic(block, lat, 149.0, "left", 90.0)
        val right = automatic(block, lat, 149.0, "right", 90.0)

        assertEquals(33.0, left.pinRowNumber!!, 1e-9)
        assertEquals(32.0, right.pinRowNumber!!, 1e-9)
        assertEquals(32.5, left.drivingRowNumber!!, 1e-9)
    }

    @Test
    fun `non-contiguous row numbers report the real adjacent pair without inventing a row`() {
        val block = eastwardBlock(numbers = listOf(32, 34))
        // Aisle between the two physically adjacent mapped rows 32 and 34.
        val lon = 149.0 + rowSpacing // midway between 32 (149.0) and 34 (149.00008)
        val left = automatic(block, -33.0, lon, "left", 0.0)
        assertEquals(PinSnapState.SNAPPED, left.snapState)
        assertEquals(32.0, left.pinRowNumber!!, 1e-9)
        assertEquals(33.0, left.drivingRowNumber!!, 1e-9)
        // Row 33 does not exist and is never attached to.
        assertNotEquals(33.0, left.pinRowNumber!!)
    }

    @Test
    fun `block boundary row keeps honest point-only semantics outside the mapped rows`() {
        val block = eastwardBlock()
        // East of row 34 — a headland position with no neighbour beyond it.
        val lon = 149.0 + 3 * rowSpacing
        val result = automatic(block, -33.0, lon, "left", 0.0)
        assertEquals(PinSnapState.UNCONFIRMED_ROW, result.snapState)
        assertFalse(result.snappedToRow)
        assertNull(result.pinRowNumber)
        assertNull(result.drivingRowNumber)
        assertNull(result.snappedLatitude)
        // Raw observation and the operator's own side are still preserved.
        assertEquals(-33.0, result.latitude!!, 0.0)
        assertEquals(lon, result.longitude!!, 0.0)
        assertEquals("left", result.pinSide)
    }

    // MARK: - No false certainty

    @Test
    fun `missing heading never becomes north and never claims a row`() {
        val block = eastwardBlock()
        val result = automatic(block, -33.0, aisle32_5Longitude(), "left", null)
        assertEquals(PinSnapState.UNCONFIRMED_ROW, result.snapState)
        assertNull(result.pinRowNumber)
        assertNull(result.drivingRowNumber)
        assertNull(result.headingDegrees)
        assertEquals("left", result.pinSide)
    }

    @Test
    fun `invalid heading values are rejected rather than normalised into a direction`() {
        val block = eastwardBlock()
        for (heading in listOf(-1.0, 361.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            val result = automatic(block, -33.0, aisle32_5Longitude(), "left", heading)
            assertEquals(PinSnapState.UNCONFIRMED_ROW, result.snapState)
            assertNull(result.headingDegrees)
            assertNull(result.pinRowNumber)
        }
        // A genuine 0° (North) remains valid.
        val north = automatic(block, -33.0, aisle32_5Longitude(), "left", 0.0)
        assertEquals(PinSnapState.SNAPPED, north.snapState)
        assertEquals(0.0, north.headingDegrees!!, 1e-9)
    }

    @Test
    fun `a fix sitting on the vine row itself does not guess an aisle`() {
        val block = eastwardBlock()
        val result = automatic(block, -33.0, 149.0, "left", 0.0)
        assertEquals(PinSnapState.UNCONFIRMED_ROW, result.snapState)
        assertNull(result.drivingRowNumber)
        assertNull(result.pinRowNumber)
    }

    @Test
    fun `a block without mapped row geometry stays unsnapped`() {
        val bare = Paddock(
            id = "bare",
            vineyardId = "vineyard-1",
            name = "Bare",
            polygonPoints = eastwardBlock().polygonPoints,
        )
        val result = automatic(bare, -33.0, 149.0, "left", 0.0)
        assertEquals(PinSnapState.NO_ROW_GEOMETRY, result.snapState)
        assertNull(result.pinRowNumber)
        assertNull(result.drivingRowNumber)
    }

    @Test
    fun `pin snaps onto the selected vine row, not the aisle centreline`() {
        val block = eastwardBlock()
        val lon = aisle32_5Longitude()
        val left = automatic(block, -33.0, lon, "left", 0.0)
        // Row 32's centreline, not the 32.5 midline the fix sits on.
        assertEquals(149.0, left.snappedLongitude!!, 1e-9)
        assertNotEquals(lon, left.snappedLongitude!!)
        // Raw observation is retained separately and unchanged.
        assertEquals(lon, left.longitude!!, 0.0)
        // Along-row distance is measured on the attached row.
        assertTrue(abs(left.alongRowDistanceM!! - 111.0) < 6.0)
    }

    // MARK: - Side-free and manual contracts unchanged

    @Test
    fun `a side-free growth observation keeps the established nearest-row contract`() {
        val block = eastwardBlock()
        val result = automatic(block, -33.0, aisle32_5Longitude(), null, 0.0)
        assertEquals(PinSnapState.SNAPPED, result.snapState)
        // Nearest row, no invented side and no manufactured aisle.
        assertEquals(32.0, result.pinRowNumber!!, 1e-9)
        assertNull(result.pinSide)
        assertNull(result.drivingRowNumber)
        assertEquals(0.0, result.headingDegrees!!, 1e-9)
    }

    @Test
    fun `explicit manual placement is untouched by the automatic resolver`() {
        val block = eastwardBlock()
        val manual = PinPlacement.resolve(
            paddocks = listOf(block),
            selectedPaddockId = block.id,
            latitude = -33.0,
            longitude = aisle32_5Longitude(),
            side = "left",
        )
        assertEquals(PinSnapState.SNAPPED, manual.snapState)
        assertEquals(32.0, manual.pinRowNumber!!, 1e-9)
        // A map tap never implies the operator drove an aisle.
        assertNull(manual.drivingRowNumber)
        assertNull(manual.headingDegrees)
    }

    // MARK: - Trip scope

    private fun trip(paddockIds: List<String>) = Trip(
        id = "trip-1",
        vineyardId = "vineyard-1",
        paddockId = paddockIds.firstOrNull(),
        paddockIds = paddockIds,
        isActive = true,
    )

    @Test
    fun `inside a trip the automatic answer matches the standalone answer`() {
        val block = eastwardBlock()
        val lon = aisle32_5Longitude()
        val inTrip = resolveTripPinAttribution(
            activeTrip = trip(listOf(block.id)),
            paddocks = listOf(block),
            latitude = -33.0,
            longitude = lon,
            side = "right",
            callerPaddockId = null,
            callerRowNumber = null,
            callerPlacement = null,
            headingDegrees = 0.0,
            automatic = true,
        )
        val standalone = automatic(block, -33.0, lon, "right", 0.0)
        assertEquals(block.id, inTrip.paddockId)
        assertEquals(standalone.pinRowNumber!!, inTrip.placement!!.pinRowNumber!!, 1e-9)
        assertEquals(standalone.drivingRowNumber!!, inTrip.placement!!.drivingRowNumber!!, 1e-9)
    }

    @Test
    fun `a wrong-block trip lock cannot attach a pin to an unselected block`() {
        val selected = eastwardBlock(id = "selected")
        val other = Paddock(
            id = "other",
            vineyardId = "vineyard-1",
            name = "Other",
            rowWidth = 3.7,
            polygonPoints = listOf(
                CoordinatePoint(southLat, 149.01000),
                CoordinatePoint(southLat, 149.01080),
                CoordinatePoint(northLat, 149.01080),
                CoordinatePoint(northLat, 149.01000),
            ),
            // Same row numbers repeated in a different block.
            rows = listOf(31, 32, 33, 34).map { number ->
                PaddockRow(
                    number = number,
                    startPoint = CoordinatePoint(southLat, 149.01 + (number - 32) * rowSpacing),
                    endPoint = CoordinatePoint(northLat, 149.01 + (number - 32) * rowSpacing),
                )
            },
        )
        val attribution = resolveTripPinAttribution(
            activeTrip = trip(listOf(selected.id)),
            paddocks = listOf(selected, other),
            latitude = -33.0,
            longitude = 149.01 + rowSpacing / 2.0, // physically inside `other`
            side = "left",
            callerPaddockId = other.id,
            callerRowNumber = 32,
            callerPlacement = null,
            headingDegrees = 0.0,
            automatic = true,
        )
        assertNull(attribution.paddockId)
        assertNull(attribution.rowNumber)
        assertNull(attribution.placement)
    }

    // MARK: - Persistence through payload, queue and replay

    private fun frozenInput(placement: PinPlacementResult) = PinRepository.PinInput(
        id = "3f8a3a52-6a1e-4a7e-9a1c-2d3e4f5a6b7f",
        vineyardId = "vineyard-1",
        paddockId = placement.paddockId,
        tripId = "trip-1",
        title = "Irrigation",
        mode = "Repairs",
        side = placement.pinSide,
        heading = placement.headingDegrees,
        rowNumber = placement.pinRowNumber?.toInt(),
        drivingRowNumber = placement.drivingRowNumber,
        pinRowNumber = placement.pinRowNumber,
        pinSide = placement.pinSide,
        alongRowDistanceM = placement.alongRowDistanceM,
        snappedLatitude = placement.snappedLatitude,
        snappedLongitude = placement.snappedLongitude,
        snappedToRow = placement.snappedToRow,
        latitude = placement.latitude,
        longitude = placement.longitude,
        createdBy = "user-1",
        createdAt = "2026-09-10T02:03:04Z",
    )

    @Test
    fun `the frozen aisle survives the offline queue, restart and production replay`() = runBlocking {
        val placement = automatic(eastwardBlock(), -33.0, aisle32_5Longitude(), "right", 346.0)
        assertEquals(33.0, placement.pinRowNumber!!, 1e-9)
        val input = frozenInput(placement)

        val storage = InMemoryPendingWriteStore()
        PinCreateSync(PendingWriteRepository(storage)).enqueue(input)

        // Restart: a brand-new repository over the same durable storage.
        val restarted = PendingWriteRepository(storage)
        val durable = restarted.list().single()
        val decoded = json.decodeFromString(PinRepository.PinInput.serializer(), durable.payloadJson)
        assertEquals(input, decoded)
        assertEquals(32.5, decoded.drivingRowNumber!!, 1e-9)

        var outgoing: PinRepository.PinInput? = null
        PinCreateSync(restarted) { sent ->
            outgoing = sent
            Pin(
                id = sent.id!!,
                vineyardId = sent.vineyardId,
                paddockId = sent.paddockId,
                tripId = sent.tripId,
                heading = sent.heading,
                rowNumber = sent.rowNumber,
                drivingRowNumber = sent.drivingRowNumber,
                pinRowNumber = sent.pinRowNumber,
                pinSide = sent.pinSide,
                alongRowDistanceM = sent.alongRowDistanceM,
                snappedLatitude = sent.snappedLatitude,
                snappedLongitude = sent.snappedLongitude,
                snappedToRow = sent.snappedToRow,
                latitude = sent.latitude,
                longitude = sent.longitude,
                createdAt = sent.createdAt,
            )
        }.replayAll { }

        assertEquals(input, outgoing)
        assertTrue(restarted.list().isEmpty())
    }

    @Test
    fun `the driving path is written under its server column name`() {
        val placement = automatic(eastwardBlock(), -33.0, aisle32_5Longitude(), "right", 346.0)
        val encoded = json.encodeToString(PinRepository.PinInput.serializer(), frozenInput(placement))
        val obj = json.parseToJsonElement(encoded).jsonObject
        assertEquals(32.5, obj.getValue("driving_row_number").jsonPrimitive.double, 1e-12)
        assertEquals(33.0, obj.getValue("pin_row_number").jsonPrimitive.double, 1e-12)
        assertEquals(346.0, obj.getValue("heading").jsonPrimitive.double, 1e-12)
    }

    @Test
    fun `queued payloads written before the driving path column still decode`() {
        val legacy = """
            {"id":"4f8a3a52-6a1e-4a7e-9a1c-2d3e4f5a6b70","vineyard_id":"vineyard-1",
             "title":"Broken Post","mode":"Repairs","side":"right",
             "row_number":7,"pin_row_number":7.0,"pin_side":"right",
             "along_row_distance_m":12.5,"snapped_to_row":true,
             "is_completed":false,"latitude":-33.0,"longitude":149.0}
        """.trimIndent()
        val decoded = json.decodeFromString(PinRepository.PinInput.serializer(), legacy)
        assertNull(decoded.drivingRowNumber)
        // The valid saved attachment it does carry is untouched.
        assertEquals(7.0, decoded.pinRowNumber!!, 1e-12)
        assertEquals("right", decoded.pinSide)
        assertTrue(decoded.snappedToRow)
    }

    // MARK: - Marker / distance / Directions agreement

    @Test
    fun `marker distance and directions all read the attached row coordinate`() {
        val placement = automatic(eastwardBlock(), -33.0, aisle32_5Longitude(), "right", 0.0)
        val pin = Pin(
            id = "pin-1",
            vineyardId = "vineyard-1",
            latitude = placement.latitude,
            longitude = placement.longitude,
            snappedLatitude = placement.snappedLatitude,
            snappedLongitude = placement.snappedLongitude,
            snappedToRow = true,
            pinRowNumber = placement.pinRowNumber,
            drivingRowNumber = placement.drivingRowNumber,
            pinSide = placement.pinSide,
        )
        assertEquals(placement.snappedLatitude!!, pin.attachedLatitude!!, 1e-12)
        assertEquals(placement.snappedLongitude!!, pin.attachedLongitude!!, 1e-12)
        // The raw observation is still preserved on the record itself.
        assertEquals(placement.longitude!!, pin.longitude!!, 1e-12)

        // A point-only pin keeps using its raw drop point.
        val pointOnly = pin.copy(snappedToRow = false)
        assertEquals(pin.latitude!!, pointOnly.attachedLatitude!!, 1e-12)
        assertEquals(pin.longitude!!, pointOnly.attachedLongitude!!, 1e-12)
    }
}

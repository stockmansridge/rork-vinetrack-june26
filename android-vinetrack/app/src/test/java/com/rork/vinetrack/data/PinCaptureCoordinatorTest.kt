package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Pin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PinCaptureCoordinatorTest {
    private fun fix(lat: Double, lng: Double) = QualifiedLocationFix(
        latitude = lat,
        longitude = lng,
        accuracyMetres = 4.0,
        fixTimeEpochMs = 1_000L,
        fixElapsedRealtimeNanos = 1_000_000L,
        bearingDegrees = 90.0,
    )

    @Test
    fun `rejected tap cannot consume a later fix in the same trip`() {
        var source: PinLocationResult = PinLocationResult.Stale
        val coordinator = PinTapCaptureCoordinator { source }

        assertTrue(coordinator.captureNow() is PinLocationResult.Stale)
        source = PinLocationResult.Success(fix(-33.2, 149.2))

        // Delivery only warms the source. No callback or pending tap exists.
        assertTrue(source is PinLocationResult.Success)
        assertEquals(-33.2, (coordinator.captureNow() as PinLocationResult.Success).fix.latitude, 0.0)
    }

    @Test
    fun `qualified tap remains at A after source moves to B`() {
        var source: PinLocationResult = PinLocationResult.Success(fix(-33.1, 149.1))
        val coordinator = PinTapCaptureCoordinator { source }
        val accepted = (coordinator.captureNow() as PinLocationResult.Success).fix
        source = PinLocationResult.Success(fix(-33.2, 149.2))

        assertEquals(-33.1, accepted.latitude, 0.0)
        assertEquals(149.1, accepted.longitude, 0.0)
    }

    @Test
    fun `persisted repository recreation and replay send original payload`() = runBlocking {
        val storage = InMemoryPendingWriteStore()
        val original = PinRepository.PinInput(
            id = "pin-at-a",
            vineyardId = "vineyard",
            tripId = "trip",
            paddockId = "block-a",
            rowNumber = 12,
            pinRowNumber = 12.0,
            pinSide = "left",
            snappedLatitude = -33.10001,
            snappedLongitude = 149.10001,
            snappedToRow = true,
            latitude = -33.1,
            longitude = 149.1,
            createdAt = "2026-09-10T01:02:03Z",
        )
        PinCreateSync(PendingWriteRepository(storage)).enqueue(original)

        var outgoing: PinRepository.PinInput? = null
        val restarted = PendingWriteRepository(storage)
        PinCreateSync(restarted) { input ->
            outgoing = input
            Pin(
                id = input.id!!,
                vineyardId = input.vineyardId,
                tripId = input.tripId,
                paddockId = input.paddockId,
                rowNumber = input.rowNumber,
                pinRowNumber = input.pinRowNumber,
                pinSide = input.pinSide,
                snappedLatitude = input.snappedLatitude,
                snappedLongitude = input.snappedLongitude,
                snappedToRow = input.snappedToRow,
                latitude = input.latitude,
                longitude = input.longitude,
                createdAt = input.createdAt,
            )
        }.replayAll { }

        assertEquals(original, outgoing)
        assertTrue(restarted.list().isEmpty())
    }

    @Test
    fun `foreground stop resume and permission changes restart only subscription`() {
        var starts = 0
        var stops = 0
        val controller = ForegroundLocationSubscriptionController({ starts++ }, { stops++ })
        controller.onForegroundChanged(true)
        controller.onForegroundChanged(false)
        controller.onForegroundChanged(true)
        controller.onEnvironmentChanged()
        controller.dispose()
        assertEquals(3, starts)
        assertEquals(5, stops)
    }
}

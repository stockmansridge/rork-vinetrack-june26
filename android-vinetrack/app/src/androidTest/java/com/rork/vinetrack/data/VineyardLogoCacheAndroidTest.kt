package com.rork.vinetrack.data

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

/** Isolated durable-cache checks only; no live vineyard, auth or storage calls. */
class VineyardLogoCacheAndroidTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private fun jpeg(): ByteArray = ByteArrayOutputStream().use { out ->
        val bitmap = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.GREEN)
        bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
        bitmap.recycle()
        out.toByteArray()
    }

    @Test fun recreatedCacheRestoresDecodableBytesAndRemoteIdentity() {
        val id = UUID.randomUUID().toString()
        val cache = VineyardLogoCache(context)
        try {
            val image = jpeg()
            assertTrue(cache.save(id, image, "$id/logo.jpg", "2026-10-30T12:00:00Z"))
            val restored = requireNotNull(VineyardLogoCache(context).load(id))
            assertArrayEquals(image, restored.jpeg)
            assertNotNull(BitmapFactory.decodeByteArray(restored.jpeg, 0, restored.jpeg.size))
            assertTrue(restored.isCurrent("$id/logo.jpg", "2026-10-30T12:00:00Z"))
        } finally { cache.remove(id) }
    }

    @Test fun stalePathTimestampAndNullTimestampRequireRefreshWithoutDiscardingBytes() {
        val id = UUID.randomUUID().toString()
        val cache = VineyardLogoCache(context)
        try {
            val image = jpeg()
            assertTrue(cache.save(id, image, "$id/logo.jpg", "old"))
            val entry = requireNotNull(cache.load(id))
            assertFalse(entry.isCurrent("$id/logo.jpg", "replacement"))
            assertFalse(entry.isCurrent("$id/replacement.jpg", "old"))
            assertFalse(entry.isCurrent("$id/logo.jpg", null))
            assertArrayEquals(image, requireNotNull(cache.load(id)).jpeg)
        } finally { cache.remove(id) }
    }

    @Test fun invalidEmptyReplacementRetainsLastKnownBytes() {
        val id = UUID.randomUUID().toString()
        val cache = VineyardLogoCache(context)
        try {
            val image = jpeg()
            assertTrue(cache.save(id, image, "$id/logo.jpg", "old"))
            assertFalse(cache.save(id, byteArrayOf(), "$id/logo.jpg", "new"))
            assertArrayEquals(image, requireNotNull(cache.load(id)).jpeg)
            assertTrue(requireNotNull(cache.load(id)).isCurrent("$id/logo.jpg", "old"))
        } finally { cache.remove(id) }
    }

    @Test fun removalAndReadsStayWithinOriginalVineyard() {
        val a = UUID.randomUUID().toString(); val b = UUID.randomUUID().toString()
        val cache = VineyardLogoCache(context)
        try {
            assertTrue(cache.save(a, jpeg(), "$a/logo.jpg", null))
            assertNull(cache.load(b))
            assertTrue(cache.save(b, jpeg(), "$b/logo.jpg", null))
            cache.remove(a)
            assertNull(cache.load(a))
            assertTrue(requireNotNull(cache.load(b)).isCurrent("$b/logo.jpg", null))
        } finally { cache.remove(a); cache.remove(b) }
    }
}

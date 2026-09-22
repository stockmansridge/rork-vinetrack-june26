package com.rork.vinetrack.data.spray

import com.rork.vinetrack.data.CanopyWaterRates
import com.rork.vinetrack.data.SprayCalculator
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CanopyReferenceImageRepositoryTest {
    private val validA = "IMG-a".encodeToByteArray()
    private val validB = "IMG-b".encodeToByteArray()

    private class FakeRemote(
        var configuration: CanopyReferenceConfiguration,
        val payloads: MutableMap<String, ByteArray>,
    ) {
        var configFailure = false
        val imageRequests = mutableListOf<String>()
        var configRequests = 0
        val failingPaths = mutableSetOf<String>()

        val source = CanopyReferenceConfigSource {
            configRequests += 1
            if (configFailure) error("offline")
            configuration
        }
        val downloader = CanopyReferenceImageDownloader { _, path ->
            imageRequests += path
            if (path in failingPaths) error("download failed")
            payloads[path] ?: ByteArray(0)
        }
    }

    private fun root(): File = Files.createTempDirectory("canopy-reference-test").toFile()

    private fun repository(root: File, remote: FakeRemote): CanopyReferenceImageRepository =
        CanopyReferenceImageRepository(
            root = root,
            configSource = remote.source,
            downloader = remote.downloader,
            validator = { it.decodeToString().startsWith("IMG-") },
        )

    private fun config(images: Map<String, CanopyReferenceRemoteImage>) =
        CanopyReferenceConfiguration("guide-images", "config-v1", images)

    @Test
    fun `fresh install downloads once persists and unchanged relaunch downloads zero images`() = runTest {
        val root = root()
        val image = CanopyReferenceRemoteImage("canopy-reference/vsp-small.png", "v1")
        val remote = FakeRemote(config(mapOf("canopy.vsp.small" to image)), mutableMapOf(image.path to validA))
        val first = repository(root, remote)

        first.refresh()
        assertEquals(listOf(image.path), remote.imageRequests)
        assertNotNull(first.localFile("canopy.vsp.small"))

        val restarted = repository(root, remote)
        restarted.refresh()
        assertEquals(listOf(image.path), remote.imageRequests)
        assertArrayEquals(validA, restarted.localFile("canopy.vsp.small")!!.readBytes())
    }

    @Test
    fun `re-entering Spray Setup performs one session refresh and no repeat downloads`() = runTest {
        val image = CanopyReferenceRemoteImage("canopy-reference/vsp-medium.png", "v1")
        val remote = FakeRemote(config(mapOf("canopy.vsp.medium" to image)), mutableMapOf(image.path to validA))
        val subject = repository(root(), remote)

        subject.refreshOncePerSession()
        subject.refreshOncePerSession()
        subject.refreshOncePerSession()

        assertEquals(1, remote.configRequests)
        assertEquals(1, remote.imageRequests.size)
    }

    @Test
    fun `all eight unchanged download zero and changing one downloads exactly one`() = runTest {
        val initial = SprayCanopyReferenceImages.slotKeys.mapIndexed { index, slot ->
            slot to CanopyReferenceRemoteImage("canopy-reference/$index.png", "v1")
        }.toMap()
        val remote = FakeRemote(config(initial), initial.values.associate { it.path to validA }.toMutableMap())
        val subject = repository(root(), remote)
        subject.refresh()
        assertEquals(8, remote.imageRequests.size)

        remote.imageRequests.clear()
        subject.refresh()
        assertTrue(remote.imageRequests.isEmpty())

        val replacement = CanopyReferenceRemoteImage("canopy-reference/replacement.png", "v2")
        remote.configuration = config(initial + ("canopy.sprawl.large" to replacement))
        remote.payloads[replacement.path] = validB
        subject.refresh()
        assertEquals(listOf(replacement.path), remote.imageRequests)
    }

    @Test
    fun `offline relaunch uses local custom while fresh offline install has no custom file`() = runTest {
        val root = root()
        val image = CanopyReferenceRemoteImage("canopy-reference/full.png", "v1")
        val remote = FakeRemote(config(mapOf("canopy.vsp.full" to image)), mutableMapOf(image.path to validA))
        repository(root, remote).refresh()

        val offline = FakeRemote(config(emptyMap()), mutableMapOf()).apply { configFailure = true }
        val relaunched = repository(root, offline)
        relaunched.refresh()
        assertNotNull(relaunched.localFile("canopy.vsp.full"))

        val freshOffline = repository(root(), offline)
        freshOffline.refresh()
        assertNull(freshOffline.localFile("canopy.vsp.full"))
    }

    @Test
    fun `failed and corrupt replacement keep previous local image visible`() = runTest {
        val original = CanopyReferenceRemoteImage("canopy-reference/original.png", "v1")
        val remote = FakeRemote(config(mapOf("canopy.sprawl.small" to original)), mutableMapOf(original.path to validA))
        val subject = repository(root(), remote)
        subject.refresh()
        val originalFile = subject.localFile("canopy.sprawl.small")

        val replacement = CanopyReferenceRemoteImage("canopy-reference/replacement.png", "v2")
        remote.configuration = config(mapOf("canopy.sprawl.small" to replacement))
        remote.failingPaths += replacement.path
        subject.refresh()
        assertEquals(originalFile, subject.localFile("canopy.sprawl.small"))

        remote.failingPaths.clear()
        remote.payloads[replacement.path] = "corrupt".encodeToByteArray()
        subject.refresh()
        assertEquals(originalFile, subject.localFile("canopy.sprawl.small"))
        assertEquals(original.path, subject.manifestEntry("canopy.sprawl.small")?.remotePath)
    }

    @Test
    fun `admin reset removes custom file and restores packaged fallback path`() = runTest {
        val image = CanopyReferenceRemoteImage("canopy-reference/reset.png", "v1")
        val remote = FakeRemote(config(mapOf("canopy.sprawl.full" to image)), mutableMapOf(image.path to validA))
        val subject = repository(root(), remote)
        subject.refresh()
        val oldFile = subject.localFile("canopy.sprawl.full")!!

        remote.configuration = config(emptyMap())
        subject.refresh()

        assertNull(subject.localFile("canopy.sprawl.full"))
        assertNull(subject.manifestEntry("canopy.sprawl.full"))
        assertFalse(oldFile.exists())
        assertEquals("canopy_sprawl_full", SprayCanopyReferenceImages.drawableName(
            SprayCalculator.CanopyType.SPRAWL,
            SprayCalculator.CanopySize.FULL,
        ))
    }

    @Test
    fun `Android semantic slots match the shared eight keys and calculations stay unchanged`() {
        assertEquals(
            setOf(
                "canopy.vsp.small", "canopy.vsp.medium", "canopy.vsp.large", "canopy.vsp.full",
                "canopy.sprawl.small", "canopy.sprawl.medium", "canopy.sprawl.large", "canopy.sprawl.full",
            ),
            SprayCanopyReferenceImages.slotKeys,
        )
        assertEquals(75.0, SprayCalculator.litresPer100m(
            CanopyWaterRates.defaults,
            SprayCalculator.CanopyType.VSP,
            SprayCalculator.CanopySize.FULL,
            SprayCalculator.CanopyDensity.HIGH,
        ), 0.0)
        assertEquals(90.0, SprayCalculator.litresPer100m(
            CanopyWaterRates.defaults,
            SprayCalculator.CanopyType.SPRAWL,
            SprayCalculator.CanopySize.FULL,
            SprayCalculator.CanopyDensity.HIGH,
        ), 0.0)
    }
}

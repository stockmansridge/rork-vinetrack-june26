package com.rork.vinetrack.data.auth

import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ApplicationInfo
import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Disposable filesystem only; no server account, storage reset, or admission bypass. */
@RunWith(AndroidJUnit4::class)
class RecoveryStorageInventoryAndroidTest {
    private lateinit var root: File
    private lateinit var fixture: Context
    @Before fun setup() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        root = File(base.cacheDir, "recovery-inventory-${UUID.randomUUID()}").also { check(it.mkdir()) }
        File(root, "files").mkdir(); File(root, "cache").mkdir()
        fixture = object : ContextWrapper(base) {
            override fun getFilesDir(): File = File(root, "files")
            override fun getCacheDir(): File = File(root, "cache")
            override fun getApplicationInfo(): ApplicationInfo = ApplicationInfo(base.applicationInfo).apply { dataDir = root.path }
        }
    }
    @After fun cleanup() {
        if (::root.isInitialized) {
            check(root.name.startsWith("recovery-inventory-"))
            check(root.deleteRecursively())
        }
    }
    private fun capture() = RecoveryStorageInventory.capture(fixture)
    private fun filesRoot() = capture().roots.first { it.area == RecoveryStorageReport.Area.FILES }
    private fun snapshot() = root.walkTopDown().filter { it.isFile }.associate { it.relativeTo(root).path to it.readBytes().toList() }

    @Test fun reportsEveryUnknownTopLevelEntryWithoutReadingItsContents() {
        File(fixture.filesDir, "one.bin").writeText("PRIVATE_CONTENT_ONE")
        File(fixture.filesDir, "two.bin").writeText("PRIVATE_CONTENT_TWO")
        val before = snapshot()
        val report = capture()
        assertEquals(2, report.roots.first().entries.size)
        assertTrue(report.reviewedText().contains("one.bin")); assertTrue(report.reviewedText().contains("two.bin"))
        assertFalse(report.reviewedText().contains("PRIVATE_CONTENT"))
        assertFalse(report.safeSummary().contains("one.bin"))
        assertEquals(before, snapshot())
    }
    @Test fun preferenceValuesAreNeverOpenedOrReturned() {
        val prefs = File(root, "shared_prefs").also { check(it.mkdir()) }
        File(prefs, "vinetrack_session.xml").writeText("CREDENTIAL_SECRET_DO_NOT_READ")
        val before = snapshot()
        assertTrue(capture().reviewedText().contains("vinetrack_session.xml"))
        assertFalse(capture().reviewedText().contains("CREDENTIAL_SECRET"))
        assertEquals(before, snapshot())
    }
    @Test fun directoryContentsAndSymlinkTargetsAreNotEnumerated() {
        val dir = File(fixture.filesDir, "retained-folder").also { check(it.mkdir()) }
        File(dir, "private-nested-name").writeText("PRIVATE_NESTED_BYTES")
        Os.symlink(dir.path, File(fixture.filesDir, "linked-folder").path)
        val report = capture().reviewedText()
        assertTrue(report.contains("SYMBOLIC_LINK"))
        assertFalse(report.contains("private-nested-name")); assertFalse(report.contains("PRIVATE_NESTED_BYTES"))
        assertFalse(report.contains(root.absolutePath))
        check(File(fixture.filesDir, "linked-folder").delete())
    }
    @Test fun danglingLinksAreReportedRatherThanTreatedAsAbsent() {
        val link = File(fixture.filesDir, "dangling")
        Os.symlink(File(root, "missing-target").path, link.path)
        assertEquals(RecoveryStorageReport.Kind.SYMBOLIC_LINK, filesRoot().entries.single().kind)
        assertFalse(capture().reviewedText().contains("missing-target"))
        assertTrue(Os.readlink(link.path).endsWith("missing-target"))
        check(link.delete())
    }
    @Test fun linkedPreferenceRootIsNotTraversed() {
        val target = File(root, "other").also { check(it.mkdir()) }
        File(target, "PRIVATE_TARGET_NAME").writeText("PRIVATE_TARGET_CONTENT")
        val link = File(root, "shared_prefs")
        Os.symlink(target.path, link.path)
        val report = capture()
        assertEquals(RecoveryStorageReport.Status.LINK_OR_ALIAS, report.roots[1].status)
        assertFalse(report.reviewedText().contains("PRIVATE_TARGET"))
        check(link.delete())
    }
    @Test fun oversizedListingIsBoundedAndExplicitlyIncomplete() {
        repeat(257) { File(fixture.filesDir, "entry-$it").writeText("") }
        val rootReport = filesRoot()
        assertEquals(257, rootReport.totalEntries)
        assertEquals(256, rootReport.entries.size)
        assertTrue(rootReport.truncated)
    }
    @Test fun hardLinksAreMarkedWithoutModifyingBytes() {
        val first = File(fixture.filesDir, "original").also { it.writeText("RETAINED_BYTES") }
        val second = File(fixture.filesDir, "alias")
        Os.link(first.path, second.path)
        assertTrue(filesRoot().entries.all { it.multipleLinks })
        assertEquals("RETAINED_BYTES", first.readText()); assertEquals("RETAINED_BYTES", second.readText())
    }
    @Test fun cameraRootAndMissingPreferenceRootAreReportedSeparately() {
        val camera = File(fixture.cacheDir, "camera-captures").also { check(it.mkdir()) }
        File(camera, "pending.jpg").writeBytes(byteArrayOf(1, 2, 3))
        val report = capture()
        assertEquals(RecoveryStorageReport.Status.ABSENT, report.roots[1].status)
        assertTrue(report.reviewedText().contains("cache/camera-captures/pending.jpg"))
        assertArrayEquals(byteArrayOf(1, 2, 3), File(camera, "pending.jpg").readBytes())
    }
}

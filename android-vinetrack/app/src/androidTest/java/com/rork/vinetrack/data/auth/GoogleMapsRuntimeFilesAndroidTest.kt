package com.rork.vinetrack.data.auth

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

/** Metadata contract tests on disposable files only; never touch production records. */
@RunWith(AndroidJUnit4::class)
class GoogleMapsRuntimeFilesAndroidTest {
    private lateinit var root: File
    private lateinit var files: File
    private val app = "com.rork.vinetrack"
    private val names = listOf("DATA_ServerControlledParametersManager.data.v1.$app", "SavedClientParameters.data.cs", "_m_t")
    @Before fun setup() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        root = File(base.cacheDir, "maps-runtime-test-${UUID.randomUUID()}").canonicalFile.also { check(it.mkdir()) }
        files = File(root, "files").also { check(it.mkdir()) }
    }
    @After fun cleanup() {
        if (::root.isInitialized) {
            check(root.name.startsWith("maps-runtime-test-"))
            // Remove direct fixture symlinks before recursive cleanup, even after a failed assertion.
            files.listFiles()?.forEach { file ->
                if (android.system.OsConstants.S_ISLNK(Os.lstat(file.path).st_mode)) check(file.delete())
            }
            check(root.deleteRecursively())
        }
    }
    private fun validate(file: File) = GoogleMapsRuntimeFiles.validate(file, files, app)
    private fun reject(file: File) { assertTrue(runCatching { validate(file) }.isFailure) }

    @Test fun observedLengthsPassTogetherAndBytesAreUnchanged() {
        val lengths = listOf(44468, 55534, 234)
        names.zip(lengths).forEach { (name, length) ->
            val bytes = ByteArray(length) { (it % 251).toByte() }
            val file = File(files, name).also { it.writeBytes(bytes) }
            val modified = file.lastModified()
            validate(file)
            assertArrayEquals(bytes, file.readBytes())
            assertEquals(modified, file.lastModified())
        }
        assertEquals(3, files.listFiles()!!.size)
    }
    @Test fun emptyAndChangedSdkPayloadsDoNotNeedBusinessSchemas() {
        val file = File(files, "_m_t")
        listOf(byteArrayOf(), byteArrayOf(1), ByteArray(1024) { 127 }).forEach { bytes ->
            file.writeBytes(bytes)
            validate(file)
            assertArrayEquals(bytes, file.readBytes())
        }
    }
    @Test fun directoryCannotHideRecordsBehindRuntimeName() {
        names.forEach { name ->
            val dir = File(files, name).also { check(it.mkdir()) }
            val retained = File(dir, "retained-work").also { it.writeText("synthetic work") }
            reject(dir)
            assertEquals("synthetic work", retained.readText())
        }
    }
    @Test fun symlinksAreRejectedWithoutReadingOrChangingTarget() {
        val target = File(root, "target").also { it.writeText("synthetic private bytes") }
        names.forEach { name ->
            val link = File(files, name)
            Os.symlink(target.path, link.path)
            reject(link)
            assertEquals(target.path, Os.readlink(link.path))
            assertEquals("synthetic private bytes", target.readText())
            check(link.delete())
        }
    }
    @Test fun danglingLinksAreRejectedAndRemainLinks() {
        val link = File(files, "_m_t")
        val target = File(root, "absent-target").path
        Os.symlink(target, link.path)
        reject(link)
        assertEquals(target, Os.readlink(link.path))
        check(link.delete())
    }
    @Test fun hardLinksCannotAliasRetainedWork() {
        val target = File(root, "target").also { it.writeText("synthetic private bytes") }
        names.forEach { name ->
            val link = File(files, name)
            Os.link(target.path, link.path)
            reject(link)
            assertEquals("synthetic private bytes", target.readText())
            check(link.delete())
        }
    }
    @Test fun fifosAreRejectedWithoutOpeningOrBlocking() {
        val fifo = File(files, "_m_t")
        Os.mkfifo(fifo.path, 384)
        reject(fifo)
        check(fifo.delete())
    }
    @Test fun recognisedBasenameOutsideRootIsRejected() {
        val outside = File(root, "_m_t").also { it.writeText("outside") }
        reject(outside)
        assertEquals("outside", outside.readText())
    }
    @Test fun nestedRecognisedNameIsRejected() {
        val dir = File(files, "nested").also { check(it.mkdir()) }
        val nested = File(dir, "_m_t").also { it.writeText("nested") }
        reject(nested)
        assertEquals("nested", nested.readText())
    }
    @Test fun unknownFileCannotCallValidatorDirectly() {
        val unknown = File(files, "private-note").also { it.writeText("retained") }
        reject(unknown)
        assertEquals("retained", unknown.readText())
    }
    @Test fun foreignPackageParameterFileIsRejected() {
        val file = File(files, "DATA_ServerControlledParametersManager.data.v1.com.other.app").also { it.writeText("retained") }
        reject(file)
        assertEquals("retained", file.readText())
    }
    @Test fun missingRecognisedFileDoesNotBecomeAValidationSuccess() {
        reject(File(files, "_m_t"))
        assertFalse(File(files, "_m_t").exists())
    }
}

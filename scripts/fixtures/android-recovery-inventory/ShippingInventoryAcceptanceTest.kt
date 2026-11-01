package com.rork.vinetrack.data.auth

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.MainActivity
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Supplemental diagnostic acceptance on an isolated emulator, never a customer installation.
 * Stage only this class and use the runner's unmodified className (shipping Application).
 * No fixture Application, transport override, storage reset or production-source changes.
 */
@RunWith(AndroidJUnit4::class)
class ShippingInventoryAcceptanceTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test fun shippingColdLaunchReviewsClosesAndSeparatelyCopiesWithoutChangingRetainedState() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext
        assertEquals(Application::class.java, app.javaClass)
        assertEquals("com.rork.vinetrack", app.packageName)
        val data = File(app.applicationInfo.dataDir).canonicalFile
        assertEquals(File(data, "files"), app.filesDir.canonicalFile)
        assertEquals(File(data, "cache"), app.cacheDir.canonicalFile)
        assertFalse(app.filesDir.path.contains("clean_exit_fixture"))
        val providers = app.packageManager.getPackageInfo(app.packageName, PackageManager.GET_PROVIDERS)
            .providers.orEmpty().map { it.name }
        assertTrue("Shipping Startup provider must be installed", providers.contains("androidx.startup.InitializationProvider"))
        // Reaching this point uses the real Application/provider lifecycle before any Activity.
        android.util.Log.i("InventoryShippingAcceptance", "application=${app.javaClass.name}; files=${app.filesDir}; cache=${app.cacheDir}; data=$data; providers=$providers; startup=${RecoveryStorageInventory.capture(app).reviewedText()}")
        val first = File(app.filesDir, "00_inventory_probe_A")
        val second = File(app.filesDir, "01_inventory_probe_B")
        assertFalse(first.exists())
        assertFalse(second.exists())
        first.writeText("retained-probe-A-not-for-report")
        second.writeText("retained-probe-B-not-for-report")
        val session = SessionStore(app)
        assertTrue("Unknown retained bytes must keep the normal guard locked", session.retentionGuard.isLocked)
        val clipboard = app.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        fun clipboardText(): String? {
            var text: String? = null
            instrumentation.runOnMainSync { text = clipboard.primaryClip?.getItemAt(0)?.text?.toString() }
            return text
        }
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            compose.onNodeWithText("Local work protected").assertIsDisplayed()
            compose.onNodeWithText("Restore original account").assertIsNotEnabled()
            listOf("Account email", "Password").forEach { label ->
                assertEquals("", compose.onNodeWithText(label).fetchSemanticsNode().config[SemanticsProperties.EditableText].text)
            }
            // Snapshot only after ordinary MainActivity initialization and initial composition.
            compose.waitForIdle()
            val preferenceFiles = File(data, "shared_prefs").listFiles().orEmpty().filter { it.isFile }
            val preferenceBytes = preferenceFiles.associate { it.name to it.readBytes().toList() }
            val sessionBefore = app.getSharedPreferences("vinetrack_session", Context.MODE_PRIVATE).all.toMap()
            val guardEpoch = session.retentionGuard.identityEpoch.value
            val principal = session.recoveryPrincipal
            val permissionBefore = app.checkSelfPermission(android.Manifest.permission.CAMERA)
            val marker = "inventory-clipboard-sentinel"
            instrumentation.runOnMainSync { clipboard.setPrimaryClip(ClipData.newPlainText("sentinel", marker)) }
            assertEquals(marker, clipboardText())
            fun openReview() {
                compose.onNodeWithText("Review storage inventory").performScrollTo().performClick()
                compose.waitUntil(10_000) { compose.onAllNodesWithText("Copy reviewed inventory").fetchSemanticsNodes().size == 1 }
                // The report's real Text contains both unknown top-level names before copy.
                compose.onNodeWithText("files/00_inventory_probe_A", substring = true).assertIsDisplayed()
                compose.onNodeWithText("files/01_inventory_probe_B", substring = true).assertExists()
                compose.onNodeWithText("Copy reviewed inventory").assertIsDisplayed()
                assertEquals(marker, clipboardText())
            }
            openReview()
            compose.onNodeWithText("Close", useUnmergedTree = true).performClick()
            compose.onNodeWithText("Copy reviewed inventory").assertDoesNotExist()
            assertEquals(marker, clipboardText())
            assertTrue(session.retentionGuard.isLocked)
            openReview()
            compose.onNodeWithText("Copy reviewed inventory").performClick()
            val copied = clipboardText() ?: error("Explicit copy did not populate clipboard")
            assertTrue(copied.startsWith("VineTrack Android storage inventory v1"))
            assertTrue(copied.contains("files/00_inventory_probe_A"))
            assertTrue(copied.contains("files/01_inventory_probe_B"))
            assertFalse(copied.contains("retained-probe-A-not-for-report"))
            assertFalse(copied.contains("retained-probe-B-not-for-report"))
            assertFalse(copied.contains(data.path))
            assertEquals("retained-probe-A-not-for-report", first.readText())
            assertEquals("retained-probe-B-not-for-report", second.readText())
            assertEquals(sessionBefore, app.getSharedPreferences("vinetrack_session", Context.MODE_PRIVATE).all.toMap())
            assertEquals(preferenceBytes, File(data, "shared_prefs").listFiles().orEmpty().filter { it.isFile }.associate { it.name to it.readBytes().toList() })
            assertTrue(session.retentionGuard.isLocked)
            assertEquals(guardEpoch, session.retentionGuard.identityEpoch.value)
            assertEquals(principal, session.recoveryPrincipal)
            assertEquals(permissionBefore, app.checkSelfPermission(android.Manifest.permission.CAMERA))
            scenario.recreate()
            compose.onNodeWithText("Local work protected").assertIsDisplayed()
            assertTrue(SessionStore(app).retentionGuard.isLocked)
            android.util.Log.i("InventoryShippingAcceptance", "PASS: shipping roots, multiple unknown names, locked credential-free review, no copy on open/close, separate copy, exact probe/preference bytes, unchanged guard/epoch/principal/permission and Activity recreation")
        }
    }
}

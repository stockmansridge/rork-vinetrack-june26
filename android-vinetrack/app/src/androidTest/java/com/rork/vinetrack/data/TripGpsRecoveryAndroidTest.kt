package com.rork.vinetrack.data

import android.content.Intent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Actual isolated Android process termination, real scoped preferences, synthetic read-only transport. */
class TripGpsRecoveryAndroidTest {
    @Test(timeout = 60000) fun interruptedLegacyGpsMarkerSurvivesProcessKillAndVerifiesCompletedTrip() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val automation = instrumentation.uiAutomation
        val id = UUID.randomUUID().toString()
        fun text(node: AccessibilityNodeInfo?, prefix: String): String? {
            if (node == null) return null
            node.text?.toString()?.takeIf { it.startsWith(prefix) }?.let { return it }
            for (index in 0 until node.childCount) text(node.getChild(index), prefix)?.let { return it }
            return null
        }
        fun launch(mode: String, prefix: String): String {
            automation.executeAndWaitForEvent({
                context.startActivity(Intent().setClassName(context.packageName,
                    "com.rork.vinetrack.data.LegacySprayProcessProbeActivity")
                    .putExtra("case", id).putExtra("mode", mode)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
            }, { text(automation.rootInActiveWindow, prefix) != null }, 10000)
            return requireNotNull(text(automation.rootInActiveWindow, prefix))
        }
        try {
            val originalPid = launch("GPS_CLAIMED", "GPS_RETAINED_").removePrefix("GPS_RETAINED_").toInt()
            assertNotEquals(android.os.Process.myPid(), originalPid)
            android.os.Process.killProcess(originalPid)
            val restartedPid = launch("GPS_RECOVER", "GPS_RECOVERED_").removePrefix("GPS_RECOVERED_").toInt()
            assertNotEquals(originalPid, restartedPid)
        } finally {
            assertEquals("LEGACY_CLEANED", launch("cleanup", "LEGACY_CLEANED"))
        }
    }
}

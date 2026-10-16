package com.rork.vinetrack.data

import android.content.Intent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Isolated real process kill/relaunch; production caches/stores, no network or customer data. */
class SprayProgramTankProcessAndroidTest {
    @Test(timeout = 60000) fun programAndTwoLinkedTankActualsSurviveProcessDeath() {
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
            val pid = launch("PROGRAM_TANK_WRITE", "PROGRAM_TANK_RETAINED_").removePrefix("PROGRAM_TANK_RETAINED_").toInt()
            assertNotEquals(android.os.Process.myPid(), pid)
            android.os.Process.killProcess(pid)
            val next = launch("PROGRAM_TANK_READ", "PROGRAM_TANK_RECOVERED_").removePrefix("PROGRAM_TANK_RECOVERED_").toInt()
            assertNotEquals(pid, next)
        } finally {
            assertEquals("LEGACY_CLEANED", launch("cleanup", "LEGACY_CLEANED"))
        }
    }
}

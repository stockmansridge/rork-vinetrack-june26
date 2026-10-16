package com.rork.vinetrack.data

import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.SharedPreferences
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.*
import com.rork.vinetrack.ui.screens.QuickActionsSection
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.util.UUID

/** Real local storage and production Home controls; no customer sessions or HTTP. */
class OfflineQuickActionsAndroidTest {
    @get:Rule val compose = createComposeRule()

    @Test fun productionHomeActionsRemainVisibleAndRouteWithoutNetwork() {
        var repairs = 0; var growth = 0; var pins = 0
        compose.setContent { MaterialTheme {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) {
                QuickActionsSection({ repairs++ }, { growth++ }, { pins++ })
            }
        } }
        repeat(3) {
            compose.onNodeWithText("QUICK ACTIONS").assertIsDisplayed()
            compose.onNodeWithText("Repairs").assertIsDisplayed().performClick()
            compose.onNodeWithText("Growth").assertIsDisplayed().performClick()
            compose.onNodeWithText(UnifiedPinContract.QUICK_ACTION_TITLE).assertIsDisplayed().performClick()
        }
        compose.runOnIdle { assertEquals(3, repairs); assertEquals(3, growth); assertEquals(3, pins) }
    }

    @Test fun verifiedConfigsEmptyResultsRevocationAndUnsyncedEditsSurviveRecreation() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val prefix = "offline-actions-${UUID.randomUUID()}-"
        val names = mutableSetOf<String>()
        val context = object : ContextWrapper(base) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                names.add(name); return base.getSharedPreferences(prefix + name, mode)
            }
        }
        try {
            val session = SessionStore(context)
            session.save("synthetic-access", "synthetic-refresh", "user", null)
            val epoch = session.retentionGuard.identityEpoch.value
            val cache = DomainCacheRepository(context)
            cache.saveVineyards("user", emptyList())
            for ((vineyard, role) in listOf("A" to "owner", "B" to "operator", "C" to "supervisor")) {
                cache.saveQuickActions("user", vineyard, epoch,
                    members = listOf(VineyardMember(vineyardId = vineyard, userId = "user", role = role)),
                    buttons = ButtonConfigRepository.LauncherButtons(repair = listOf(LauncherButton(name = vineyard, vineyardId = vineyard))))
            }
            for (vineyard in listOf("A", "B", "A", "C", "B")) {
                val restored = DomainCacheRepository(context).loadQuickActions("user", vineyard, epoch)!!
                assertEquals(vineyard, restored.buttons!!.repair.single().name)
                assertEquals(vineyard, restored.members!!.single().vineyardId)
            }
            val pending = PendingWriteRepository(context)
            val edited = listOf(LauncherButton(name = "Unsynced", vineyardId = "A"))
            ButtonConfigUpdateSync(ButtonConfigRepository(session), pending).enqueue("A", "repair_buttons", edited, "2026-10-16T08:00:00Z")
            val restored = DomainCacheRepository(context).loadQuickActions("user", "A", epoch)!!
            val overlaid = PendingWriteOverlay.overlayButtonConfig(restored.buttons!!.repair, emptyList(), PendingWriteRepository(context).list(), "A")
            assertEquals(edited, overlaid.first)
            cache.saveQuickActions("user", "B", epoch, buttons = ButtonConfigRepository.LauncherButtons(), members = emptyList())
            assertTrue(DomainCacheRepository(context).loadQuickActions("user", "B", epoch)!!.buttons!!.repair.isEmpty())
            assertTrue(DomainCacheRepository(context).loadQuickActions("user", "B", epoch)!!.members!!.isEmpty())
            assertNull(cache.loadQuickActions("another", "A", epoch))
            assertNull(cache.loadQuickActions("user", "A", epoch + 1))
            assertNull(cache.loadQuickActions("user", "unvisited", epoch))
        } finally { names.forEach { base.deleteSharedPreferences(prefix + it) } }
    }

}

/** Kept separate from Compose tests: its secondary-process task owns the foreground window. */
class OfflineQuickActionsProcessAndroidTest {
    @Test(timeout = 60000) fun realProcessKillRetainsTwoVineyardConfigsPinsAndPhotos() {
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
            val pid = launch("QUICK_ACTIONS_WRITE", "QUICK_ACTIONS_RETAINED_").removePrefix("QUICK_ACTIONS_RETAINED_").toInt()
            assertNotEquals(android.os.Process.myPid(), pid)
            android.os.Process.killProcess(pid)
            val next = launch("QUICK_ACTIONS_READ", "QUICK_ACTIONS_RECOVERED_").removePrefix("QUICK_ACTIONS_RECOVERED_").toInt()
            assertNotEquals(pid, next)
        } finally { assertEquals("LEGACY_CLEANED", launch("cleanup", "LEGACY_CLEANED")) }
    }
}

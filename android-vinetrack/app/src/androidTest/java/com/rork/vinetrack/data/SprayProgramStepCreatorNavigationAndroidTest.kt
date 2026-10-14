package com.rork.vinetrack.data

import android.app.Application
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.model.VineyardMember
import com.rork.vinetrack.ui.AppUiState
import com.rork.vinetrack.ui.AppViewModel
import com.rork.vinetrack.ui.screens.SpraysScreen
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpStatusCode
import org.junit.After
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID

/** Rendered production Program -> editor navigation with isolated state, not a live login journey. */
class SprayProgramStepCreatorNavigationAndroidTest {
    @get:Rule val compose = createComposeRule()
    private val models = ViewModelStore()
    private var client: HttpClient? = null
    private var root: File? = null
    private var namespace: String? = null
    private val preferenceNames = java.util.Collections.synchronizedSet(linkedSetOf<String>())

    @After fun cleanUp() {
        compose.runOnUiThread { models.clear() }
        SupabaseClient.installInstrumentationTransport(null)
        client?.close()
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        namespace?.let { prefix -> preferenceNames.forEach { base.getSharedPreferences(prefix + it, Context.MODE_PRIVATE).edit().clear().commit() } }
        root?.deleteRecursively()
    }

    @Test fun emptyStateOpensCanonicalCreatorWithThreeNormalMethods() {
        openProgram(admin = false)
        compose.onNodeWithText("Add Program Step", substring = true).performClick()
        compose.mainClock.advanceTimeBy(1_000)
        assertCreator()
        openMethodMenu()
        compose.onNodeWithText("Banded Spray").assertExists()
        compose.onNodeWithText("Spreader").assertExists()
        compose.onNodeWithText("Fertigation").assertDoesNotExist()
    }

    @Test fun addMenuOpensSameCreatorAndAdminCanChooseFertigation() {
        openProgram(admin = true)
        compose.onNodeWithContentDescription("New spray").performClick()
        compose.mainClock.advanceTimeBy(300)
        compose.onNode(hasText("Add Program Step") and hasAnyAncestor(isPopup())).performClick()
        compose.mainClock.advanceTimeBy(1_000)
        assertCreator()
        compose.onNodeWithText("Program Step name").performTextInput("Unsaved nutrient step")
        compose.mainClock.advanceTimeBy(300)
        openMethodMenu()
        compose.onNodeWithText("Fertigation").performClick()
        compose.mainClock.advanceTimeBy(300)
        compose.onNodeWithText("Spray unit").assertDoesNotExist()
        compose.onNodeWithText("TARGETS").assertDoesNotExist()
        compose.onNodeWithText("Program Step name").performScrollTo().assertTextContains("Unsaved nutrient step")
    }

    private fun assertCreator() {
        compose.onNodeWithText("Create Program Step").assertExists()
        compose.onNodeWithText("Program Step name").assertExists()
        compose.onNodeWithText("GROWTH STAGE").assertExists()
        compose.onNodeWithText("Method").assertExists()
        compose.onNodeWithText("New Program Record").assertDoesNotExist()
    }

    private fun openMethodMenu() {
        compose.onNodeWithText("Method").performScrollTo()
        compose.mainClock.advanceTimeBy(300)
        compose.onNodeWithText("Method").performClick()
        compose.mainClock.advanceTimeBy(300)
    }

    private fun openProgram(admin: Boolean) {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val prefix = "program_navigation_${UUID.randomUUID()}_"
        namespace = prefix
        val isolatedRoot = File(base.cacheDir, prefix).apply { mkdirs() }
        root = isolatedRoot
        val wrapped = object : ContextWrapper(base) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
                preferenceNames.add(name)
                return base.getSharedPreferences(prefix + name, mode)
            }
            override fun getFilesDir(): File = File(isolatedRoot, "files").apply { mkdirs() }
            override fun getCacheDir(): File = File(isolatedRoot, "cache").apply { mkdirs() }
        }
        val app = object : Application() {
            init { attachBaseContext(wrapped) }
            override fun getApplicationContext(): Context = this
        }
        client = HttpClient(MockEngine { respond("Synthetic UI: no live fallback", HttpStatusCode.ServiceUnavailable) })
        SupabaseClient.installInstrumentationTransport(client)
        lateinit var vm: AppViewModel
        compose.runOnUiThread { vm = AppViewModel(app); models.put("isolated-program", vm) }
        val vineyard = UUID.randomUUID().toString(); val user = UUID.randomUUID().toString()
        val state = AppUiState(selectedVineyardId = vineyard, currentUserId = user,
            members = listOf(VineyardMember(vineyardId = vineyard, userId = user, role = "manager")),
            isSystemAdmin = admin, isOnline = false)
        org.junit.Assert.assertTrue(state.canManageSprayProgram)
        compose.setContent { MaterialTheme { SpraysScreen(vm, state) } }
        // The production sheet samples drag offsets every frame indefinitely.
        // Advance its real animation with a finite test clock, never wait for that sampler to finish.
        compose.mainClock.autoAdvance = false
    }
}

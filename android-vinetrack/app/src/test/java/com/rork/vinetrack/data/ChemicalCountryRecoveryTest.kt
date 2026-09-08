package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalLookupAdvisory
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ChemicalCountryRecoveryTest {
    private fun source(relative: String): String {
        val candidates = listOf(
            File(relative),
            File("app/$relative"),
            File("android-vinetrack/app/$relative"),
        )
        return candidates.firstOrNull { it.exists() }?.readText()
            ?: error("source not found for $relative")
    }

    @Test
    fun `missing country is rejected before any network setup`() = runBlocking {
        try {
            ChemicalInfoService().searchChemicals("Dithane", "  \n ")
            fail("missing country must fail closed")
        } catch (error: ChemicalInfoService.LookupException) {
            assertEquals(
                "Set this vineyard’s country to search the correct national chemical register.",
                error.message,
            )
        }
    }

    @Test
    fun `search gate requires confirmed country`() {
        assertFalse(ChemicalLookupAdvisory.canStartSearch("Dithane", false, ""))
        assertTrue(ChemicalLookupAdvisory.canStartSearch("Dithane", false, "AU"))
        assertEquals("New Zealand", ChemicalInfoService.requireVineyardCountry(" New Zealand "))
    }

    @Test
    fun `shared search opens current vineyard editor and preserves manual entry`() {
        val flow = source("src/main/java/com/rork/vinetrack/ui/screens/ChemicalMatchFlowSheet.kt")
        assertTrue(flow.contains("vineyard = selectedVineyard"))
        assertTrue(flow.contains("initialFocusCountry = true"))
        assertTrue(flow.contains("Set vineyard country"))
        assertTrue(flow.contains("Ask a vineyard Owner or Manager to set the country."))
        assertTrue(flow.contains("onClick = onEnterManually"))
        assertTrue(flow.contains("searchJob?.cancel()"))
    }

    @Test
    fun `country editor publishes only confirmed refreshed saves`() {
        val editor = source("src/main/java/com/rork/vinetrack/ui/screens/SettingsScreen.kt")
        val viewModel = source("src/main/java/com/rork/vinetrack/ui/AppViewModel.kt")
        assertTrue(editor.contains("if (ok) { country = c; onCountrySaved() }"))
        assertTrue(editor.contains("initialFocusCountry"))
        assertTrue(viewModel.contains("repo.updateVineyard(id, trimmed, country)"))
        assertTrue(viewModel.contains("repo.listMyVineyards()"))
        assertTrue(viewModel.contains("state.copy(vineyards = refreshed)"))
        assertFalse(viewModel.contains("state.vineyards.map { if (it.id == id) it.copy(name = trimmed, country = country)"))
    }
}

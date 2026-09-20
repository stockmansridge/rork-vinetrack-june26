package com.rork.vinetrack.ui.screens

import com.rork.vinetrack.data.model.LauncherButton
import com.rork.vinetrack.data.model.Pin
import org.junit.Assert.assertEquals
import org.junit.Test

class PinColorContractTest {
    private val vineyardA = "vineyard-a"

    @Test fun `all supported tokens use the shared exact argb contract`() {
        assertEquals(
            linkedMapOf(
                "red" to 0xFFFF3B30, "orange" to 0xFFFF9500, "yellow" to 0xFFFFCC00,
                "green" to 0xFF34C759, "darkgreen" to 0xFF1B7F3B, "mint" to 0xFF00C7BE,
                "teal" to 0xFF30B0C7, "cyan" to 0xFF32ADE6, "blue" to 0xFF007AFF,
                "indigo" to 0xFF5856D6, "purple" to 0xFFAF52DE, "pink" to 0xFFFF2D55,
                "brown" to 0xFFA2845E, "gray" to 0xFF8E8E93, "black" to 0xFF000000,
                "white" to 0xFFFFFFFF,
            ),
            pinColorHexByToken,
        )
        assertEquals("mint", normalizedPinColorToken("mint"))
        assertEquals("teal", normalizedPinColorToken("teal"))
        assertEquals("black", normalizedPinColorToken("black"))
        assertEquals("gray", normalizedPinColorToken("grey"))
    }

    @Test fun `configured repair colour overrides canonical and historical colour`() {
        val pin = Pin(id = "pin", vineyardId = vineyardA, category = "Vine Issue", buttonName = "Vine Issue", buttonColor = "green", mode = "Repairs")
        val config = PinColorConfiguration(vineyardA, listOf(button("repair-id", "Vine Issue", "yellow", "Repairs")), emptyList())
        assertEquals("yellow", pinColorToken(pin, config))
    }

    @Test fun `configured growth colour overrides historical stored colour`() {
        val pin = Pin(id = "pin", vineyardId = vineyardA, buttonName = "Powdery", buttonColor = "gray", mode = "Growth")
        val config = PinColorConfiguration(vineyardA, emptyList(), listOf(button("powdery-id", "Powdery", "pink", "Growth")))
        assertEquals("pink", pinColorToken(pin, config))
    }

    @Test fun `legacy unmatched pin uses stored colour and missing colour falls back safely`() {
        val config = PinColorConfiguration(vineyardA, emptyList(), emptyList())
        assertEquals("purple", pinColorToken(Pin(id = "one", vineyardId = vineyardA, buttonName = "Custom A", buttonColor = "purple", mode = "Repairs"), config))
        assertEquals("gray", pinColorToken(Pin(id = "two", vineyardId = vineyardA, buttonName = "Unknown", mode = "Repairs"), config))
    }

    @Test fun `stable identity survives rename and configuration is vineyard scoped`() {
        val pin = Pin(id = "pin", vineyardId = vineyardA, buttonName = "Old Name", buttonColor = "red", launcherButtonId = "stable", mode = "Repairs")
        val renamed = PinColorConfiguration(vineyardA, listOf(button("stable", "New Name", "cyan", "Repairs")), emptyList())
        val otherVineyard = PinColorConfiguration("vineyard-b", listOf(button("stable", "New Name", "blue", "Repairs")), emptyList())
        assertEquals("cyan", pinColorToken(pin, renamed))
        assertEquals("red", pinColorToken(pin, otherVineyard))
    }

    private fun button(id: String, name: String, color: String, mode: String): LauncherButton =
        LauncherButton(id = id, vineyardId = vineyardA, name = name, color = color, mode = mode)
}

package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Pin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Launcher identity contract used verbatim by PinEditSheetHost and quickCreate. */
class PinTypeKeyLauncherTest {
    @Test
    fun `persisted identity resolves button name then title then category`() {
        val base = Pin(id = "pin", vineyardId = "vineyard", mode = "Repairs")
        assertEquals(
            "repairs|button value",
            PinTypeKey.existing(base.copy(buttonName = " Button Value ", title = "Title", category = "Category")).toString(),
        )
        assertEquals(
            "repairs|title value",
            PinTypeKey.existing(base.copy(title = " Title   Value ", category = "Category")).toString(),
        )
        assertEquals(
            "repairs|category value",
            PinTypeKey.existing(base.copy(category = " Category Value ")).toString(),
        )
    }

    @Test
    fun `growth launcher persists E-L detail but compares canonical Growth Stage type`() {
        assertEquals(
            PinTypeKey.candidate("Growth", "Growth Stage EL 31"),
            PinTypeKey.candidate(" growth ", " Growth   Stage EL 33 "),
        )
        assertEquals("growth|growth stage", PinTypeKey.candidate("Growth", "Growth Stage EL 31").toString())
    }

    @Test
    fun `mode only legacy records are not broad duplicate candidates`() {
        val legacy = Pin(id = "pin", vineyardId = "vineyard", mode = "Repairs")
        assertNull(PinTypeKey.existing(legacy))
    }
}

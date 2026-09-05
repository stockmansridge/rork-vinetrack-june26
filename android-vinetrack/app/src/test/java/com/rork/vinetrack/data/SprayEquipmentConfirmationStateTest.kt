package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayEquipmentConfirmationState
import com.rork.vinetrack.data.spray.SprayEquipmentSelection
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SprayEquipmentConfirmationStateTest {
    private fun selection(
        blocks: List<String> = listOf("block-a"),
        equipmentId: String? = "unit-a",
        tractorId: String? = "tractor-a",
        fansJets: String = "6",
        pattern: String = "sequential",
        startPath: Double? = 1.5,
        direction: Boolean? = true,
    ) = SprayEquipmentSelection(blocks, equipmentId, tractorId, fansJets, pattern, startPath, direction)

    @Test fun `selected or prefilled equipment is not confirmed`() {
        assertFalse(SprayEquipmentConfirmationState().isConfirmed(selection()))
    }

    @Test fun `explicit confirmation completes equipment`() {
        val chosen = selection()
        assertTrue(SprayEquipmentConfirmationState().confirm(chosen).isConfirmed(chosen))
    }

    @Test fun `missing spray unit cannot be confirmed`() {
        val chosen = selection(equipmentId = null)
        assertFalse(SprayEquipmentConfirmationState().confirm(chosen).isConfirmed(chosen))
    }

    @Test fun `Not Set tractor is a valid confirmed choice`() {
        val chosen = selection(tractorId = null)
        assertTrue(SprayEquipmentConfirmationState().confirm(chosen).isConfirmed(chosen))
    }

    @Test fun `every equipment and path input invalidates confirmation`() {
        val chosen = selection()
        val confirmed = SprayEquipmentConfirmationState().confirm(chosen)
        val changes = listOf(
            selection(blocks = listOf("block-b")),
            selection(equipmentId = "unit-b"),
            selection(tractorId = "tractor-b"),
            selection(fansJets = "8"),
            selection(pattern = "everySecondRow"),
            selection(startPath = 2.5),
            selection(direction = false),
        )
        changes.forEach { assertFalse(confirmed.isConfirmed(it)) }
    }

    @Test fun `Free Drive confirms without start path or direction`() {
        val chosen = selection(pattern = "freeDrive", startPath = null, direction = null)
        assertTrue(SprayEquipmentConfirmationState().confirm(chosen).isConfirmed(chosen))
    }
}

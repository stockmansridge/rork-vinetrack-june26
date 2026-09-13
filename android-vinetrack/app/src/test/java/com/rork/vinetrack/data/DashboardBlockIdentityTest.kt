package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Test

class DashboardBlockIdentityTest {
    @Test
    fun `mixed-case activity ids count each current block once`() {
        val blockA = "53128d1c-d745-4d99-8194-52e0ba08767b"
        val blockB = "d68f9c97-7de0-4b7c-bf47-f5033120aa83"
        val unrelated = "68fbc907-21bd-453e-98c6-d301268ef825"

        val worked = dashboardWorkedBlockIds(
            currentBlockIds = listOf(blockA, blockB),
            pinBlockIds = listOf(blockA.uppercase(), "not-a-uuid"),
            tripBlockIds = listOf(blockA, blockB.uppercase(), blockB.uppercase()),
            sprayBlockIds = listOf(blockA.uppercase(), blockB, unrelated.uppercase()),
        )

        assertEquals(linkedSetOf(blockA, blockB), worked)
    }
}

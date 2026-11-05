package com.rork.vinetrack.data

import com.rork.vinetrack.ui.screens.GrowthStageBundledImages
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Test

/** Reference imagery must never invent a stage for an unrecorded block. */
class GrowthStageReferenceImageTest {
    @Test fun exactKnownStageUsesOwnBundledImage() {
        val ref = GrowthStageBundledImages.referenceFor("EL23")
        assertNotNull(ref)
        assertEquals("EL23", ref?.second)
    }

    @Test fun missingStageImageUsesNearestReferenceOnly() {
        assertEquals("EL12", GrowthStageBundledImages.referenceFor("EL13")?.second)
        assertEquals("EL23", GrowthStageBundledImages.referenceFor("EL23.5")?.second)
    }

    @Test fun missingObservationDoesNotInventELOne() {
        assertNull(GrowthStageBundledImages.referenceFor(null))
        assertNull(GrowthStageBundledImages.referenceFor(""))
        assertNull(GrowthStageBundledImages.referenceFor("not-a-stage"))
    }
}

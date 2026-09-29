package com.rork.vinetrack.ui.screens

import com.rork.vinetrack.data.chemical.MasterFrontLabel
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MasterFrontLabelContractTest {
    private val id = "a0000000-0000-4000-8000-000000000001"
    private val hash = "a".repeat(64)
    private val media = MasterFrontLabel(id, "AU:apvma:53576", hash, "https://example.com/label.pdf", "2022", 2,
        "$id/$hash/label.pdf", "$id/$hash/front-p2.png", "$id/$hash/thumb-p2.webp")

    @Test fun onlyExactProductRegistrationAndVersionCanDisplay() {
        assertTrue(media.belongsTo(id, "AU:apvma:53576"))
        assertFalse(media.belongsTo("b0000000-0000-4000-8000-000000000002", "AU:apvma:53576"))
        assertFalse(media.belongsTo(id, "AU:apvma:53577"))
        assertFalse(media.copy(documentSha256 = "b".repeat(64)).belongsTo(id, "AU:apvma:53576"))
        assertFalse(media.copy(physicalPage = 1).belongsTo(id, "AU:apvma:53576"))
        assertFalse(media.copy(thumbnailPath = "https://example.com/signed").belongsTo(id, "AU:apvma:53576"))
    }
}

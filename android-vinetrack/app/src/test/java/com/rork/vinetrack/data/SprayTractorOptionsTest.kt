package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.SprayTractorOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SprayTractorOptionsTest {
    @Test fun `options are active vineyard scoped tractors sorted by display name`() {
        val rows = listOf(
            SprayJobTemplateRepository.SprayTractor("b", "vineyard-a", name = "Zulu"),
            SprayJobTemplateRepository.SprayTractor("other", "vineyard-b", name = "Other"),
            SprayJobTemplateRepository.SprayTractor("deleted", "vineyard-a", name = "Deleted", deletedAt = "2026-01-01"),
            SprayJobTemplateRepository.SprayTractor("a", "vineyard-a", brand = "Case", model = "75"),
        )
        assertEquals(listOf("a", "b"), SprayTractorOptions.activeForVineyard(rows, "vineyard-a").map { it.id })
    }

    @Test fun `tractor query scopes vineyard and excludes archived rows`() {
        val path = SprayJobTemplateRepository.tractorFilterPath("vineyard-a")
        assertTrue(path.startsWith("tractors?"))
        assertTrue(path.contains("vineyard_id=eq.vineyard-a"))
        assertTrue(path.contains("deleted_at=is.null"))
        assertTrue(!path.contains("vineyard_machines"))
    }

    @Test fun `Not Set works and machine uuid cannot enter tractor identity`() {
        val options = listOf(SprayJobTemplateRepository.SprayTractor("tractor-id", "vineyard-a", name = "T1"))
        assertNull(SprayTractorOptions.selectedId(null, options))
        assertNull(SprayTractorOptions.selectedId("vineyard-machine-id", options))
        assertEquals("tractor-id", SprayTractorOptions.selectedId("tractor-id", options))
    }
}

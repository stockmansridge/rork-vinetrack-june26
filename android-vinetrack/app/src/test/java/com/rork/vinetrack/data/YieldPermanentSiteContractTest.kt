package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.SampleSite
import com.rork.vinetrack.data.model.YieldEstimationSession
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class YieldPermanentSiteContractTest {
    @Test fun physicalSiteIdsAndRevisionSnapshotSurviveJsonRoundtrip() {
        val block = UUID.randomUUID().toString()
        val physical = UUID.randomUUID().toString()
        val frozen = YieldSiteSetSource(UUID.randomUUID().toString(), UUID.randomUUID().toString(), 4)
        val original = YieldEstimationSession(
            id = UUID.randomUUID().toString(),
            vineyardId = UUID.randomUUID().toString(),
            createdAt = "2026-11-05T04:00:00Z",
            selectedPaddockIds = listOf(block),
            sampleSites = listOf(SampleSite(physical, block, rowNumber = 12, latitude = -34.0,
                longitude = 149.0, siteIndex = 1)),
            siteSetVersions = mapOf(block.lowercase() to frozen),
        )
        val wire = Json.encodeToString(original)
        val decoded = Json.decodeFromString<YieldEstimationSession>(wire)
        assertEquals(frozen, decoded.siteSetVersions[block.lowercase()])
        assertEquals(physical, decoded.sampleSites.single().id)
        assertEquals(-34.0, decoded.sampleSites.single().latitude, 0.0)
    }

    @Test fun oldSessionsDecodeWithoutSiteSets() {
        val legacy = YieldEstimationSession(
            id = UUID.randomUUID().toString(),
            vineyardId = UUID.randomUUID().toString(),
            createdAt = "2026-11-05T04:00:00Z",
        )
        val wire = Json.encodeToString(legacy).replace(Regex(",?\\\"siteSetVersions\\\":\\\\{\\\\}"), "")
        val decoded = Json.decodeFromString<YieldEstimationSession>(wire)
        assertTrue(decoded.siteSetVersions.isEmpty())
    }
}

package com.rork.vinetrack.data

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import com.rork.vinetrack.data.model.VineyardMember
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class WorkTaskAssignmentNamesAndroidTest {
    private fun withCache(body: (WorkTaskAssignmentNames, android.content.SharedPreferences) -> Unit) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val prefs = context.getSharedPreferences("assignment-test-${UUID.randomUUID()}", Context.MODE_PRIVATE)
        try { body(WorkTaskAssignmentNames(prefs), prefs) } finally { prefs.edit().clear().commit() }
    }
    @Test fun assignedMember() = withCache { c, _ -> assertEquals("Alex Chen", c.resolve("a", "v", "a", null, " Alex Chen ")) }
    @Test fun anotherMemberProfileUsesNonblankName() = withCache { c, _ ->
        val member = VineyardMember(userId = "m", vineyardId = "v", role = "operator", fullName = " ", displayName = "Sam")
        assertEquals("Sam", c.resolve("a", "v", "m", null, WorkTaskAssignmentNames.memberName(member)))
    }
    @Test fun externalResource() = withCache { c, _ -> assertEquals("River Crew", c.resolve("a", "v", null, "r", "River Crew")) }
    @Test fun unassignedNeverUsesOldLabel() = withCache { c, _ -> assertEquals("", c.resolve("a", "v", null, null, "Old name")) }
    @Test fun historicalDraftRejectsIdentifierFragments() = withCache { c, _ ->
        for (label in listOf("Vineyard member (12345678)", "User deadbeef", UUID.randomUUID().toString()))
            assertEquals("Assigned vineyard member", c.resolve("a", "v", "m", null, label))
    }
    @Test fun offlineReopenUsesPersistedPresentation() = withCache { c, prefs ->
        c.resolve("a", "v", "m", null, "Alex Chen")
        assertEquals("Alex Chen", WorkTaskAssignmentNames(prefs).resolve("a", "v", "m", null))
    }
    @Test fun vineyardAccountAndKindIsolation() = withCache { c, _ ->
        c.resolve("a", "v", "m", null, "Alex Chen")
        assertEquals("Assigned vineyard member", c.resolve("a", "other-v", "m", null))
        assertEquals("Assigned vineyard member", c.resolve("other-a", "v", "m", null))
        assertEquals("Assigned external resource", c.resolve("a", "v", null, "m"))
    }
    @Test fun inactiveHistoricalAssigneeRetainsResolvedName() = withCache { c, _ ->
        c.resolve("a", "v", "m", null, "Former operator")
        assertEquals("Former operator", c.resolve("a", "v", "m", null, ""))
    }
}

package com.rork.vinetrack.data

import com.rork.vinetrack.data.model.Pin
import com.rork.vinetrack.data.model.VineyardMember
import com.rork.vinetrack.data.model.resolvePinCreatorName
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * "Created by" resolution for the Pin Details sheet — the Android mirror of the
 * iOS `resolveDisplayName(userId:fallbackText:)` resolver used by
 * `PinDetailSheet`.
 *
 * The contract these fixtures lock in: the author comes from the pin's own
 * `created_by` column, never from whoever is currently signed in. A pin dropped
 * by another member must keep naming that member, and an unresolvable author
 * must fall back to the neutral em dash rather than crediting the viewer.
 */
class PinCreatorNameTest {

    private val jonathanId = "11111111-1111-4111-8111-111111111111"
    private val otherId = "22222222-2222-4222-8222-222222222222"
    private val departedId = "33333333-3333-4333-8333-333333333333"

    private val members = listOf(
        VineyardMember(userId = jonathanId, displayName = "Jonathan"),
        VineyardMember(userId = otherId, displayName = "Maria Alvarez"),
    )

    private fun pin(createdBy: String?): Pin =
        Pin(id = "pin-1", vineyardId = "v-1", createdBy = createdBy)

    @Test
    fun `pin created by the current user shows their name`() {
        val label = resolvePinCreatorName(
            pin = pin(jonathanId),
            members = members,
            currentUserId = jonathanId,
            currentUserName = "Jonathan",
        )
        assertEquals("Jonathan", label)
    }

    @Test
    fun `pin created by another member shows that member, not the viewer`() {
        val label = resolvePinCreatorName(
            pin = pin(otherId),
            members = members,
            currentUserId = jonathanId,
            currentUserName = "Jonathan",
        )
        assertEquals("Maria Alvarez", label)
    }

    @Test
    fun `older pin resolves its stored creator id against the directory`() {
        // No signed-in identity available (e.g. directory loaded before auth
        // state settles): the pin's own id still resolves the historical author.
        val label = resolvePinCreatorName(
            pin = pin(otherId),
            members = members,
            currentUserId = null,
            currentUserName = null,
        )
        assertEquals("Maria Alvarez", label)
    }

    @Test
    fun `deleted member falls back to the placeholder, never the current user`() {
        val label = resolvePinCreatorName(
            pin = pin(departedId),
            members = members,
            currentUserId = jonathanId,
            currentUserName = "Jonathan",
        )
        assertEquals("\u2014", label)
    }

    @Test
    fun `legacy row with no creator shows the placeholder`() {
        assertEquals(
            "\u2014",
            resolvePinCreatorName(pin(null), members, jonathanId, "Jonathan"),
        )
        assertEquals(
            "\u2014",
            resolvePinCreatorName(pin("   "), members, jonathanId, "Jonathan"),
        )
    }

    @Test
    fun `stored display text is shown verbatim rather than treated as an id`() {
        val label = resolvePinCreatorName(
            pin = pin("Jonathan"),
            members = emptyList(),
            currentUserId = otherId,
            currentUserName = "Maria Alvarez",
        )
        assertEquals("Jonathan", label)
    }

    @Test
    fun `member with only an email falls back through the label chain`() {
        val label = resolvePinCreatorName(
            pin = pin(otherId),
            members = listOf(VineyardMember(userId = otherId, email = "maria@example.com")),
            currentUserId = jonathanId,
            currentUserName = "Jonathan",
        )
        assertEquals("maria@example.com", label)
    }
}

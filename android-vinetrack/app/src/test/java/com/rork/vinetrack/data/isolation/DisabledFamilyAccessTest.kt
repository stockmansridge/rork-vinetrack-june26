package com.rork.vinetrack.data.isolation

import java.io.ByteArrayOutputStream
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

/** Same controlled primitive for ten distinct scopes; NOT ten actual legacy repository/caller integrations. */
@RunWith(Parameterized::class)
class DisabledFamilyAccessTest(familyName: String) {
    private val family = FieldCallerFamily.valueOf(familyName)
    @get:Rule val temporary = TemporaryFolder()
    private fun store() = AccountEvidenceStore(File(temporary.root, "accounts"), contractDisk())
    private fun access(store: AccountEvidenceStore, cap: FieldAccountCapability, vineyard: String = "shared") =
        DisabledFamilyAccess(temporary.root, contractDisk(), store, DisabledGenerationJournal(temporary.root, contractDisk(), store),
            cap, vineyard, family)

    @Test fun controlledReadWriteEmissionAndTestExportRevokeImmediatelyWithoutDeletingOriginals() {
        val store = store()
        val a = store.authenticateVerifiedAccount("A", setOf("shared"))
        val scoped = access(store, a)
        val ticket = scoped.begin("${family.name.replace('_', '-')}-operation")
        scoped.publish(ticket, "exact-1.234567890123".toByteArray())
        store.revoke()
        contractDenied { scoped.read() }
        contractDenied { scoped.begin("late") }
        contractDenied { scoped.publish(ticket, "late".toByteArray()) }
        contractDenied { scoped.deliver { fail("stale emission") } }
        val output = ByteArrayOutputStream()
        contractDenied { scoped.copyToTestSink(ticket.id, output) }
        contractDenied { scoped.acknowledge(ticket.id) }
        assertEquals(0, output.size())
        val back = store.authenticateVerifiedAccount("A", setOf("shared"))
        assertEquals("exact-1.234567890123", access(store, back).read().single().bytes.toString(Charsets.UTF_8))
    }

    @Test fun sharedVineyardBAndDifferentVineyardCannotReadOrAcknowledgeA() {
        val store = store()
        val a = store.authenticateVerifiedAccount("A", setOf("shared"))
        val scoped = access(store, a)
        val ticket = scoped.begin("A-operation")
        scoped.publish(ticket, "A-bytes".toByteArray())
        val b = store.authenticateVerifiedAccount("B", setOf("shared", "other"))
        assertTrue(access(store, b).read().isEmpty())
        assertFalse(access(store, b).acknowledge(ticket.id))
        assertTrue(access(store, b, "other").read().isEmpty())
        contractDenied { scoped.read() }
        val newA = store.authenticateVerifiedAccount("A", setOf("other"))
        contractDenied { access(store, newA).read() }
        val returned = store.authenticateVerifiedAccount("A", setOf("shared"))
        assertEquals("A", access(store, returned).read().single().account)
    }

    @Test fun delayedCallbackAndInterruptedAdmissionRequireExactOriginalActorAndFreshTicket() {
        val store = store()
        val a = store.authenticateVerifiedAccount("A", setOf("shared"))
        val old = access(store, a)
        val ticket = old.begin("operation")
        val b = store.authenticateVerifiedAccount("B", setOf("shared"))
        contractDenied { access(store, b).resume(ticket.id) }
        contractDenied { old.publish(ticket, "late".toByteArray()) }
        val newA = store.authenticateVerifiedAccount("A", setOf("shared"))
        val resumed = access(store, newA)
        contractDenied { resumed.read() }
        val renewed = resumed.resume(ticket.id)
        contractDenied { resumed.publish(ticket, "obsolete session".toByteArray()) }
        resumed.publish(renewed, "exact preserved result".toByteArray())
        resumed.publish(renewed, "exact preserved result".toByteArray())
        assertEquals(1, resumed.read().size)
        contractDenied { resumed.publish(renewed, "conflicting retry".toByteArray()) }
        assertEquals("exact preserved result", resumed.read().single().bytes.toString(Charsets.UTF_8))
        assertEquals(ticket.ordinal, renewed.ordinal)
    }

    @Test fun controlledReceiptAndStreamingRetainExactBytesAndFamilySeparation() {
        val store = store()
        val a = store.authenticateVerifiedAccount("A", setOf("shared"))
        val scoped = access(store, a)
        val ticket = scoped.begin("operation")
        val bytes = ByteArray(4097) { (it % 251).toByte() }
        scoped.publish(ticket, bytes)
        val output = ByteArrayOutputStream()
        assertTrue(scoped.copyToTestSink(ticket.id, output))
        assertArrayEquals(bytes, output.toByteArray())
        assertTrue(scoped.acknowledge(ticket.id))
        assertTrue(scoped.acknowledge(ticket.id))
        assertArrayEquals(bytes, scoped.read().single().bytes)
        var emissions = 0
        scoped.deliver { rows -> assertEquals(1, rows.size); emissions++ }
        assertEquals(1, emissions)
        val other = FieldCallerFamily.entries.first { it != family }
        val otherScope = DisabledFamilyAccess(temporary.root, contractDisk(), store,
            DisabledGenerationJournal(temporary.root, contractDisk(), store), a, "shared", other)
        assertTrue(otherScope.read().isEmpty())
    }

    companion object {
        @JvmStatic @Parameterized.Parameters(name = "{0}")
        fun families(): List<Array<Any>> = FieldCallerFamily.entries.map { arrayOf<Any>(it.name) }
    }
}

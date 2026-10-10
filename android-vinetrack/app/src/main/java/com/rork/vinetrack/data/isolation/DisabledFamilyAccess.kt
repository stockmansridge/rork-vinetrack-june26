package com.rork.vinetrack.data.isolation

import java.io.File
import java.io.OutputStream
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
private data class ControlledOutcome(val ticket: FieldAdmissionTicket, val revision: String, val sha256: String)

/** Explicit NEW-work controlled façade. No legacy files, live repositories, network replay or provider grants are accepted. */
internal class DisabledFamilyAccess(
    private val workspace: File,
    private val disk: IsolationDisk,
    private val accounts: AccountEvidenceStore,
    private val journal: DisabledGenerationJournal,
    private val capability: FieldAccountCapability,
    private val vineyard: String,
    private val family: FieldCallerFamily,
) {
    private val collection = "controlled-${family.name}"
    private val json = Json { encodeDefaults = true }

    /** Fix identity before starting any asynchronous acquisition. The caller must retain this exact ticket. */
    fun begin(operationId: String): FieldAdmissionTicket = journal.admit(capability, vineyard, family, operationId)

    fun resume(operationId: String): FieldAdmissionTicket = journal.recoverAdmission(capability, vineyard, operationId, family).also {
        check(it.family == family.name)
    }

    /** Bytes are NEW controlled inputs, never an ownership import. Failed publication retains the admission and exact intent. */
    fun publish(ticket: FieldAdmissionTicket, bytes: ByteArray) {
        check(ticket.vineyard == vineyard && ticket.family == family.name)
        val immutable = bytes.copyOf()
        journal.publishOutcome(capability, ticket, validateRetained = {
            val retained = File(workspace, "controlled-outcomes/${ticket.id}/binding.json")
            check(retained.absoluteFile == retained.canonicalFile && retained.isFile)
            val old = json.decodeFromString<ControlledOutcome>(retained.readText())
            check(old.ticket.copy(incarnation = ticket.incarnation) == ticket && old.sha256 == IsolationDisk.digest(immutable)) {
                "Conflicting callback retry; original retained"
            }
        }) {
            accounts.appendRevision(capability, vineyard, collection, ticket.id, ticket.id, immutable)
            val directory = File(workspace, "controlled-outcomes/${ticket.id}")
            val binding = File(directory, "binding.json")
            val encoded = json.encodeToString(ControlledOutcome(ticket, ticket.id, IsolationDisk.digest(immutable)))
                .toByteArray(Charsets.UTF_8)
            // Session incarnation is runtime authority; a resumed completion retains the ORIGINAL binding, not a new owner.
            if (binding.exists()) {
                check(binding.absoluteFile == binding.canonicalFile)
                val old = json.decodeFromString<ControlledOutcome>(binding.readText())
                check(old.ticket.copy(incarnation = ticket.incarnation) == ticket && old.revision == ticket.id &&
                    old.sha256 == IsolationDisk.digest(immutable)) { "Conflicting controlled outcome" }
            } else disk.publishBytes(binding, encoded)
            disk.confirmPublished(binding)
            val manifest = File(workspace, "controlled-proofs/${ticket.id}.json")
            val digest = ClosedEvidenceSet(disk).seal(directory, manifest)
            ClosedSetProof("controlled-outcomes/${ticket.id}", "controlled-proofs/${ticket.id}.json", digest)
        }
    }

    fun read(): List<OwnedEvidence> = accounts.withAccess(capability, vineyard) {
        checkReadable()
        accounts.read(capability, vineyard, collection)
    }

    /** Controlled emission check, not a wrapper around escaped legacy StateFlow or an already-delivered value. */
    fun deliver(consumer: (List<OwnedEvidence>) -> Unit) = accounts.withAccess(capability, vineyard) { consumer(read()) }

    fun acknowledge(revision: String): Boolean = accounts.withAccess(capability, vineyard) {
        checkReadable()
        accounts.acknowledge(capability, vineyard, collection, revision)
    }

    private fun checkReadable() {
        journal.status()
        check(journal.pending(capability, vineyard).none { it.family == family.name }) {
            "Unfinished controlled admission; hold rather than an empty queue"
        }
        val expected = journal.completedTickets(capability, vineyard, family).map { it.id }.toSet()
        val actual = accounts.metadata(capability, vineyard, collection)
        check(actual.map { it.revision }.toSet() == expected && actual.all { it.recordId == it.revision }) {
            "Incomplete revision set; never an empty queue"
        }
    }

    /** Streaming into a caller-owned test sink. This is NOT a public export or revocable FileProvider grant. */
    fun copyToTestSink(revision: String, sink: OutputStream): Boolean = accounts.withAccess(capability, vineyard) {
        checkReadable()
        accounts.copyBinary(capability, vineyard, collection, revision, sink)
    }
}

/** Closed manifest plus independent digest is mandatory at restored entry. Missing EVERYTHING is HOLD, not a fresh installation. */
internal class DisabledRestoreBoundary(
    private val evidenceRoot: File,
    private val manifest: File,
    private val retainedDigest: String,
    private val disk: IsolationDisk,
    private val accounts: AccountEvidenceStore,
) {
    fun openFreshlyVerifiedOriginalAccount(account: String, vineyards: Set<String>): FieldAccountCapability {
        accounts.revoke()
        ClosedEvidenceSet(disk).verify(evidenceRoot, manifest, retainedDigest)
        return accounts.authenticateVerifiedAccount(account, vineyards)
    }
}

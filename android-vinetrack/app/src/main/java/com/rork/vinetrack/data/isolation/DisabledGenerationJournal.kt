package com.rork.vinetrack.data.isolation

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Exactly the ten reviewed families. Enrollment is controlled-harness evidence, never live caller coverage. */
internal enum class FieldCallerFamily {
    COMPOSITION, QUEUE, PHOTOS, TRIP_TANK, CAPTURE_RECOVERY, SCOUT, MANUAL_PLANNING, AUXILIARY, CACHE_UI, EXPORT_CAPTURE
}

@Serializable
internal data class ClosedSetProof(val root: String, val manifest: String, val digest: String)

@Serializable
internal data class FieldAdmissionTicket(
    val id: String, val account: String, val vineyard: String, val incarnation: String,
    val family: String, val route: String, val ordinal: Long,
)

@Serializable
private data class GenerationEvent(
    val version: Int = 1, val sequence: Long, val predecessor: String,
    val kind: String, val id: String, val ticket: FieldAdmissionTicket? = null,
    val proof: ClosedSetProof? = null, val account: String? = null,
    val highWater: Long = 0, val coverage: List<String> = emptyList(),
)

internal data class DisabledGenerationStatus(
    val route: String, val phase: String?, val pendingAdmissions: Int, val unresolvedClaims: Int, val highWater: Long,
)

/** Append-only, cross-process-locked development journal. No live consumers, adoption, network replay or deletion. */
internal class DisabledGenerationJournal(
    private val workspace: File,
    private val disk: IsolationDisk,
    private val accounts: AccountEvidenceStore,
) {
    private val root = File(workspace, "generation-journal")
    private val json = Json { encodeDefaults = true }
    private val closed = ClosedEvidenceSet(disk)

    fun admit(capability: FieldAccountCapability, vineyard: String, family: FieldCallerFamily, id: String): FieldAdmissionTicket =
        accounts.withAccess(capability, vineyard) {
            transaction { state ->
                identifier(id)
                val existing = state.tickets[id]
                if (existing != null) {
                    check(existing.account == capability.account && existing.vineyard == vineyard &&
                        existing.incarnation == capability.incarnation && existing.family == family.name && id !in state.completed)
                    return@transaction existing
                }
                check(state.activeGeneration == null) { "Admission closed; no legacy fallback" }
                val ticket = FieldAdmissionTicket(id, capability.account, vineyard, capability.incarnation, family.name,
                    state.route, Math.addExact(state.highWater, 1))
                append(state, "ADMIT", id, ticket = ticket)
                ticket
            }
        }

    /** An interrupted admission stays unresolved. Only its proven original actor can explicitly resume it; no resend occurs. */
    fun recoverAdmission(capability: FieldAccountCapability, vineyard: String, id: String, family: FieldCallerFamily): FieldAdmissionTicket =
        accounts.withAccess(capability, vineyard) {
            transaction { state ->
                val old = checkNotNull(state.tickets[id])
                check(old.account == capability.account && old.vineyard == vineyard && old.family == family.name &&
                    id !in state.completed && old.route == state.route)
                val resumed = old.copy(incarnation = capability.incarnation)
                if (resumed != old) append(state, "RECOVER", id, ticket = resumed)
                resumed
            }
        }

    /** Requires a closed durable outcome, not an in-memory apply() readback. Duplicate completion must match the retained proof. */
    fun complete(capability: FieldAccountCapability, ticket: FieldAdmissionTicket, outcome: ClosedSetProof) =
        accounts.withAccess(capability, ticket.vineyard) {
            transaction { state ->
                checkTicket(state, capability, ticket)
                verify(outcome)
                val previous = state.completed[ticket.id]
                if (previous != null) check(previous == outcome) else append(state, "COMPLETE", ticket.id, proof = outcome)
            }
        }

    /** Holds the device journal lease through the controlled effect and durable completion. Failure leaves the admission unresolved. */
    fun publishOutcome(capability: FieldAccountCapability, ticket: FieldAdmissionTicket,
                       validateRetained: (ClosedSetProof) -> Unit, publish: () -> ClosedSetProof) =
        accounts.withAccess(capability, ticket.vineyard) {
            transaction { state ->
                checkTicket(state, capability, ticket)
                val retained = state.completed[ticket.id]
                if (retained != null) validateRetained(retained) else {
                    val outcome = publish()
                    verify(outcome)
                    append(state, "COMPLETE", ticket.id, proof = outcome)
                }
            }
        }

    fun pending(capability: FieldAccountCapability, vineyard: String): List<FieldAdmissionTicket> =
        accounts.withAccess(capability, vineyard) {
            transaction { state -> state.tickets.values.filter {
                it.account == capability.account && it.vineyard == vineyard && it.id !in state.completed
            } }
        }

    fun completedTickets(capability: FieldAccountCapability, vineyard: String, family: FieldCallerFamily): List<FieldAdmissionTicket> =
        accounts.withAccess(capability, vineyard) {
            transaction { state -> state.tickets.values.filter {
                it.account == capability.account && it.vineyard == vineyard && it.family == family.name && it.id in state.completed
            } }
        }

    /** Non-content exclusion claim. Unknown/corrupt legacy claims must be enrolled as unresolved, never decoded as vacant. */
    fun claim(capability: FieldAccountCapability, vineyard: String, id: String) = accounts.withAccess(capability, vineyard) {
        transaction { state ->
            identifier(id)
            check(state.activeGeneration == null) { "Admission closed" }
            val owner = json.encodeToString(listOf(capability.account, vineyard))
            val previous = state.claims[id]
            if (previous != null) check(previous == owner) else append(state, "CLAIM", id, account = owner)
        }
    }

    /** An unreadable/authorless legacy claim is exclusion only. No login or consent can resolve it through this API. */
    fun holdUnattributedClaim(id: String) = transaction { state ->
        identifier(id)
        check(state.activeGeneration == null)
        val previous = state.claims[id]
        if (previous != null) check(previous == "UNKNOWN_LOCKED") else append(state, "CLAIM", id, account = "UNKNOWN_LOCKED")
    }

    fun resolveClaim(capability: FieldAccountCapability, vineyard: String, id: String, outcome: ClosedSetProof) =
        accounts.withAccess(capability, vineyard) {
            transaction { state ->
                check(state.claims[id] == json.encodeToString(listOf(capability.account, vineyard)))
                verify(outcome)
                append(state, "RESOLVE", id, proof = outcome)
            }
        }

    /** Defers admitted/active work without waiting for a writer lease. Never pauses, cancels, resets or drains it. */
    fun beginGeneration(id: String, source: ClosedSetProof, enrolled: Set<FieldCallerFamily>): Boolean = disk.tryLocked(root) {
        val state = load()
        identifier(id)
        check(enrolled == FieldCallerFamily.entries.toSet()) { "Incomplete controlled enrollment" }
        if (state.activeGeneration != null) {
            check(state.activeGeneration == id && state.source == source)
            return@tryLocked true
        }
        if (state.claims.isNotEmpty() || state.tickets.keys.any { it !in state.completed }) return@tryLocked false
        check(id !in state.usedGenerations) { "Generation identity cannot be reused" }
        verify(source)
        append(state, "INTENT", id, proof = source, highWater = state.highWater, coverage = enrolled.map { it.name }.sorted())
        true
    } ?: false

    fun rawVerified(id: String, raw: ClosedSetProof) = transaction { state ->
        check(state.activeGeneration == id)
        if (state.phase != "INTENT") {
            check(state.raw == raw)
            verify(raw)
        } else {
            check(verify(checkNotNull(state.source)).entries == verify(raw).entries) { "Copy differs from original generation" }
            append(state, "RAW_VERIFIED", id, proof = raw)
        }
    }

    /** Copy-only terminal state reopens admission without publishing any routing decision. Originals remain untouched. */
    fun finishCopyOnly(id: String) = transaction { state ->
        if (id in state.copyCompleted) return@transaction
        check(state.activeGeneration == id && state.phase == "RAW_VERIFIED")
        append(state, "COPY_COMPLETE", id)
    }

    /** Test-owned synthetic namespace only; never imports the source set or establishes legacy authorship. */
    fun stageSynthetic(id: String, staged: ClosedSetProof) = transaction { state ->
        check(state.activeGeneration == id && state.phase in setOf("RAW_VERIFIED", "SCOPED_STAGED"))
        verify(staged)
        if (state.phase == "SCOPED_STAGED") check(state.staged == staged) else append(state, "SCOPED_STAGED", id, proof = staged)
    }

    fun commitSyntheticRoute(id: String) = transaction { state ->
        if (state.route == id) return@transaction
        check(state.activeGeneration == id && state.phase == "SCOPED_STAGED")
        append(state, "ROUTE_COMMITTED", id)
    }

    /** A restored journal must be inside a separately anchored closed set before this diagnostic is trusted. */
    fun status(): DisabledGenerationStatus = transaction { state ->
        DisabledGenerationStatus(state.route, state.phase, state.tickets.keys.count { it !in state.completed }, state.claims.size, state.highWater)
    }

    private fun checkTicket(state: State, capability: FieldAccountCapability, ticket: FieldAdmissionTicket) {
        check(state.tickets[ticket.id] == ticket && ticket.account == capability.account &&
            ticket.incarnation == capability.incarnation && ticket.route == state.route) { "Obsolete admission cannot publish or acknowledge" }
    }

    private fun <T> transaction(action: (State) -> T): T = disk.locked(root) { action(load()) }

    private fun append(state: State, kind: String, id: String, ticket: FieldAdmissionTicket? = null,
                       proof: ClosedSetProof? = null, account: String? = null, highWater: Long = 0,
                       coverage: List<String> = emptyList()) {
        val event = GenerationEvent(sequence = state.sequence + 1, predecessor = state.digest, kind = kind, id = id,
            ticket = ticket, proof = proof, account = account, highWater = highWater, coverage = coverage)
        val file = File(root, "%020d.event".format(event.sequence))
        disk.publishBytes(file, json.encodeToString(event).toByteArray(Charsets.UTF_8))
        disk.confirmPublished(file)
    }

    private fun load(): State {
        val state = State()
        val files = checkNotNull(root.listFiles()).filter { it.name != "storage.lock" && !it.name.endsWith(".partial") }.sortedBy { it.name }
        files.forEach { file ->
            check(file.absoluteFile == file.canonicalFile && file.isFile && file.extension == "event")
            val event = json.decodeFromString<GenerationEvent>(file.readText())
            check(event.version == 1 && event.sequence == state.sequence + 1 && event.predecessor == state.digest &&
                file.name == "%020d.event".format(event.sequence)) { "Incomplete or corrupt routing journal" }
            apply(state, event)
            disk.confirmPublished(file)
            state.sequence = event.sequence
            state.digest = IsolationDisk.digest(file)
        }
        // Completed generations validate historical copies, not ever-changing original legacy sources.
        state.retainedProofs.forEach { verify(it) }
        if (state.phase == "INTENT") verify(checkNotNull(state.source))
        return state
    }

    private fun apply(s: State, e: GenerationEvent) {
        identifier(e.id)
        when (e.kind) {
            "ADMIT" -> {
                val t = checkNotNull(e.ticket)
                check(s.activeGeneration == null && t.id == e.id && t.id !in s.tickets && t.route == s.route && t.ordinal == s.highWater + 1)
                check(t.account.isNotBlank() && t.vineyard.isNotBlank() && t.incarnation.isNotBlank())
                FieldCallerFamily.valueOf(t.family)
                s.tickets[t.id] = t
                s.highWater = t.ordinal
            }
            "RECOVER" -> {
                val t = checkNotNull(e.ticket)
                val old = checkNotNull(s.tickets[e.id])
                check(e.id !in s.completed && old.copy(incarnation = t.incarnation) == t && t.route == s.route)
                s.tickets[e.id] = t
            }
            "COMPLETE" -> {
                check(e.id in s.tickets && e.id !in s.completed)
                s.completed[e.id] = checkNotNull(e.proof)
                s.retainedProofs += e.proof
            }
            "CLAIM" -> { check(s.activeGeneration == null && e.id !in s.claims); s.claims[e.id] = checkNotNull(e.account) }
            "RESOLVE" -> { check(s.claims.remove(e.id) != null); s.retainedProofs += checkNotNull(e.proof) }
            "INTENT" -> {
                check(s.activeGeneration == null && s.claims.isEmpty() && s.tickets.keys.all { it in s.completed } &&
                    e.highWater == s.highWater && e.coverage == FieldCallerFamily.entries.map { it.name }.sorted() && s.usedGenerations.add(e.id))
                s.activeGeneration = e.id; s.phase = "INTENT"; s.source = checkNotNull(e.proof); s.raw = null; s.staged = null
            }
            "RAW_VERIFIED" -> {
                check(s.activeGeneration == e.id && s.phase == "INTENT")
                s.raw = checkNotNull(e.proof); s.retainedProofs += e.proof; s.phase = "RAW_VERIFIED"
            }
            "SCOPED_STAGED" -> {
                check(s.activeGeneration == e.id && s.phase == "RAW_VERIFIED")
                s.staged = checkNotNull(e.proof); s.retainedProofs += e.proof; s.phase = "SCOPED_STAGED"
            }
            "COPY_COMPLETE" -> {
                check(s.activeGeneration == e.id && s.phase == "RAW_VERIFIED")
                s.copyCompleted += e.id; s.activeGeneration = null; s.phase = null
            }
            "ROUTE_COMMITTED" -> {
                check(s.activeGeneration == e.id && s.phase == "SCOPED_STAGED")
                s.route = e.id; s.activeGeneration = null; s.phase = null
            }
            else -> error("Unsupported journal event; retain evidence")
        }
    }

    private fun verify(proof: ClosedSetProof): ClosedEvidenceManifest = closed.verify(path(proof.root), path(proof.manifest), proof.digest)

    private fun path(relative: String): File {
        check(relative.isNotBlank() && !relative.startsWith('/') && relative.split('/').none { it in setOf("", ".", "..") })
        val result = File(workspace, relative)
        check(workspace.absoluteFile == workspace.canonicalFile && result.absoluteFile == result.canonicalFile &&
            result.toPath().startsWith(workspace.toPath()) && !result.toPath().startsWith(root.toPath()))
        return result
    }

    private fun identifier(id: String) { check(id.matches(Regex("[a-zA-Z0-9-]{1,80}"))) }

    private class State {
        var sequence: Long = 0
        var digest: String = "ROOT"
        var route: String = "LEGACY_LOCKED"
        var highWater: Long = 0
        var activeGeneration: String? = null
        var phase: String? = null
        var source: ClosedSetProof? = null
        var raw: ClosedSetProof? = null
        var staged: ClosedSetProof? = null
        val tickets = linkedMapOf<String, FieldAdmissionTicket>()
        val completed = mutableMapOf<String, ClosedSetProof>()
        val claims = mutableMapOf<String, String>()
        val retainedProofs = mutableSetOf<ClosedSetProof>()
        val usedGenerations = mutableSetOf<String>()
        val copyCompleted = mutableSetOf<String>()
    }
}

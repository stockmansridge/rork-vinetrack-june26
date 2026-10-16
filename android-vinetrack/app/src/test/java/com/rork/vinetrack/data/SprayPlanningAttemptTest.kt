package com.rork.vinetrack.data

import com.rork.vinetrack.data.spray.*
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Request
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Snapshot
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Receipt
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Scope
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Kind
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Phase
import com.rork.vinetrack.data.spray.SprayPlanningProtocol.Result
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Local protocol/production reducer tests. Child-JVM halt is NOT Android application process death. */
class SprayPlanningAttemptTest {
    private val scope = fixtureScope()
    private val json = Json { encodeDefaults = true; explicitNulls = true }
    private val digest = "a".repeat(64)
    private class Memory : SprayPlanningAttemptJournal.Storage {
        var bytes: String? = null; var fail = false
        override fun read() = bytes
        override fun commit(value: String): Boolean { if (fail) return false; bytes = value; return true }
    }
    private fun journal(storage: SprayPlanningAttemptJournal.Storage = Memory()) = SprayPlanningAttemptJournal(storage, scope)
    private fun request(configuration: SprayPassConfiguration = SprayPassConfiguration.STANDARD_PASS,
        method: SprayPlanningMethod = SprayPlanningMethod.BY_AREA,
        specification: SprayFullTankSpecification = SprayFullTankSpecification.TARGET_AREA,
        kind: Kind = Kind.SAVE): Request = fixtureRequest(scope, configuration, method, specification, kind)
    private fun receipt(r: Request, phase: Phase? = null): Receipt {
        val s = r.snapshot
        return Receipt(SprayPlanningProtocol.CONTRACT, 1, r.operationId, r.actorId, r.vineyardId, r, SprayPlanningProtocol.DIGEST,
            digest, digest, 1, "2026-10-15T10:00:00Z", Result(s.recordId, s.tripId, s.recipeRevisionId, s.routeRevisionId,
                s.tankSessionId, s.actualUseId, phase ?: when (r.kind) { Kind.START, Kind.TANK -> Phase.ACTIVE; Kind.BIND -> Phase.BOUND; else -> Phase.SAVED_UNBOUND }, s, buildJsonObject {}))
    }
    private fun capability(r: Request): String = json.encodeToString(SprayPlanningProtocol.Capability(SprayPlanningProtocol.CONTRACT, 1,
        r.vineyardId, true, "synthetic", "synthetic", SprayPlanningProtocol.DIGEST, Kind.entries.toList(), 1, 1))
    private fun transport(handler: (String, String) -> SprayPlanningTransport.Response) = object : SprayPlanningTransport {
        override suspend fun call(rpc: String, body: String) = handler(rpc, body)
    }
    private fun fails(block: () -> Unit) { try { block(); fail("Expected rejection") } catch (_: SprayPlanningProtocol.Failure) { } }
    @Test fun sixVariantsAcrossFiveOperationsRetainCF2AndOriginalEvidence() {
        SprayPassConfiguration.entries.forEach { c -> repeat(3) { variant -> Kind.entries.forEach { kind ->
            val r = request(c, if (variant == 0) SprayPlanningMethod.BY_AREA else SprayPlanningMethod.FULL_TANK,
                if (variant == 2) SprayFullTankSpecification.CALIBRATED_RATE else SprayFullTankSpecification.TARGET_AREA, kind)
            SprayPlanningProtocol.validate(r); SprayPlanningProtocol.verify(receipt(r), r)
            assertEquals(2.0, r.snapshot.frozenOutputs["concentrationFactor"]!!.jsonPrimitive.double, 0.0)
            assertEquals(r, json.decodeFromString<Request>(json.encodeToString(r)))
        } } }
    }
    @Test fun unknownRequestRestoresOriginalIDsAndPayload() {
        val storage = Memory(); val r = request(); var j = journal(storage)
        j.prepare(r, scope); j.markSent(r.operationId, scope); j = journal(storage)
        assertEquals(r, j.pending(scope).single().request)
        assertEquals(SprayPlanningAttemptJournal.Stage.OUTCOME_UNKNOWN, j.pending(scope).single().stage)
        assertEquals(r, j.prepare(r, scope).request)
    }
    @Test fun failedDurabilityPreventsTransmission() = runBlocking {
        val storage = Memory().apply { fail = true }; val j = journal(storage)
        try { SprayPlanningClient(j, transport { _, _ -> error("HTTP before durability") }) { scope }.send(request()); fail() }
        catch (e: SprayPlanningProtocol.Failure) { assertEquals(SprayPlanningProtocol.Code.STORAGE, e.code) }
        assertTrue(j.load().attempts.isEmpty())
    }
    @Test fun receiptMustBeDurableBeforeRepairAndSuccess() {
        val j = journal(); val r = request(); j.prepare(r, scope); j.accept(receipt(r), scope)
        fails { j.repair(r.operationId, scope) { false } }
        assertEquals(SprayPlanningAttemptJournal.Stage.RECEIPT_VERIFIED, j.load().attempts.single().stage)
        var count = 0; repeat(2) { j.repair(r.operationId, scope) { count++; true } }
        assertEquals(1, count); assertTrue(j.pending(scope).isEmpty())
    }
    @Test fun changedRequestUnderSameUUIDRejected() {
        val j = journal(); val r = request(); j.prepare(r, scope)
        fails { j.prepare(r.copy(kind = Kind.REPLACE), scope) }
        assertEquals(r, j.load().attempts.single().request)
    }
    @Test fun switchedVineyardQuarantinesEvidence() {
        val j = journal(); val r = request(); j.prepare(r, scope)
        fails { j.pending(scope.copy(vineyardId = UUID.randomUUID().toString())) }
        assertEquals(r, j.load().attempts.single().request)
        assertEquals(SprayPlanningAttemptJournal.Stage.QUARANTINED, j.load().attempts.single().stage)
        fails { j.accept(receipt(r), scope) }
    }
    @Test fun switchedIncarnationQuarantinesEvidence() {
        val j = journal(); val r = request(); j.prepare(r, scope)
        fails { j.pending(scope.copy(incarnation = UUID.randomUUID().toString())) }
        assertEquals(SprayPlanningAttemptJournal.Stage.QUARANTINED, j.load().attempts.single().stage)
    }
    @Test fun delayedAcknowledgementCannotClearNewerRevision() {
        val j = journal(); val r = request(); j.prepare(r, scope); j.accept(receipt(r), scope); j.repair(r.operationId, scope) { true }
        val next = request(kind = Kind.REPLACE); j.prepare(next, scope)
        j.accept(receipt(r), scope)
        assertEquals(listOf(next), j.pending(scope).map { it.request })
    }
    @Test fun unboundSaveCannotClaimReady() {
        val r = request(); fails { SprayPlanningProtocol.verify(receipt(r, Phase.READY), r) }
        SprayPlanningProtocol.verify(receipt(r), r)
    }
    @Test fun wrongReceiptIdentityIsHeld() = runBlocking {
        val r = request()
        val raw = json.encodeToJsonElement(receipt(r)).jsonObject
        val echoed = raw["request"]!!.jsonObject
        val missingNull = JsonObject(raw + ("request" to JsonObject(echoed + ("snapshot" to JsonObject(echoed["snapshot"]!!.jsonObject - "tripId")))))
        listOf(json.encodeToString(receipt(request())), missingNull.toString()).forEach { response ->
            val j = journal()
            val t = transport { rpc, _ -> SprayPlanningTransport.Response(200, if (rpc == "get_spray_planning_capability_v1") capability(r) else response) }
            try { SprayPlanningClient(j, t) { scope }.send(r); fail() } catch (_: SprayPlanningProtocol.Failure) { }
            assertEquals(SprayPlanningAttemptJournal.Stage.HELD, j.load().attempts.single().stage)
        }
    }
    @Test fun conflict409NeverMeansSuccess() = runBlocking {
        val j = journal(); val r = request()
        val t = transport { rpc, _ -> if (rpc == "get_spray_planning_capability_v1") SprayPlanningTransport.Response(200, capability(r)) else SprayPlanningTransport.Response(409, "existing record") }
        try { SprayPlanningClient(j, t) { scope }.send(r); fail() } catch (_: SprayPlanningProtocol.Failure) { }
        assertNull(j.load().attempts.single().receipt); assertEquals(SprayPlanningAttemptJournal.Stage.HELD, j.load().attempts.single().stage)
    }
    @Test fun unavailableCapabilityPreservesIntentWithoutWriteRPC() = runBlocking {
        val j = journal(); val calls = mutableListOf<String>()
        val t = transport { rpc, _ -> calls += rpc; SprayPlanningTransport.Response(404, "") }
        try { SprayPlanningClient(j, t) { scope }.send(request()); fail() } catch (_: SprayPlanningProtocol.Failure) { }
        assertEquals(listOf("get_spray_planning_capability_v1"), calls)
        assertEquals(SprayPlanningAttemptJournal.Stage.INTENT_DURABLE, j.load().attempts.single().stage)
    }
    @Test fun lostResponseAndLaterReceiptRecoverWithoutRepeatingEffects() = runBlocking {
        val j = journal(); val r = request()
        val t = transport { rpc, _ -> if (rpc == "get_spray_planning_capability_v1") SprayPlanningTransport.Response(200, capability(r)) else throw java.io.IOException("lost response") }
        try { SprayPlanningClient(j, t) { scope }.send(r); fail() } catch (_: java.io.IOException) { }
        assertEquals(SprayPlanningAttemptJournal.Stage.OUTCOME_UNKNOWN, j.load().attempts.single().stage)
        val recovery = SprayPlanningProtocol.Recovery(SprayPlanningProtocol.CONTRACT, 1, scope.actorId, scope.vineyardId,
            listOf(receipt(r)), buildJsonObject { put("newer", true) })
        SprayPlanningClient(j, transport { _, _ -> SprayPlanningTransport.Response(200, json.encodeToString(recovery)) }) { scope }.recover()
        assertEquals(SprayPlanningAttemptJournal.Stage.RECEIPT_VERIFIED, j.load().attempts.single().stage)
        assertEquals(r, j.load().attempts.single().request)
    }
    @Test fun existingRecordWithoutReceiptIsNotAcceptance() = runBlocking {
        val j = journal(); val r = request(); j.prepare(r, scope); j.markSent(r.operationId, scope)
        val recovery = SprayPlanningProtocol.Recovery(SprayPlanningProtocol.CONTRACT, 1, scope.actorId, scope.vineyardId,
            emptyList(), buildJsonObject { put("recordId", r.snapshot.recordId) })
        SprayPlanningClient(j, transport { _, _ -> SprayPlanningTransport.Response(200, json.encodeToString(recovery)) }) { scope }.recover()
        assertEquals(SprayPlanningAttemptJournal.Stage.OUTCOME_UNKNOWN, j.load().attempts.single().stage)
    }
    @Test fun repeatedAndBlockQualifiedWholePassesNeverCreateCoverage() {
        val a = TripOccurrencePlanner.Candidate(scope.vineyardId, UUID.randomUUID().toString(), "A", 38.5, emptyList())
        val b = TripOccurrencePlanner.Candidate(scope.vineyardId, UUID.randomUUID().toString(), "B", 38.5, emptyList())
        val choices = SprayWorkAreaSelection.choices(listOf(a, a, b))
        assertEquals(3, choices.map { it.id }.distinct().size); assertEquals(listOf(1, 2, 1), choices.map { it.ordinal })
        val selected = SprayWorkAreaSelection.select(choices[1], SprayPassConfiguration.OVER_ROW)
        assertEquals(1, selected.travelPassCount); assertEquals(2.0, selected.controllerRowEquivalents, 0.0)
        assertFalse(choices[1].hasGeometry); assertNull(selected.physicalEvidence["status"])
        assertTrue(SprayWorkAreaSelection.retained(selected, choices, SprayPassConfiguration.OVER_ROW))
        assertFalse(SprayWorkAreaSelection.retained(selected, choices, SprayPassConfiguration.STANDARD_PASS))
    }
    @Test fun legacyCFIsAdvisoryButMalformedBasisStillRejects() {
        val r = request()
        val lowCF = r.snapshot.copy(frozenOutputs = JsonObject(r.snapshot.frozenOutputs + ("concentrationFactor" to JsonPrimitive(0.99))))
        val ambiguous = r.snapshot.copy(chemicalLines = JsonArray(listOf(buildJsonObject { put("quantity", 1.0); put("unit", "L") })))
        SprayPlanningProtocol.validate(r.copy(snapshot = lowCF))
        assertEquals(JsonPrimitive(0.99), lowCF.frozenOutputs["concentrationFactor"])
        fails { SprayPlanningProtocol.validate(r.copy(snapshot = ambiguous)) }
    }
    @Test fun productionSnapshotBuilderRetainsOriginalRecipeAndUnboundHasNoTrip() {
        val source = request()
        val intent = Json.decodeFromJsonElement<SprayPlanningIntent>(source.snapshot.planningInputs)
        val resolution = Json.decodeFromJsonElement<SprayPlanningResolution>(source.snapshot.frozenOutputs)
        val original = com.rork.vinetrack.data.model.SprayRecord(id = source.snapshot.recordId, vineyardId = scope.vineyardId,
            notes = "Full original payload", tanks = listOf(com.rork.vinetrack.data.model.SprayTank(UUID.randomUUID().toString(),
                waterVolume = 600.0, concentrationFactor = 2.0, chemicals = listOf(com.rork.vinetrack.data.model.SprayChemical(
                    UUID.randomUUID().toString(), name = "Original label", volumePerTank = 1.5, ratePer100L = 0.25, rateBasis = "per_100_litres")))))
            .copy(grossAreaHa = 1.0, sprayerConfiguration = "standard_pass", sprayPlanningMethod = "by_area",
                planningCalibratedLitresPerHectare = intent.calibratedLitresPerHectare,
                resolvedPlanningCarrierLitres = resolution.intendedLitres, plannedApplicationAreaHa = resolution.plannedAreaHa,
                resolvedPlanningLitresPerHectare = resolution.litresPerHectare, resolvedPlanningPhysicalRowLitresPer100m = resolution.physicalRowLitresPer100m,
                resolvedPlanningConcentrationFactor = resolution.concentrationFactor, controllerLitresPer100mTravel = resolution.controllerLitresPer100mTravel,
                effectiveWorkingWidthMetres = resolution.effectiveWorkingWidthMetres)
        val binding = SprayPlanningSnapshotBuilder.Binding(source.snapshot.recipeRevisionId, null, null, null, null, null,
            buildJsonObject {}, buildJsonObject {}, buildJsonObject {}, null, null, null)
        val r = SprayPlanningSnapshotBuilder.freeze(original, scope, Kind.SAVE, binding)
        assertEquals(original, Json.decodeFromJsonElement<com.rork.vinetrack.data.model.SprayRecord>(r.snapshot.originalRecord))
        assertNull(r.snapshot.tripId); assertNull(r.snapshot.originalTrip)
        SprayPlanningSnapshotBuilder.validateTankConfirmation(original, original)
        fails { SprayPlanningSnapshotBuilder.validateTankConfirmation(original, original.copy(notes = "newer recipe")) }
    }
    @Test fun presentationNeverCallsPendingOrUnboundReady() {
        val j = journal(); val r = request()
        assertEquals(SprayPlanningPresentation.DRAFT, SprayPlanningPresentation.state(null))
        j.prepare(r, scope); assertEquals(SprayPlanningPresentation.SAVE_REQUESTED, SprayPlanningPresentation.state(j.load().attempts.single()))
        j.accept(receipt(r), scope); assertEquals(SprayPlanningPresentation.REPAIR_REQUIRED, SprayPlanningPresentation.state(j.load().attempts.single()))
        j.repair(r.operationId, scope) { true }; assertEquals(SprayPlanningPresentation.SAVED_UNBOUND, SprayPlanningPresentation.state(j.load().attempts.single()))
    }
    @Test(timeout = 60000) fun abruptChildJVMTerminationRetainsOriginalUnknownAttempt() {
        val root = kotlin.io.path.createTempDirectory("planning-attempt-process-").toFile()
        try {
            val classpath = buildSet {
                addAll(System.getProperty("java.class.path").split(File.pathSeparator))
                var loader: ClassLoader? = javaClass.classLoader
                while (loader != null) {
                    (loader as? java.net.URLClassLoader)?.getURLs()?.filter { it.protocol == "file" }?.forEach { add(File(it.toURI()).absolutePath) }
                    loader = loader.parent
                }
            }.joinToString(File.pathSeparator)
            val child = ProcessBuilder(File(System.getProperty("java.home"), "bin/java").absolutePath, "-cp", classpath,
                "com.rork.vinetrack.data.SprayAttemptAbruptProcess", root.absolutePath)
                .redirectErrorStream(true).redirectOutput(File(root, "child.log")).start()
            if (!child.waitFor(25, TimeUnit.SECONDS)) { child.destroyForcibly(); fail("Child timed out") }
            assertEquals(File(root, "child.log").readText(), 73, child.exitValue())
            val storage = AttemptProcessDisk(File(root, "journal.json")); val j = journal(storage)
            val original = Json.decodeFromString<Request>(File(root, "original.json").readText())
            assertEquals(original, j.pending(scope).single().request)
            assertEquals(SprayPlanningAttemptJournal.Stage.OUTCOME_UNKNOWN, j.pending(scope).single().stage)
        } finally { root.deleteRecursively() }
    }
}

private fun fixtureScope() = Scope("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
private fun fixtureRequest(scope: Scope, c: SprayPassConfiguration = SprayPassConfiguration.STANDARD_PASS,
    method: SprayPlanningMethod = SprayPlanningMethod.BY_AREA, spec: SprayFullTankSpecification = SprayFullTankSpecification.TARGET_AREA,
    kind: Kind = Kind.SAVE): Request {
    val intent = SprayPlanningIntent(c, method, spec, 600.0, 1.0, 600.0,
        SprayPlanningInputProvenance("600,00", "1", "600", "L", "ha", "ha", "AU"))
    val resolved = requireNotNull(intent.resolve(1.0, 2.8, 1200.0))
    val bound = kind in listOf(Kind.BIND, Kind.START, Kind.TANK)
    val trip = if (kind in listOf(Kind.START, Kind.TANK)) "ffffffff-ffff-4fff-8fff-ffffffffffff" else null
    return Request(actorId = scope.actorId, vineyardId = scope.vineyardId, kind = kind, snapshot = Snapshot(
        "dddddddd-dddd-4ddd-8ddd-dddddddddddd", trip, "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        if (kind == Kind.SAVE) null else "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", if (kind == Kind.SAVE) null else "a".repeat(64),
        if (bound) "11111111-1111-4111-8111-111111111111" else null, if (kind == Kind.TANK) "original-text-session" else null,
        if (kind == Kind.TANK) "22222222-2222-4222-8222-222222222222" else null,
        Json.encodeToJsonElement(intent).jsonObject, Json.encodeToJsonElement(resolved).jsonObject,
        JsonArray(listOf(buildJsonObject { put("lineId", "original-line"); put("rateBasis", "per_100_litres"); put("quantity", 1.5); put("unit", "L"); put("labelPermission", "unknown") })),
        buildJsonObject { put("id", "original-equipment") }, buildJsonObject { put("frozen", true) }, if (bound) buildJsonObject { put("wholePasses", JsonArray(emptyList())) } else null,
        buildJsonObject { put("id", "dddddddd-dddd-4ddd-8ddd-dddddddddddd"); put("notes", "retain") }, trip?.let { buildJsonObject { put("id", it) } },
        if (kind == Kind.TANK) buildJsonObject { put("water", 600) } else null, buildJsonObject {}))
}
private class AttemptProcessDisk(private val file: File) : SprayPlanningAttemptJournal.Storage {
    override fun read(): String? = file.takeIf { it.exists() }?.readText()
    override fun commit(value: String): Boolean {
        val temp = File(file.parentFile, file.name + ".replacement")
        FileOutputStream(temp).use { it.write(value.toByteArray()); it.fd.sync() }
        Files.move(temp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        return true
    }
}
object SprayAttemptAbruptProcess {
    @JvmStatic fun main(args: Array<String>) {
        val root = File(args.single()); val r = fixtureRequest(fixtureScope())
        val j = SprayPlanningAttemptJournal(AttemptProcessDisk(File(root, "journal.json")), fixtureScope())
        j.prepare(r, fixtureScope()); j.markSent(r.operationId, fixtureScope())
        check(AttemptProcessDisk(File(root, "original.json")).commit(Json.encodeToString(r)))
        Runtime.getRuntime().halt(73)
    }
}

package com.rork.vinetrack.data.material

import com.rork.vinetrack.data.InMemoryPendingWriteStore
import com.rork.vinetrack.data.PendingWriteRepository
import com.rork.vinetrack.data.auth.SessionPhase
import com.rork.vinetrack.data.model.PendingEntityType
import com.rork.vinetrack.data.model.PendingOpType
import com.rork.vinetrack.data.model.PendingWriteStatus
import com.rork.vinetrack.data.model.WorkTask
import com.rork.vinetrack.data.model.WorkTaskCostingMethod
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigDecimal

/**
 * WORK TASK MATERIAL COSTS — foundation contract (sql/247).
 *
 * The Android twin of `WorkTaskMaterialCostsTests.swift`. Both suites assert
 * the SAME fixtures and the SAME stable catalogue keys, so any divergence
 * between the platforms fails a build.
 *
 * ```text
 * quantity × unitCost = materialTotal          (BigDecimal, money-safe)
 * a task with no material rows                 = $0, no row required
 * a library reprice / retirement               NEVER alters a saved task line
 * a vineyard's custom materials                are invisible to another vineyard
 * a replayed offline create                    upserts the SAME id, never a second line
 * ```
 */
class WorkTaskMaterialCostsTest {

    // -----------------------------------------------------------------
    // Shared fixtures (identical on iOS)
    // -----------------------------------------------------------------

    private val vineyardA = "00000000-0000-0000-0000-00000000aa01"
    private val vineyardB = "00000000-0000-0000-0000-00000000aa02"
    private val taskOne = "00000000-0000-0000-0000-00000000aa03"
    private val taskTwo = "00000000-0000-0000-0000-00000000aa04"

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun gripple(): MaterialCatalogueItem =
        MaterialCatalogueSeed.items.first { it.key == "material.trellis.gripple" }

    private fun pending(): PendingWriteRepository =
        PendingWriteRepository(InMemoryPendingWriteStore())

    // -----------------------------------------------------------------
    // 1. Base catalogue
    // -----------------------------------------------------------------

    @Test
    fun `base catalogue seeds the 18 expected entries including Gripple`() {
        val items = MaterialCatalogueSeed.items
        assertEquals(18, items.size)

        val gripple = items.firstOrNull { it.key == "material.trellis.gripple" }
        assertNotNull(gripple)
        assertEquals("Gripple / Wire Joiner-Tensioner", gripple!!.name)
        assertEquals(MaterialCategoryCatalog.TRELLIS, gripple.category)
        assertEquals("Each", gripple.defaultUnit)

        val expected = mapOf(
            "material.trellis.line_post" to "Each",
            "material.trellis.end_post" to "Each",
            "material.trellis.wire" to "Metre",
            "material.trellis.anchor" to "Each",
            "material.trellis.gripple" to "Each",
            "material.fastener.trellis_clip" to "Each",
            "material.fastener.vine_tie" to "Each",
            "material.fastener.zip_tie" to "Each",
            "material.netting.post_cap" to "Each",
            "material.netting.bird_netting" to "Metre",
            "material.netting.clip_repair" to "Each",
            "material.irrigation.dripline" to "Metre",
            "material.irrigation.dripper" to "Each",
            "material.irrigation.fitting" to "Each",
            "material.establishment.vine_stake" to "Each",
            "material.establishment.vine_guard" to "Each",
            "material.establishment.vine" to "Each",
            "material.other.miscellaneous" to "Each",
        )
        expected.forEach { (key, unit) ->
            val item = items.firstOrNull { it.key == key }
            assertNotNull("missing catalogue key $key", item)
            assertEquals("wrong default unit for $key", unit, item!!.defaultUnit)
        }
        // Keys are the cross-platform identity and must be unique.
        assertEquals(18, items.map { it.key }.toSet().size)
    }

    @Test
    fun `catalogue keys match the keys iOS ships and sql 247 seeds`() {
        // Duplicated verbatim in the iOS suite and in the migration's seed block.
        val shared = listOf(
            "material.trellis.line_post", "material.trellis.end_post",
            "material.trellis.wire", "material.trellis.anchor", "material.trellis.gripple",
            "material.fastener.trellis_clip", "material.fastener.vine_tie",
            "material.fastener.zip_tie",
            "material.netting.post_cap", "material.netting.bird_netting",
            "material.netting.clip_repair",
            "material.irrigation.dripline", "material.irrigation.dripper",
            "material.irrigation.fitting",
            "material.establishment.vine_stake", "material.establishment.vine_guard",
            "material.establishment.vine",
            "material.other.miscellaneous",
        )
        assertEquals(shared.sorted(), MaterialCatalogueSeed.keys.sorted())
    }

    @Test
    fun `standard units are suggestions not a closed set`() {
        assertEquals(
            listOf("Each", "Metre", "Roll", "Pack", "Box", "Bag"),
            MaterialUnitCatalog.suggested,
        )
        // A future custom unit passes through — no enum, no migration.
        assertEquals("Pallet", MaterialUnitCatalog.normalised("Pallet"))
        // A blank unit can never be written (the database rejects it).
        assertEquals("Each", MaterialUnitCatalog.normalised("   "))
        assertEquals("Each", MaterialUnitCatalog.normalised(null))
    }

    @Test
    fun `base catalogue is available offline and a synced server copy wins`() {
        val store = InMemoryWorkTaskMaterialStore()
        // Fresh offline install: the bundled catalogue is used.
        assertNull(store.loadCatalogue())
        assertEquals(18, MaterialCatalogueSeed.resolve(null, store.loadCatalogue()).size)

        val server = MaterialCatalogueSeed.items.map { it.copy(remoteId = "srv-${it.key}") }
        assertTrue(store.saveCatalogue(server))
        assertTrue(MaterialCatalogueSeed.resolve(null, store.loadCatalogue()).all { it.remoteId != null })

        // An empty read is refused rather than blanking every picker.
        assertFalse(store.saveCatalogue(emptyList()))
        assertEquals(18, MaterialCatalogueSeed.resolve(null, store.loadCatalogue()).size)
    }

    // -----------------------------------------------------------------
    // 2. Vineyard isolation
    // -----------------------------------------------------------------

    @Test
    fun `vineyard A custom materials never appear for vineyard B`() {
        val custom = VineyardMaterial(
            id = "vm-1", vineyardId = vineyardA, name = "Gripple Plus Medium",
            category = MaterialCategoryCatalog.TRELLIS, unit = "Each",
            defaultUnitCostRaw = "2.15", isCustom = true,
        )
        val store = InMemoryWorkTaskMaterialStore()
        store.saveVineyardMaterials(listOf(custom))

        val forA = store.loadVineyardMaterials().filter { it.vineyardId == vineyardA }
        val forB = store.loadVineyardMaterials().filter { it.vineyardId == vineyardB }
        assertEquals(1, forA.size)
        assertTrue(forB.isEmpty())

        val libraryB = MaterialLibrary.merged(
            catalogue = MaterialCatalogueSeed.items,
            vineyardMaterials = store.loadVineyardMaterials(),
            vineyardId = vineyardB,
        )
        assertFalse(libraryB.any { it.name == "Gripple Plus Medium" })
        assertTrue(libraryB.none { it.isCustom })
        // B still gets the full base catalogue, just with no prices.
        assertEquals(18, libraryB.size)
        assertTrue(libraryB.all { it.defaultUnitCost == null })
    }

    // -----------------------------------------------------------------
    // 3 & 4. Vineyard defaults and custom materials
    // -----------------------------------------------------------------

    @Test
    fun `a vineyard can price a system material without creating rows for the rest`() {
        val base = gripple().copy(remoteId = "base-gripple")
        val catalogue = MaterialCatalogueSeed.items.map { if (it.key == base.key) base else it }
        val override = VineyardMaterial(
            id = "vm-2", vineyardId = vineyardA,
            baseMaterialId = base.remoteId, baseMaterialKey = base.key,
            name = base.name, category = base.category, unit = base.defaultUnit,
            defaultUnitCostRaw = "1.82", isCustom = false,
        )

        val library = MaterialLibrary.merged(catalogue, listOf(override), vineyardA)
        // Still 18 selectable entries: pricing one item does NOT create 18 rows.
        assertEquals(18, library.size)

        val priced = library.first { it.baseMaterialKey == "material.trellis.gripple" }
        assertEquals("Gripple / Wire Joiner-Tensioner", priced.name)
        assertEquals(BigDecimal("1.82"), priced.defaultUnitCost)
        assertEquals("Each", priced.unit)
        assertFalse(priced.isCustom)
        assertEquals("base-gripple", priced.baseMaterialId)
        // Everything else stays unpriced rather than defaulting to zero.
        assertEquals(1, library.count { it.defaultUnitCost != null })
    }

    @Test
    fun `a vineyard can create a reusable custom material`() {
        val custom = VineyardMaterial(
            id = "vm-3", vineyardId = vineyardA, name = "2.4 m Eco Trellis Post",
            category = MaterialCategoryCatalog.TRELLIS, unit = "Each",
            defaultUnitCostRaw = "14.80", isCustom = true,
        )
        val library = MaterialLibrary.merged(MaterialCatalogueSeed.items, listOf(custom), vineyardA)
        assertEquals(19, library.size)

        val entry = library.first { it.name == "2.4 m Eco Trellis Post" }
        assertTrue(entry.isCustom)
        assertEquals(BigDecimal("14.80"), entry.defaultUnitCost)
        assertEquals("vm-3", entry.vineyardMaterialId)
        assertNull(entry.baseMaterialId)
    }

    // -----------------------------------------------------------------
    // 5 & 6. Multiple lines and decimal quantities
    // -----------------------------------------------------------------

    @Test
    fun `a task holds multiple material lines and decimal quantities cost exactly`() {
        val posts = WorkTaskMaterial(
            id = "m-1", workTaskId = taskOne, vineyardId = vineyardA,
            materialName = "Line / Trellis Post", category = MaterialCategoryCatalog.TRELLIS,
            unit = "Each", quantityRaw = "3", unitCostRaw = "12.40",
        )
        val wire = WorkTaskMaterial(
            id = "m-2", workTaskId = taskOne, vineyardId = vineyardA,
            materialName = "Trellis Wire", category = MaterialCategoryCatalog.TRELLIS,
            unit = "Metre", quantityRaw = "42.5", unitCostRaw = "0.31",
        )
        val netting = WorkTaskMaterial(
            id = "m-3", workTaskId = taskOne, vineyardId = vineyardA,
            materialName = "Bird Netting", category = MaterialCategoryCatalog.NETTING,
            unit = "Roll", quantityRaw = "0.5", unitCostRaw = "245.00",
        )

        // The worked example: 3 × $12.40 = $37.20 (not 37.199999...).
        assertEquals(BigDecimal("37.20"), posts.totalCost)
        // 42.5 m × $0.31 = $13.175 → $13.18 half-up, matching the generated column.
        assertEquals(BigDecimal("13.18"), wire.totalCost)
        // 0.5 roll × $245.00 = $122.50.
        assertEquals(BigDecimal("122.50"), netting.totalCost)

        val lines = listOf(posts, wire, netting)
        assertEquals(BigDecimal("172.88"), WorkTaskMaterialCosting.total(lines, taskOne))
        assertEquals(3, WorkTaskMaterialCosting.lines(lines, taskOne).size)

        val byCategory = WorkTaskMaterialCosting.totalByCategory(lines)
        assertEquals(BigDecimal("50.38"), byCategory[MaterialCategoryCatalog.TRELLIS])
        assertEquals(BigDecimal("122.50"), byCategory[MaterialCategoryCatalog.NETTING])
    }

    @Test
    fun `a task with no material lines costs zero without needing a row`() {
        assertEquals(BigDecimal("0.00"), WorkTaskMaterialCosting.total(emptyList(), taskOne))

        val otherTaskLine = WorkTaskMaterial(
            id = "m-9", workTaskId = taskTwo, vineyardId = vineyardA,
            materialName = "Vine Stake", unit = "Each", quantityRaw = "10", unitCostRaw = "3",
        )
        assertEquals(BigDecimal("0.00"), WorkTaskMaterialCosting.total(listOf(otherTaskLine), taskOne))
        assertTrue(WorkTaskMaterialCosting.lines(listOf(otherTaskLine), taskOne).isEmpty())
    }

    @Test
    fun `the server generated total is preferred and matches the local calculation`() {
        val withServerTotal = WorkTaskMaterial(
            id = "m-4", workTaskId = taskOne, vineyardId = vineyardA,
            materialName = "Trellis Wire", unit = "Metre",
            quantityRaw = "42.5", unitCostRaw = "0.31", totalCostRaw = "13.18",
        )
        assertEquals(BigDecimal("13.18"), withServerTotal.totalCost)

        // An offline line with no server total still costs correctly.
        val offline = withServerTotal.copy(id = "m-5", totalCostRaw = null)
        assertEquals(BigDecimal("13.18"), offline.totalCost)
    }

    // -----------------------------------------------------------------
    // 7. Historical snapshot survives a reprice
    // -----------------------------------------------------------------

    @Test
    fun `repricing the library never changes an existing work task snapshot`() {
        val store = InMemoryWorkTaskMaterialStore()
        val base = MaterialCatalogueSeed.items.first { it.key == "material.trellis.line_post" }
            .copy(remoteId = "base-post")
        val catalogue = MaterialCatalogueSeed.items.map { if (it.key == base.key) base else it }

        var libraryItem = VineyardMaterial(
            id = "vm-4", vineyardId = vineyardA,
            baseMaterialId = base.remoteId, baseMaterialKey = base.key,
            name = base.name, category = base.category, unit = base.defaultUnit,
            defaultUnitCostRaw = "12.40", isCustom = false,
        )
        store.saveVineyardMaterials(listOf(libraryItem))

        val entry = MaterialLibrary.merged(catalogue, listOf(libraryItem), vineyardA)
            .first { it.baseMaterialKey == base.key }
        // Today: 3 posts at $12.40 = $37.20.
        val line = entry.toTaskMaterial(
            id = "m-6", workTaskId = taskOne, vineyardId = vineyardA, quantity = BigDecimal("3"),
        )
        store.saveTaskMaterials(listOf(line))
        assertEquals(0, BigDecimal("12.40").compareTo(line.unitCost))
        assertEquals(BigDecimal("37.20"), line.totalCost)

        // Next season the vineyard raises its standard post price.
        libraryItem = libraryItem.copy(defaultUnitCostRaw = "14.50")
        store.saveVineyardMaterials(listOf(libraryItem))

        // The historical task is untouched.
        val history = WorkTaskMaterialCosting.lines(store.loadTaskMaterials(), taskOne)
        assertEquals(1, history.size)
        assertEquals(0, BigDecimal("12.40").compareTo(history[0].unitCost))
        assertEquals(BigDecimal("37.20"), history[0].totalCost)
        assertEquals("Line / Trellis Post", history[0].materialName)

        // A NEW line added after the change picks up the new default.
        val newEntry = MaterialLibrary.merged(catalogue, listOf(libraryItem), vineyardA)
            .first { it.baseMaterialKey == base.key }
        val newLine = newEntry.toTaskMaterial(
            id = "m-7", workTaskId = taskTwo, vineyardId = vineyardA, quantity = BigDecimal("3"),
        )
        assertEquals(0, BigDecimal("14.50").compareTo(newLine.unitCost))
    }

    @Test
    fun `a task line can override quantity unit and cost without editing the library`() {
        val base = gripple().copy(remoteId = "base-gripple")
        val catalogue = MaterialCatalogueSeed.items.map { if (it.key == base.key) base else it }
        val libraryItem = VineyardMaterial(
            id = "vm-5", vineyardId = vineyardA,
            baseMaterialId = base.remoteId, baseMaterialKey = base.key,
            name = base.name, category = base.category, unit = "Each",
            defaultUnitCostRaw = "1.82", isCustom = false,
        )
        val entry = MaterialLibrary.merged(catalogue, listOf(libraryItem), vineyardA)
            .first { it.baseMaterialKey == base.key }

        val line = entry.toTaskMaterial(
            id = "m-8", workTaskId = taskOne, vineyardId = vineyardA,
            quantity = BigDecimal("30"), unitCost = BigDecimal("2.05"), unit = "Pack",
        )
        assertEquals(BigDecimal("2.05"), line.unitCost)
        assertEquals("Pack", line.unit)
        assertEquals(BigDecimal("61.50"), line.totalCost)
        // The library defaults are unchanged.
        assertEquals(BigDecimal("1.82"), libraryItem.defaultUnitCost)
        assertEquals("Each", libraryItem.unit)
    }

    // -----------------------------------------------------------------
    // 8. Deactivation preserves history
    // -----------------------------------------------------------------

    @Test
    fun `deactivating a library material removes it from selection but not from history`() {
        val store = InMemoryWorkTaskMaterialStore()
        var custom = VineyardMaterial(
            id = "vm-6", vineyardId = vineyardA, name = "Gripple Plus Medium",
            category = MaterialCategoryCatalog.TRELLIS, unit = "Each",
            defaultUnitCostRaw = "2.15", isCustom = true,
        )
        store.saveVineyardMaterials(listOf(custom))
        store.saveTaskMaterials(
            listOf(
                WorkTaskMaterial(
                    id = "m-10", workTaskId = taskOne, vineyardId = vineyardA,
                    vineyardMaterialId = custom.id,
                    materialName = "Gripple Plus Medium", category = MaterialCategoryCatalog.TRELLIS,
                    unit = "Each", quantityRaw = "40", unitCostRaw = "2.15",
                ),
            ),
        )

        // Retire it.
        custom = custom.copy(isActive = false)
        store.saveVineyardMaterials(listOf(custom))

        // Gone from the picker…
        val library = MaterialLibrary.merged(
            MaterialCatalogueSeed.items, store.loadVineyardMaterials(), vineyardA,
        )
        assertFalse(library.any { it.name == "Gripple Plus Medium" })

        // …but the historical task is intact and still costs the same.
        val history = WorkTaskMaterialCosting.lines(store.loadTaskMaterials(), taskOne)
        assertEquals(1, history.size)
        assertEquals("Gripple Plus Medium", history[0].materialName)
        assertEquals(BigDecimal("86.00"), history[0].totalCost)
    }

    @Test
    fun `removing the library row entirely still leaves the task line readable`() {
        val store = InMemoryWorkTaskMaterialStore()
        store.saveVineyardMaterials(
            listOf(
                VineyardMaterial(
                    id = "vm-7", vineyardId = vineyardA, name = "Retired Post Type",
                    unit = "Each", defaultUnitCostRaw = "9.00", isCustom = true,
                ),
            ),
        )
        // Provenance is deliberately nullable — the database sets it null on
        // delete and the line must still read from its own snapshot.
        store.saveTaskMaterials(
            listOf(
                WorkTaskMaterial(
                    id = "m-11", workTaskId = taskOne, vineyardId = vineyardA,
                    vineyardMaterialId = null,
                    materialName = "Retired Post Type", unit = "Each",
                    quantityRaw = "5", unitCostRaw = "9.00",
                ),
            ),
        )
        store.saveVineyardMaterials(emptyList())

        val history = WorkTaskMaterialCosting.lines(store.loadTaskMaterials(), taskOne)
        assertEquals(1, history.size)
        assertEquals("Retired Post Type", history[0].materialName)
        assertEquals(BigDecimal("45.00"), history[0].totalCost)
    }

    // -----------------------------------------------------------------
    // 9 & 10. Offline durability and replay idempotency
    // -----------------------------------------------------------------

    @Test
    fun `an offline created material line survives restart and keeps its id`() {
        val store = InMemoryWorkTaskMaterialStore()
        val created = WorkTaskMaterial(
            id = "m-12", workTaskId = taskOne, vineyardId = vineyardA,
            materialName = "Dripper / Emitter", category = MaterialCategoryCatalog.IRRIGATION,
            unit = "Each", quantityRaw = "12", unitCostRaw = "0.85",
        )
        assertTrue(store.saveTaskMaterials(listOf(created)))

        // "Relaunch": a fresh read from the same durable storage.
        val afterRestart = WorkTaskMaterialCosting.lines(store.loadTaskMaterials(), taskOne)
        assertEquals(1, afterRestart.size)
        assertEquals("m-12", afterRestart[0].id)
        assertEquals(BigDecimal("10.20"), afterRestart[0].totalCost)
    }

    @Test
    fun `an offline create queues exactly one marker keyed by the line id`() {
        val pending = pending()
        val sync = WorkTaskMaterialSync(
            repo = FakeWorkTaskMaterialWriter(),
            pending = pending,
        )
        val now = "2026-09-22T00:00:00Z"
        sync.enqueueCreate(
            id = "m-13", workTaskId = taskOne, vineyardId = vineyardA,
            baseMaterialId = null, vineyardMaterialId = "vm-8",
            materialName = "Vine Guard", category = MaterialCategoryCatalog.ESTABLISHMENT,
            unit = "Each", quantity = BigDecimal("20"), unitCost = BigDecimal("1.10"),
            notes = null, clientUpdatedAt = now,
        )
        val markers = pending.list().filter {
            it.entityType == PendingEntityType.WORK_TASK_MATERIAL
        }
        assertEquals(1, markers.size)
        assertEquals(PendingOpType.CREATE, markers[0].opType)
        // Keyed by the line id so no other queue can pick it up.
        assertEquals("m-13", markers[0].clientId)

        val payload = json.decodeFromString(
            WorkTaskMaterialSync.UpsertPayload.serializer(), markers[0].payloadJson,
        )
        assertEquals(taskOne, payload.workTaskId)
        assertEquals("20", payload.quantity)
        assertEquals("1.1", payload.unitCost)
        assertEquals("Vine Guard", payload.materialName)
    }

    @Test
    fun `re-queueing the same line coalesces so replay cannot duplicate a row`() {
        val pending = pending()
        val sync = WorkTaskMaterialSync(FakeWorkTaskMaterialWriter(), pending)

        repeat(3) { attempt ->
            sync.enqueueCreate(
                id = "m-14", workTaskId = taskOne, vineyardId = vineyardA,
                baseMaterialId = null, vineyardMaterialId = null,
                materialName = "Zip Tie", category = MaterialCategoryCatalog.FASTENERS,
                unit = "Pack", quantity = BigDecimal((attempt + 1).toString()),
                unitCost = BigDecimal("8.40"), notes = null,
                clientUpdatedAt = "2026-09-22T00:0$attempt:00Z",
            )
        }
        val markers = pending.list().filter {
            it.entityType == PendingEntityType.WORK_TASK_MATERIAL && it.clientId == "m-14"
        }
        // Exactly one unresolved create, carrying the LATEST values.
        assertEquals(1, markers.size)
        val payload = json.decodeFromString(
            WorkTaskMaterialSync.UpsertPayload.serializer(), markers[0].payloadJson,
        )
        assertEquals("3", payload.quantity)
    }

    @Test
    fun `an edit before the create has synced folds into the create`() {
        val pending = pending()
        val sync = WorkTaskMaterialSync(FakeWorkTaskMaterialWriter(), pending)
        sync.enqueueCreate(
            "m-15", taskOne, vineyardA, null, null, "Vine Stake",
            MaterialCategoryCatalog.ESTABLISHMENT, "Each",
            BigDecimal("10"), BigDecimal("3.00"), null, "2026-09-22T00:00:00Z",
        )
        val folded = sync.foldCreate(
            "m-15", taskOne, vineyardA, null, null, "Vine Stake",
            MaterialCategoryCatalog.ESTABLISHMENT, "Each",
            BigDecimal("15"), BigDecimal("3.00"), null, "2026-09-22T00:05:00Z",
        )
        assertTrue(folded)

        val markers = pending.list().filter { it.clientId == "m-15" }
        // Still ONE create — never a create plus an update for a row the
        // server has never seen.
        assertEquals(1, markers.size)
        assertEquals(PendingOpType.CREATE, markers[0].opType)
        val payload = json.decodeFromString(
            WorkTaskMaterialSync.UpsertPayload.serializer(), markers[0].payloadJson,
        )
        assertEquals("15", payload.quantity)
    }

    @Test
    fun `deleting a never-synced line cancels locally instead of queueing a server delete`() {
        val pending = pending()
        val sync = WorkTaskMaterialSync(FakeWorkTaskMaterialWriter(), pending)
        sync.enqueueCreate(
            "m-16", taskOne, vineyardA, null, null, "Anchor / Stay",
            MaterialCategoryCatalog.TRELLIS, "Each",
            BigDecimal("2"), BigDecimal("18.00"), null, "2026-09-22T00:00:00Z",
        )
        assertTrue(sync.cancelLocalCreate("m-16"))
        assertTrue(pending.list().none { it.clientId == "m-16" })

        // An already-synced line is NOT cancellable — it needs a real delete.
        assertFalse(sync.cancelLocalCreate("m-17"))
        sync.enqueueDelete("m-17", taskOne)
        val deletes = pending.list().filter { it.clientId == "m-17" }
        assertEquals(1, deletes.size)
        assertEquals(PendingOpType.DELETE, deletes[0].opType)
    }

    @Test
    fun `a material write is deferred while the parent work task create is unresolved`() = kotlinx.coroutines.test.runTest {
        val pending = pending()
        // The parent task itself was created offline and has not synced.
        pending.enqueue(
            entityType = PendingEntityType.WORK_TASK,
            opType = PendingOpType.CREATE,
            payloadJson = "{}",
            clientId = taskOne,
        )
        val sync = WorkTaskMaterialSync(FakeWorkTaskMaterialWriter(), pending)
        sync.enqueueCreate(
            "m-18", taskOne, vineyardA, null, null, "Trellis Wire",
            MaterialCategoryCatalog.TRELLIS, "Metre",
            BigDecimal("100"), BigDecimal("0.31"), null, "2026-09-22T00:00:00Z",
        )

        var upserts = 0
        sync.replayAll(onUpserted = { upserts++ }, onDeleted = { _, _ -> })

        // Never POSTed against a parent the server doesn't have, and kept
        // retry-eligible rather than consumed.
        assertEquals(0, upserts)
        val marker = pending.list().first { it.clientId == "m-18" }
        assertEquals(PendingWriteStatus.FAILED, marker.status)
        assertEquals(0, marker.attemptCount)
    }

    @Test
    fun `deleting the parent work task drops its unresolved material markers`() {
        val pending = pending()
        val sync = WorkTaskMaterialSync(FakeWorkTaskMaterialWriter(), pending)
        sync.enqueueCreate(
            "m-19", taskOne, vineyardA, null, null, "Vine Tie",
            MaterialCategoryCatalog.FASTENERS, "Each",
            BigDecimal("50"), BigDecimal("0.06"), null, "2026-09-22T00:00:00Z",
        )
        sync.enqueueCreate(
            "m-20", taskTwo, vineyardA, null, null, "Post Cap",
            MaterialCategoryCatalog.NETTING, "Each",
            BigDecimal("5"), BigDecimal("0.90"), null, "2026-09-22T00:00:00Z",
        )
        sync.cleanupForWorkTask(taskOne)

        assertTrue(pending.list().none { it.clientId == "m-19" })
        // The other task's line is untouched.
        assertEquals(1, pending.list().count { it.clientId == "m-20" })
    }

    @Test
    fun `the library queue is separate from the task line queue`() {
        val pending = pending()
        val repo = FakeWorkTaskMaterialWriter()
        WorkTaskMaterialSync(repo, pending).enqueueCreate(
            "m-21", taskOne, vineyardA, null, null, "Dripline",
            MaterialCategoryCatalog.IRRIGATION, "Metre",
            BigDecimal("60"), BigDecimal("1.15"), null, "2026-09-22T00:00:00Z",
        )
        VineyardMaterialSync(repo, pending).enqueueUpsert(
            id = "vm-9", vineyardId = vineyardA, baseMaterialId = null,
            name = "Gripple Plus Medium", category = MaterialCategoryCatalog.TRELLIS,
            unit = "Each", defaultUnitCost = BigDecimal("2.15"),
            isCustom = true, isActive = true, clientUpdatedAt = "2026-09-22T00:00:00Z",
        )

        assertEquals(1, pending.list().count { it.entityType == PendingEntityType.WORK_TASK_MATERIAL })
        assertEquals(1, pending.list().count { it.entityType == PendingEntityType.VINEYARD_MATERIAL })
        // A custom library row carries NO base id (database check constraint).
        val libraryMarker = pending.list().first { it.entityType == PendingEntityType.VINEYARD_MATERIAL }
        val payload = json.decodeFromString(
            VineyardMaterialSync.UpsertPayload.serializer(), libraryMarker.payloadJson,
        )
        assertNull(payload.baseMaterialId)
        assertTrue(payload.isCustom)
    }

    // -----------------------------------------------------------------
    // 11. Cross-platform interpretation
    // -----------------------------------------------------------------

    @Test
    fun `a backend row decodes to the same values iOS reads`() {
        val raw = """
        {
          "id": "00000000-0000-0000-0000-00000000aa05",
          "work_task_id": "$taskOne",
          "vineyard_id": "$vineyardA",
          "base_material_id": null,
          "vineyard_material_id": null,
          "material_name": "Trellis Wire",
          "category": "Trellis",
          "unit": "Metre",
          "quantity": 42.5,
          "unit_cost": 0.31,
          "total_cost": 13.18,
          "notes": "",
          "deleted_at": null
        }
        """.trimIndent()
        val decoded = json.decodeFromString(WorkTaskMaterial.serializer(), raw)
        assertEquals("Trellis Wire", decoded.materialName)
        assertEquals("Metre", decoded.unit)
        assertEquals(BigDecimal("42.5"), decoded.quantity)
        assertEquals(BigDecimal("0.31"), decoded.unitCost)
        // The same total iOS computes and the same the database generates.
        assertEquals(BigDecimal("13.18"), decoded.totalCost)
    }

    // -----------------------------------------------------------------
    // 14 & 15. Work Task access
    // -----------------------------------------------------------------

    @Test
    fun `a permitted vineyard member can enter work task material costs`() {
        val access = WorkTaskMaterialCostsAccess.resolve(
            sessionPhase = SessionPhase.AuthenticatedOnline,
            selectedVineyardId = vineyardA,
            isMemberOfSelectedVineyard = true,
        )
        assertEquals(WorkTaskMaterialCostsAccess.Allowed, access)
        assertTrue(access.isAllowed)
    }

    @Test
    fun `a normal permitted work task user can use materials without system admin status`() {
        val member = WorkTaskMaterialCostsAccess.resolve(
            sessionPhase = SessionPhase.AuthenticatedOnline,
            selectedVineyardId = vineyardA,
            isMemberOfSelectedVineyard = true,
        )
        assertEquals(WorkTaskMaterialCostsAccess.Allowed, member)
        assertTrue(member.isAllowed)
    }

    @Test
    fun `the gate fails closed while restoring signed out or outside a vineyard`() {
        assertEquals(
            WorkTaskMaterialCostsAccess.Unavailable(WorkTaskMaterialCostsAccess.Reason.SessionRestoring),
            WorkTaskMaterialCostsAccess.resolve(SessionPhase.Restoring, vineyardA, true),
        )
        assertEquals(
            WorkTaskMaterialCostsAccess.Unavailable(WorkTaskMaterialCostsAccess.Reason.NotAuthenticated),
            WorkTaskMaterialCostsAccess.resolve(SessionPhase.SignedOut, vineyardA, true),
        )
        // Vineyard tenancy still applies.
        assertEquals(
            WorkTaskMaterialCostsAccess.Unavailable(WorkTaskMaterialCostsAccess.Reason.NotVineyardMember),
            WorkTaskMaterialCostsAccess.resolve(SessionPhase.AuthenticatedOnline, vineyardA, false),
        )
        assertEquals(
            WorkTaskMaterialCostsAccess.Unavailable(WorkTaskMaterialCostsAccess.Reason.NotVineyardMember),
            WorkTaskMaterialCostsAccess.resolve(SessionPhase.AuthenticatedOnline, null, true),
        )
        // Offline but authenticated still works — Material Costs is offline-first.
        assertEquals(
            WorkTaskMaterialCostsAccess.Allowed,
            WorkTaskMaterialCostsAccess.resolve(SessionPhase.AuthenticatedOffline, vineyardA, true),
        )
    }

    // -----------------------------------------------------------------
    // 16 & 17. Additive, and the gate is cleanly removable
    // -----------------------------------------------------------------

    @Test
    fun `material costs is additive - existing work task behaviour is untouched`() {
        val task = WorkTask(
            id = taskOne,
            vineyardId = vineyardA,
            taskType = "Wire Lifting",
            costingMethod = null,
        )
        // Unchanged defaults: an existing task still resolves as hourly.
        assertEquals(WorkTaskCostingMethod.HOURLY, task.resolvedCostingMethod)
        assertFalse(task.isPieceRate)
        // Materials are never mandatory: no row means no cost.
        assertEquals(BigDecimal("0.00"), WorkTaskMaterialCosting.total(emptyList(), taskOne))
    }

    @Test
    fun `removing the gate needs no change to models storage or the wire format`() {
        // The whole data layer is exercised with NO admin input anywhere: if any
        // of these required an isSystemAdmin argument, this would not compile.
        val store = InMemoryWorkTaskMaterialStore()
        val pending = pending()
        val repo = FakeWorkTaskMaterialWriter()

        val custom = VineyardMaterial(
            id = "vm-10", vineyardId = vineyardA, name = "Zip Tie 300mm",
            unit = "Pack", defaultUnitCostRaw = "8.40", isCustom = true,
        )
        store.saveVineyardMaterials(listOf(custom))
        store.saveTaskMaterials(
            listOf(
                WorkTaskMaterial(
                    id = "m-22", workTaskId = taskOne, vineyardId = vineyardA,
                    vineyardMaterialId = custom.id, materialName = "Zip Tie 300mm",
                    unit = "Pack", quantityRaw = "2", unitCostRaw = "8.40",
                ),
            ),
        )
        WorkTaskMaterialSync(repo, pending).enqueueCreate(
            "m-23", taskOne, vineyardA, null, custom.id, "Zip Tie 300mm",
            MaterialCategoryCatalog.FASTENERS, "Pack",
            BigDecimal("2"), BigDecimal("8.40"), null, "2026-09-22T00:00:00Z",
        )

        assertEquals(
            BigDecimal("16.80"),
            WorkTaskMaterialCosting.total(store.loadTaskMaterials(), taskOne),
        )
        // The queued payload carries no admin concept.
        val marker = pending.list().first { it.entityType == PendingEntityType.WORK_TASK_MATERIAL }
        assertFalse(marker.payloadJson.contains("admin", ignoreCase = true))
    }

    private class FakeWorkTaskMaterialWriter : WorkTaskMaterialWriting {
        override suspend fun upsertVineyardMaterial(
            id: String,
            vineyardId: String,
            baseMaterialId: String?,
            name: String,
            category: String,
            unit: String,
            defaultUnitCost: BigDecimal?,
            isCustom: Boolean,
            isActive: Boolean,
            clientUpdatedAt: String?,
        ): VineyardMaterial = VineyardMaterial(
            id = id,
            vineyardId = vineyardId,
            baseMaterialId = baseMaterialId,
            name = name,
            category = category,
            unit = unit,
            defaultUnitCostRaw = defaultUnitCost?.toPlainString(),
            isCustom = isCustom,
            isActive = isActive,
        )

        override suspend fun softDeleteVineyardMaterial(id: String) = Unit

        override suspend fun upsertTaskMaterial(
            id: String,
            workTaskId: String,
            vineyardId: String,
            baseMaterialId: String?,
            vineyardMaterialId: String?,
            materialName: String,
            category: String,
            unit: String,
            quantity: BigDecimal,
            unitCost: BigDecimal,
            notes: String?,
            clientUpdatedAt: String?,
        ): WorkTaskMaterial = WorkTaskMaterial(
            id = id,
            workTaskId = workTaskId,
            vineyardId = vineyardId,
            baseMaterialId = baseMaterialId,
            vineyardMaterialId = vineyardMaterialId,
            materialName = materialName,
            category = category,
            unit = unit,
            quantityRaw = quantity.toPlainString(),
            unitCostRaw = unitCost.toPlainString(),
            notes = notes.orEmpty(),
        )

        override suspend fun softDeleteTaskMaterial(id: String) = Unit
    }
}

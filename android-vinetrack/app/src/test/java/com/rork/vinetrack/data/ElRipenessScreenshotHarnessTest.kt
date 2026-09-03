package com.rork.vinetrack.data

import com.rork.vinetrack.data.ripeness.CivilDate
import com.rork.vinetrack.data.ripeness.ElRipenessGeometry
import com.rork.vinetrack.data.ripeness.ElRipenessHeatRaster
import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap
import com.rork.vinetrack.data.ripeness.ElRipenessHeatmap.LatLng
import com.rork.vinetrack.data.ripeness.ElRipenessObservationAdapter
import com.rork.vinetrack.data.ripeness.ElRipenessObservationAdapter.Origin
import com.rork.vinetrack.data.ripeness.ElRipenessObservationAdapter.SourceRecord
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Base64

/**
 * Non-shipping visual harness for the E-L Ripeness Heatmap.
 *
 * Runs the **real shipped calculation and rasteriser** ([ElRipenessHeatmap],
 * [ElRipenessHeatRaster], [ElRipenessGeometry]) against the canonical contract
 * fixture and dumps every frame — polygons, raster pixels, draw bounds, pins,
 * modes and counts — to `build/ripeness-shots/frames.json` for a compositor to
 * turn into reviewable PNGs.
 *
 * The dump exists because `java.awt` is shadowed by `android.jar` on the unit
 * test classpath, so the frames cannot be drawn in-process. Every pixel in the
 * output still comes from the production rasteriser; only the surrounding
 * chrome is drawn by the compositor.
 *
 * Scope, stated honestly: this verifies the **renderer** against the contract
 * fixture. It is not a live Google Maps screenshot — the satellite basemap and
 * Compose chrome are not exercised.
 */
class ElRipenessScreenshotHarnessTest {

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val outputDir = File("build/ripeness-shots")
    private val vineyard = "vy-fixture-south"

    private fun fixture(): JsonObject {
        val stream = javaClass.classLoader!!
            .getResourceAsStream("portal-contracts/el-ripeness-heatmap-fixture.json")
            ?: error("missing fixture")
        return json.parseToJsonElement(stream.bufferedReader().use { it.readText() }).jsonObject
    }

    private fun JsonPrimitive.orNull(): String? = if (this.toString() == "null") null else content

    private fun blocks(): List<ElRipenessHeatmap.BlockInput> =
        fixture()["blocks"]!!.jsonArray.map { element ->
            val block = element.jsonObject
            ElRipenessHeatmap.BlockInput(
                id = block["id"]!!.jsonPrimitive.content,
                name = block["name"]?.jsonPrimitive?.orNull(),
                polygon = (block["polygon_points"]?.jsonArray ?: emptyList<Any>().let { null })
                    ?.map {
                        val point = it.jsonObject
                        LatLng(
                            point["lat"]!!.jsonPrimitive.doubleOrNull!!,
                            point["lng"]!!.jsonPrimitive.doubleOrNull!!,
                        )
                    } ?: emptyList(),
            )
        }

    private fun observations(): List<ElRipenessHeatmap.Observation> {
        val sources = fixture()["observations"]!!.jsonArray.map { element ->
            val o = element.jsonObject
            SourceRecord(
                record = ElRipenessHeatmap.RawRecord(
                    id = o["id"]!!.jsonPrimitive.content,
                    vineyardId = o["vineyard_id"]?.jsonPrimitive?.orNull(),
                    paddockId = o["paddock_id"]?.jsonPrimitive?.orNull(),
                    stageCode = o["growth_stage_code"]?.jsonPrimitive?.orNull(),
                    latitude = o["latitude"]?.jsonPrimitive?.doubleOrNull,
                    longitude = o["longitude"]?.jsonPrimitive?.doubleOrNull,
                    date = o["date"]?.jsonPrimitive?.orNull(),
                    completedAt = o["completed_at"]?.jsonPrimitive?.orNull(),
                    createdAt = o["created_at"]?.jsonPrimitive?.orNull(),
                    deletedAt = o["deleted_at"]?.jsonPrimitive?.orNull(),
                ),
                origin = Origin.REMOTE,
                placementAssigned = o["placement"]?.jsonObject
                    ?.get("is_location_assigned")?.jsonPrimitive?.booleanOrNull,
            )
        }
        return ElRipenessObservationAdapter.observations(sources, vineyard)
    }

    // ---- JSON emission ----

    private fun esc(value: String): String = value.replace("\\", "\\\\").replace("\"", "\\\"")

    private fun frameJson(
        name: String,
        caption: String,
        dateIso: String,
        model: ElRipenessHeatmap.HeatModel,
        allBlocks: List<ElRipenessHeatmap.BlockInput>,
    ): String {
        val sb = StringBuilder()
        sb.append("{")
        sb.append("\"name\":\"${esc(name)}\",")
        sb.append("\"caption\":\"${esc(caption)}\",")
        sb.append("\"date\":\"${esc(dateIso)}\",")

        // Every block in the vineyard, so the compositor can frame the map the
        // same way regardless of the active filter.
        sb.append("\"extent\":[")
        sb.append(allBlocks.flatMap { it.polygon }.joinToString(",") { "[${it.lat},${it.lng}]" })
        sb.append("],")

        sb.append("\"blocks\":[")
        sb.append(model.blocks.joinToString(",") { block ->
            val raster = ElRipenessHeatRaster.raster(block)
            val bounds = ElRipenessHeatRaster.drawBounds(block)
            val parts = StringBuilder()
            parts.append("{")
            parts.append("\"id\":\"${esc(block.paddockId)}\",")
            parts.append("\"name\":\"${esc(block.paddockName ?: "Block")}\",")
            parts.append("\"mode\":\"${block.mode.wire}\",")
            parts.append("\"medianEl\":${block.medianEl?.toString() ?: "null"},")
            parts.append("\"polygon\":[")
            parts.append(block.polygon.joinToString(",") { "[${it.lat},${it.lng}]" })
            parts.append("]")
            val centroid = ElRipenessGeometry.centroid(block.polygon)
            if (centroid != null) {
                parts.append(",\"centroid\":[${centroid.lat},${centroid.lng}]")
            }
            if (raster != null && bounds != null) {
                // ARGB, row 0 = north, four bytes per pixel.
                val bytes = ByteArray(raster.pixels.size * 4)
                raster.pixels.forEachIndexed { index, pixel ->
                    bytes[index * 4] = ((pixel ushr 24) and 0xFF).toByte()
                    bytes[index * 4 + 1] = ((pixel shr 16) and 0xFF).toByte()
                    bytes[index * 4 + 2] = ((pixel shr 8) and 0xFF).toByte()
                    bytes[index * 4 + 3] = (pixel and 0xFF).toByte()
                }
                parts.append(",\"raster\":{")
                parts.append("\"w\":${raster.width},\"h\":${raster.height},")
                parts.append("\"bounds\":[${bounds.south},${bounds.west},${bounds.north},${bounds.east}],")
                parts.append("\"argb\":\"${Base64.getEncoder().encodeToString(bytes)}\"")
                parts.append("}")
            }
            parts.append("}")
            parts.toString()
        })
        sb.append("],")

        fun pins(list: List<ElRipenessHeatmap.Observation>, status: String) =
            list.joinToString(",") {
                val colour = ElRipenessHeatmap.elColour(it.el)
                "{\"lat\":${it.lat},\"lng\":${it.lng}," +
                    "\"label\":\"${esc(ElRipenessHeatmap.formatEl(it.el))}\"," +
                    "\"status\":\"$status\"," +
                    "\"rgb\":[${colour.r},${colour.g},${colour.b}]}"
            }

        val pinParts = mutableListOf<String>()
        model.blocks.forEach { block ->
            if (block.influencing.isNotEmpty()) pinParts.add(pins(block.influencing, "current"))
            if (block.stale.isNotEmpty()) pinParts.add(pins(block.stale, "stale"))
        }
        if (model.unassigned.isNotEmpty()) pinParts.add(pins(model.unassigned, "unassigned"))

        sb.append("\"pins\":[")
        sb.append(pinParts.filter { it.isNotEmpty() }.joinToString(","))
        sb.append("],")

        sb.append("\"counts\":{")
        sb.append("\"recorded\":${model.qualifying.size},")
        sb.append("\"influencing\":${model.influencing.size},")
        sb.append("\"stale\":${model.stale.size},")
        sb.append("\"unassigned\":${model.unassigned.size}")
        sb.append("},")
        sb.append("\"medianEl\":${model.medianEl?.toString() ?: "null"}")
        sb.append("}")
        return sb.toString()
    }

    private fun build(dateIso: String, filter: String? = null) =
        ElRipenessHeatmap.buildHeatModel(
            observations = observations(),
            blocks = blocks(),
            atDateIso = dateIso,
            blockFilter = filter,
        )

    @Test
    fun `dump every review frame`() {
        val allBlocks = blocks()
        val obs = observations()
        val frames = mutableListOf<String>()

        // Season progression.
        listOf(
            "2026-01-10" to "Early season — first observations",
            "2026-02-05" to "Mid season — surfaces established",
            "2026-03-01" to "Late season — ripening advanced",
        ).forEachIndexed { index, (date, caption) ->
            frames.add(
                frameJson("%02d-season".format(index + 1), caption, date, build(date), allBlocks)
            )
        }

        // Single-block filter.
        val target = allBlocks.first()
        frames.add(
            frameJson(
                "04-single-block",
                "Filtered to ${target.name}",
                "2026-02-05",
                build("2026-02-05", target.id),
                allBlocks,
            )
        )

        // Sparse modes: find the first day each appears.
        var haloDate: String? = null
        var gradientDate: String? = null
        var cursor = CivilDate(2026, 1, 1)
        repeat(150) {
            val model = ElRipenessHeatmap.buildHeatModel(obs, allBlocks, cursor.iso)
            if (haloDate == null && model.blocks.any { it.mode == ElRipenessHeatmap.Mode.HALO }) {
                haloDate = cursor.iso
            }
            if (gradientDate == null &&
                model.blocks.any { it.mode == ElRipenessHeatmap.Mode.GRADIENT }
            ) {
                gradientDate = cursor.iso
            }
            cursor = cursor.adding(1)
        }

        haloDate?.let {
            frames.add(frameJson("05-halo", "Halo — one influencing observation", it, build(it), allBlocks))
        }
        gradientDate?.let {
            frames.add(
                frameJson("06-gradient", "Gradient — two influencing observations", it, build(it), allBlocks)
            )
        }

        // Everything past the recency window: pins greyed, nothing painted.
        val staleDate = "2026-09-01"
        frames.add(
            frameJson("07-stale-only", "Stale only — pins greyed, no surface", staleDate, build(staleDate), allBlocks)
        )

        outputDir.mkdirs()
        val file = File(outputDir, "frames.json")
        file.writeText("[" + frames.joinToString(",") + "]")
        println("RIPENESS-FRAMES ${file.absolutePath} (${frames.size} frames)")

        // The dump is only useful if the real rasteriser actually painted.
        val painted = frames.count { it.contains("\"raster\"") }
        assertTrue("expected most frames to carry a real raster, got $painted", painted >= 4)
        assertTrue("expected 7 frames", frames.size == 7)
    }
}

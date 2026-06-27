package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

/**
 * One button definition inside a [ButtonTemplate] — a name, a colour token (see
 * [com.rork.vinetrack.ui.screens.launcherColorTokens]) and, for Growth mode, a
 * flag marking it as the canonical Growth-Stage button. Mirrors the iOS
 * `ButtonTemplateEntry`.
 */
@Serializable
data class ButtonTemplateEntry(
    val name: String = "",
    val color: String = "blue",
    val isGrowthStageButton: Boolean = false,
)

/**
 * A named, reusable set of four launcher buttons that owners/managers can save
 * and apply to overwrite the live Repairs/Growth button configuration. Mirrors
 * the iOS `ButtonTemplate`. Templates are device-local (never synced) — applying
 * one writes through the shared `vineyard_button_configs` contract, which is the
 * canonical, synced source iOS/portal also read.
 */
@Serializable
data class ButtonTemplate(
    val id: String = UUID.randomUUID().toString(),
    val vineyardId: String = "",
    val name: String = "",
    val mode: String = "Repairs",
    val entries: List<ButtonTemplateEntry> = emptyList(),
) {
    val hasUniqueColors: Boolean
        get() = entries.map { it.color.lowercase() }.toSet().size == entries.size
}

/**
 * Local, per-device persistence for [ButtonTemplate]s, mirroring the iOS
 * `MigratedDataStore` on-disk button-template storage. Templates are stored as a
 * single JSON array and filtered by vineyard + mode at read time. The first time
 * a vineyard is read with no templates for a mode, the built-in defaults are
 * seeded (matching the iOS `DefaultDataSeeder`).
 */
class ButtonTemplateStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_button_templates", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private fun loadAll(): List<ButtonTemplate> {
        val raw = prefs.getString(KEY_TEMPLATES, null) ?: return emptyList()
        return try {
            json.decodeFromString<List<ButtonTemplate>>(raw)
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun saveAll(templates: List<ButtonTemplate>) {
        prefs.edit { putString(KEY_TEMPLATES, json.encodeToString(templates)) }
    }

    /**
     * Templates for [vineyardId] in [mode], seeding the built-in default the
     * first time a vineyard/mode pairing is read so the list is never empty.
     */
    fun templates(vineyardId: String, mode: String): List<ButtonTemplate> {
        val all = loadAll()
        val matching = all.filter { it.vineyardId == vineyardId && it.mode == mode }
        if (matching.isNotEmpty()) return matching
        val seeded = listOf(defaultTemplate(vineyardId, mode))
        saveAll(all + seeded)
        return seeded
    }

    fun add(template: ButtonTemplate) {
        saveAll(loadAll() + template)
    }

    fun update(template: ButtonTemplate) {
        saveAll(loadAll().map { if (it.id == template.id) template else it })
    }

    fun delete(template: ButtonTemplate) {
        saveAll(loadAll().filterNot { it.id == template.id })
    }

    companion object {
        private const val KEY_TEMPLATES = "templates_v1"

        /** iOS-parity built-in default for a mode. */
        fun defaultTemplate(vineyardId: String, mode: String): ButtonTemplate =
            if (mode == "Growth") {
                ButtonTemplate(
                    vineyardId = vineyardId,
                    name = "Default Growth",
                    mode = "Growth",
                    entries = listOf(
                        ButtonTemplateEntry("Growth Stage", "darkgreen", isGrowthStageButton = true),
                        ButtonTemplateEntry("Powdery", "gray"),
                        ButtonTemplateEntry("Downy", "yellow"),
                        ButtonTemplateEntry("Blackberries", "red"),
                    ),
                )
            } else {
                ButtonTemplate(
                    vineyardId = vineyardId,
                    name = "Default Repairs",
                    mode = "Repairs",
                    entries = listOf(
                        ButtonTemplateEntry("Irrigation", "blue"),
                        ButtonTemplateEntry("Broken Post", "brown"),
                        ButtonTemplateEntry("Vine Issue", "green"),
                        ButtonTemplateEntry("Other", "red"),
                    ),
                )
            }
    }
}

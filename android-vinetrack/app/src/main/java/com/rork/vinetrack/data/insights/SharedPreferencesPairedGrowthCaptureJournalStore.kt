package com.rork.vinetrack.data.insights

import android.content.SharedPreferences
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** Synchronous disk-backed journal; commit success is part of capture success. */
class SharedPreferencesPairedGrowthCaptureJournalStore(
    private val preferences: SharedPreferences,
) : PairedGrowthCaptureJournalStore {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    override fun load(): List<PairedGrowthCaptureJournal> {
        val encoded = preferences.getString(KEY, null) ?: return emptyList()
        return runCatching {
            json.decodeFromString(ListSerializer(PairedGrowthCaptureJournal.serializer()), encoded)
        }.getOrDefault(emptyList())
    }

    override fun save(journal: PairedGrowthCaptureJournal): Boolean {
        val all = load().filterNot { it.operationId == journal.operationId } + journal
        return write(all)
    }

    override fun remove(operationId: String): Boolean =
        write(load().filterNot { it.operationId == operationId })

    private fun write(all: List<PairedGrowthCaptureJournal>): Boolean =
        runCatching {
            preferences.edit().putString(
                KEY,
                json.encodeToString(ListSerializer(PairedGrowthCaptureJournal.serializer()), all),
            ).commit()
        }.getOrDefault(false)

    private companion object {
        const val KEY: String = "paired_growth_capture_journal_v1"
    }
}

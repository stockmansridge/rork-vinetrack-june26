package com.rork.vinetrack.data

import android.content.Context
import androidx.core.content.edit
import com.rork.vinetrack.data.model.FertiliserProduct
import com.rork.vinetrack.data.model.FertiliserRecord
import kotlinx.serialization.json.Json

/**
 * Local-first store for the Fertiliser Calculator (in development — System
 * Admin only). Backs the product library and saved calculations with
 * per-vineyard JSON blobs in SharedPreferences. Model shapes mirror the
 * planned `fertiliser_products` / `fertiliser_applications` sync tables so
 * cloud sync can be added later without a data migration.
 */
class FertiliserStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("vinetrack_fertiliser", Context.MODE_PRIVATE)

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun loadProducts(vineyardId: String): List<FertiliserProduct> {
        val raw = prefs.getString("products_$vineyardId", null) ?: return emptyList()
        return runCatching { json.decodeFromString<List<FertiliserProduct>>(raw) }
            .getOrDefault(emptyList())
            .sortedBy { it.name.lowercase() }
    }

    fun upsertProduct(vineyardId: String, product: FertiliserProduct): List<FertiliserProduct> {
        val current = loadProducts(vineyardId)
        val updated = if (current.any { it.id == product.id }) {
            current.map { if (it.id == product.id) product else it }
        } else {
            current + product
        }
        prefs.edit { putString("products_$vineyardId", json.encodeToString(updated)) }
        return updated.sortedBy { it.name.lowercase() }
    }

    fun deleteProduct(vineyardId: String, productId: String): List<FertiliserProduct> {
        val updated = loadProducts(vineyardId).filterNot { it.id == productId }
        prefs.edit { putString("products_$vineyardId", json.encodeToString(updated)) }
        return updated
    }

    fun loadRecords(vineyardId: String): List<FertiliserRecord> {
        val raw = prefs.getString("records_$vineyardId", null) ?: return emptyList()
        return runCatching { json.decodeFromString<List<FertiliserRecord>>(raw) }
            .getOrDefault(emptyList())
            .sortedByDescending { it.date }
    }

    fun saveRecords(vineyardId: String, records: List<FertiliserRecord>) {
        prefs.edit { putString("records_$vineyardId", json.encodeToString(records)) }
    }

    fun addRecord(vineyardId: String, record: FertiliserRecord): List<FertiliserRecord> {
        val updated = loadRecords(vineyardId) + record
        saveRecords(vineyardId, updated)
        return updated.sortedByDescending { it.date }
    }

    fun markCompleted(vineyardId: String, recordId: String, date: String): List<FertiliserRecord> {
        val updated = loadRecords(vineyardId).map {
            if (it.id == recordId) it.copy(status = "completed", date = date) else it
        }
        saveRecords(vineyardId, updated)
        return updated
    }

    fun deleteRecord(vineyardId: String, recordId: String): List<FertiliserRecord> {
        val updated = loadRecords(vineyardId).filterNot { it.id == recordId }
        saveRecords(vineyardId, updated)
        return updated
    }
}

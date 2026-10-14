package com.rork.vinetrack.data

import android.content.Context
import com.rork.vinetrack.data.auth.FieldStoreAccess
import com.rork.vinetrack.data.model.Trip
import com.rork.vinetrack.data.model.TripOccurrenceCoverage
import kotlinx.serialization.json.JsonObject
import java.util.UUID

/** Actual Android journal backend: synchronous SharedPreferences commit before publication. */
class TripOccurrenceNativeStore(context: Context) {
    private val preferences = context.getSharedPreferences("trip_occurrence_journals_v1", Context.MODE_PRIVATE)
    private val access = FieldStoreAccess(context)
    private val journals = mutableMapOf<TripOccurrenceJournal.Scope, TripOccurrenceJournal>()
    @Synchronized fun journal(scope: TripOccurrenceJournal.Scope): TripOccurrenceJournal {
        listOf(scope.ownerId, scope.vineyardId, scope.tripId).forEach { require(UUID.fromString(it).toString() == it) }
        return journals.getOrPut(scope) {
            val key = "${scope.ownerId}/${scope.vineyardId}/${scope.tripId}"
            TripOccurrenceJournal(object : TripOccurrenceJournal.Storage {
                override fun read(): String? = access.admittedForOwner(scope.ownerId) { preferences.getString(key, null) }
                override fun commit(value: String): Boolean = access.admittedForOwner(scope.ownerId) {
                    preferences.edit().putString(key, value).commit()
                }
            }, scope)
        }
    }
}

/** Display projections never populate legacy numeric coverage arrays. */
fun Trip.withOccurrenceProjection(coverage: JsonObject): Trip {
    val d = TripOccurrenceCoverage.requireDocument(coverage)
    val current = d.items.firstOrNull { it.id == d.targetId }
    val next = d.order.firstOrNull { it != d.targetId && d.status(it) == "incomplete" }
    return copy(occurrenceCoverage = coverage, completedPaths = emptyList(), skippedPaths = emptyList(),
        rowSequence = d.order.map { id -> d.items.single { it.id == id }.label },
        sequenceIndex = d.order.indexOf(d.raw["plannedCursorId"]?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }).takeIf { it >= 0 } ?: d.order.size,
        currentRowNumber = current?.label, nextRowNumber = d.items.firstOrNull { it.id == next }?.label)
}

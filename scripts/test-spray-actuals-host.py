#!/usr/bin/env python3
"""Run bounded production actual-entry/store/coordinator JVM regressions.

Compiles changed production Kotlin directly, with exact SprayTank/SprayChemical
and unit conversion declarations extracted from Models.kt. Android preferences,
auth adapters, the large Trip container and unrelated snapshot types are
explicit doubles. This is not a native Android build or Compose/device test.
Requires Kotlin 2.3.10, serialization 1.10.0, coroutines 1.10.2 and JUnit 4.13.2.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--kotlin-home', type=Path, required=True)
p.add_argument('--library-dir', type=Path, required=True)
a = p.parse_args()
SOURCE = ROOT / 'android-vinetrack/app/src/main/java/com/rork/vinetrack'
TEST = ROOT / 'android-vinetrack/app/src/test/java/com/rork/vinetrack/data'
STUBS = {
'Android.kt': r'''
package android.content
class SharedPreferences {
    fun getString(key: String, default: String?): String? = error("Native adapter is not executed")
    fun edit() = Editor()
    class Editor {
        fun putString(key: String, value: String): Editor = this
        fun remove(key: String): Editor = this
        fun commit(): Boolean = error("Native adapter is not executed")
    }
}
class Context {
    companion object { const val MODE_PRIVATE = 0 }
    val applicationContext: Context get() = this
    fun getSharedPreferences(name: String, mode: Int) = SharedPreferences()
}
''',
'Auth.kt': r'''
package com.rork.vinetrack.data.auth
class FieldAccessRevoked : RuntimeException()
class FieldStoreAccess(context: android.content.Context) {
    fun <T> admitted(action: () -> T): T = action()
    fun <T> admittedForOwner(owner: String, action: () -> T): T = action()
    fun <T> commitForOwner(owner: String, action: () -> T): T = action()
    fun preferences(value: android.content.SharedPreferences) = value
}
class AuthRetentionGuard {
    class AccountAccess(val userId: String, val authority: Authority = Authority())
    class Authority { fun withAccount(access: AccountAccess, current: () -> String?, action: () -> Unit): Boolean {
        if (access.userId != current()) return false
        action(); return true
    } }
}
''',
'OtherData.kt': r'''
package com.rork.vinetrack.data
import com.rork.vinetrack.data.model.Trip
object SupabaseClient { val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true; encodeDefaults = true } }
class ActiveTripStore {
    data class Snapshot(val ownerUserId: String, val vineyardId: String, val trip: Trip)
    fun load(): Snapshot? = error("Native adapter is not executed")
    fun saveDurably(owner: String, vineyard: String, trip: Trip): Boolean = error("Native adapter is not executed")
}
class PendingWriteRepository { fun list() = emptyList<com.rork.vinetrack.data.model.PendingWrite>() }
class TripTankSync { fun enqueue(trip: Trip) { error("Native adapter is not executed") } }
data class VineyardOperationalAccess(val canRead: Boolean, val canWrite: Boolean, val isTrialExpiredReadOnly: Boolean = false)
sealed class BackendError : RuntimeException() { class Server(val body: String?) : BackendError() }
''',
'TripBoundary.kt': r'''
package com.rork.vinetrack.data.model
import kotlinx.serialization.Serializable
@Serializable data class CoordinatePoint(val latitude: Double, val longitude: Double)
@Serializable data class TankSession(val id: String, val tankNumber: Int, val startTime: String,
    val endTime: String? = null, val startRow: Double? = null, val endRow: Double? = null,
    val fillStartTime: String? = null, val fillEndTime: String? = null)
@Serializable data class Trip(val id: String, val vineyardId: String, val paddockName: String? = null,
    val startTime: String? = null, val isActive: Boolean = false, val endTime: String? = null,
    val deletedAt: String? = null, val tankSessions: List<TankSession> = emptyList(),
    val activeTankNumber: Int? = null, val isFillingTank: Boolean = false, val fillingTankNumber: Int? = null,
    val pathPoints: List<CoordinatePoint>? = null, val totalDistance: Double? = null,
    val completedPaths: List<Double> = emptyList(), val startEngineHours: Double? = null,
    val endEngineHours: Double? = null, val completionNotes: String? = null)
data class PendingWrite(val clientId: String, val entityType: String, val status: String)
object PendingEntityType { const val TRIP_TANK = "trip_tank" }
object PendingWriteStatus { val unresolved = setOf("pending") }
''',
'ChemicalSnapshotBoundary.kt': r'''
package com.rork.vinetrack.data.chemical
import kotlinx.serialization.Serializable
@Serializable data class ChemicalLineSnapshot(val activityGroupCodes: List<String> = emptyList(), val hasResistanceData: Boolean = false)
''',
}
with tempfile.TemporaryDirectory(prefix='vinetrack-actuals-host-') as tmp:
    output = Path(tmp)
    for name, text in STUBS.items(): (output/name).write_text(text)
    models = (SOURCE/'data/model/Models.kt').read_text()
    frozen = models[models.index('@Serializable\ndata class SprayChemical('):models.index('/**\n * A completed spray application/compliance record')]
    units = models[models.index('fun chemicalUnitToBase('):models.index('/** Rate basis raw values matching')]
    (output/'PlannedModels.kt').write_text('package com.rork.vinetrack.data.model\nimport kotlinx.serialization.Serializable\nimport com.rork.vinetrack.data.chemical.ChemicalLineSnapshot\nimport com.rork.vinetrack.data.spray.SprayProductRateBasis\n' + frozen + units)
    rate = (SOURCE/'data/spray/SprayProductRateBasis.kt').read_text()
    (output/'RateBasis.kt').write_text(rate[:rate.index('/** The measured application')])
    production = ['data/spray/SprayStartActualAmounts.kt', 'data/spray/SprayStartRateReview.kt',
        'data/model/SprayActualInputDraft.kt', 'data/model/SprayTankActual.kt',
        'data/SprayTankActualStore.kt', 'data/StartTankCommitCoordinator.kt', 'data/VineyardWriteAuthority.kt']
    suites = ['SprayStartActualAmountsTest', 'SprayActualInputDraftStoreTest', 'StartTankCommitCoordinatorTest']
    jars = [a.library_dir/name for name in ['kotlinx-serialization-core-jvm-1.10.0.jar',
        'kotlinx-serialization-json-jvm-1.10.0.jar', 'kotlinx-coroutines-core-jvm-1.10.2.jar',
        'junit-4.13.2.jar', 'hamcrest-core-1.3.jar']]
    classpath = os.pathsep.join(map(str, jars))
    command = [str(a.kotlin_home/'bin/kotlinc'), *map(str, output.glob('*.kt')),
        *(str(SOURCE/f) for f in production), *(str(TEST/(name+'.kt')) for name in suites),
        '-cp', classpath, '-Xplugin='+str(a.kotlin_home/'lib/kotlinx-serialization-compiler-plugin.jar'),
        '-jvm-target', '17', '-include-runtime', '-d', str(output/'checks.jar')]
    subprocess.run(command, check=True)
    subprocess.run(['java', '-cp', str(output/'checks.jar')+os.pathsep+classpath,
        'org.junit.runner.JUnitCore', *('com.rork.vinetrack.data.'+name for name in suites)], check=True)

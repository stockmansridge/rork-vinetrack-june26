#!/usr/bin/env python3
"""Execute the real Android actual-cache ownership classifier on the JVM.

Requires the project's Kotlin 2.3.10 compiler, serialization compiler plugin and
serialization core/json 1.10.0 JVM jars. Android Context/files and unrelated
stores are explicit fail-closed doubles. This is NOT native Android, full auth
recovery, Compose or device validation; AuthRetentionAndroidTest covers those
production adapter journeys separately.

python3 scripts/test-spray-draft-recovery-host.py \
  --kotlin-home /tmp/vinetrack-kotlin-2.3.10/kotlinc \
  --library-dir /tmp/vinetrack-kotlin-2.3.10
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--kotlin-home", required=True, type=Path)
parser.add_argument("--library-dir", required=True, type=Path)
args = parser.parse_args()

STUBS = {
    "AndroidContext.kt": r'''
package android.content
import java.io.File
class SharedPreferences(var all: Map<String, Any?> = emptyMap())
class ApplicationInfo(val dataDir: String)
class PackageInfo(val lastUpdateTime: Long = 1)
class PackageManager { fun getPackageInfo(name: String, flags: Int) = PackageInfo() }
class Context(val root: File) {
    companion object { const val MODE_PRIVATE = 0 }
    val applicationInfo = ApplicationInfo(root.path)
    val filesDir = File(root, "files")
    val cacheDir = File(root, "cache")
    val packageName = "host.boundary"
    val packageManager = PackageManager()
    private val preferences = mutableMapOf<String, SharedPreferences>()
    fun getSharedPreferences(name: String, mode: Int) = preferences.getOrPut(name) { SharedPreferences() }
}
''',
    "AndroidOs.kt": r'''
package android.system
import java.io.FileDescriptor
class StructStat(val st_mode: Int = 0, val st_size: Long = 0, val st_nlink: Long = 0,
                 val st_dev: Long = 0, val st_ino: Long = 0, val st_mtime: Long = 0)
object Os {
    fun lstat(path: String): StructStat = error("Filesystem inspection is outside this cache-only host test")
    fun fstat(fd: FileDescriptor): StructStat = error("Filesystem inspection is outside this cache-only host test")
    fun open(path: String, flags: Int, mode: Int): FileDescriptor = error("No host file admission")
}
object OsConstants {
    const val O_RDONLY = 0; const val O_NOFOLLOW = 1; const val O_NONBLOCK = 2
    fun S_ISREG(mode: Int) = false
}
''',
    "DataBoundary.kt": r'''
package com.rork.vinetrack.data
import kotlinx.serialization.Serializable
@Serializable data class HostTrip(val id: String, val vineyardId: String)
class ActiveTripStore {
    @Serializable data class Snapshot(val ownerUserId: String, val vineyardId: String, val trip: HostTrip)
}
class RecoverySnapshotStore {
    @Serializable data class SourceStatus(val source: String, val status: String, val itemCount: Int)
    @Serializable data class Snapshot(val formatVersion: Int, val vineyardId: String,
        val pendingWrites: List<String>, val captureEvidence: List<String>, val activeTrip: String?,
        val cachedPins: List<String>, val cachedTrips: List<String>, val excludedOrUnreadable: List<String>,
        val source: String, val sourceStatuses: List<SourceStatus>)
}
''',
    "ModelBoundary.kt": r'''
package com.rork.vinetrack.data.model
data class SprayChemical(val id: String)
data class SprayTank(val tankNumber: Int, val chemicals: List<SprayChemical>)
''',
    "UnrelatedContracts.kt": r'''
package com.rork.vinetrack.data.auth
import java.io.File
data class RecoveryEvidenceDiagnostic(val store: String, val rule: String, val recordCount: Int? = null)
class EvidenceContractFailure(val diagnostic: RecoveryEvidenceDiagnostic) : RuntimeException()
private fun requireEmpty(values: Map<String, Any?>): Set<String> { check(values.isEmpty()); return emptySet() }
object RetainedEvidenceContract {
    fun queue(values: Map<String, Any?>, owner: String?) = requireEmpty(values)
    fun snapshots(values: Map<String, Any?>, owner: String?) = requireEmpty(values)
}
object RetainedPlanningContract {
    fun inspect(values: Map<String, Any?>, owner: String?) = requireEmpty(values)
}
object CleanExitCacheContract {
    val devicePreferences = emptySet<String>()
    fun validatePreferences(name: String, values: Map<String, Any?>) { requireEmpty(values) }
    fun validate(values: Map<String, Any?>) { requireEmpty(values) }
    fun recoveryScopes(values: Map<String, Any?>, original: String) = requireEmpty(values)
    fun validateSavedChemicals(values: Map<String, Any?>, pending: Map<String, Any?>) {
        requireEmpty(values); requireEmpty(pending)
    }
    fun chemicalRecoveryScopes(values: Map<String, Any?>, pending: Map<String, Any?>, original: String): Set<String> {
        requireEmpty(pending); return requireEmpty(values)
    }
}
object RecoveryLocationContract {
    fun requireLocation(ok: Boolean, rule: String) { check(ok) }
    fun present(file: File) = file.exists()
    fun directory(file: File, rule: String): List<File> = error("No populated filesystem admission in this host test")
    fun logos(file: File): Set<String> = error("No logo admission in this host test")
    fun emptyTree(file: File, rule: String) { check(!file.exists()) }
    fun retainedRule(file: File) = "HOST_OUT_OF_SCOPE"
}
object ProfileInstallerSkipContract {
    const val FILE_NAME = "profileinstaller_profileWrittenFor_lastUpdateTime.dat"; const val BYTE_COUNT = 8
    fun accepts(bytes: ByteArray, lastUpdateTime: Long): Boolean = error("No profile-marker admission in this host test")
}
object PhotoCaptureReceipt { const val PREFERENCES = "vinetrack_photo_capture_receipts" }
''',
    "Probe.kt": r'''
package com.rork.vinetrack.data.auth
import android.content.Context
import com.rork.vinetrack.data.model.SprayActualInputDraft
import com.rork.vinetrack.data.model.SprayTankActual
import kotlinx.serialization.json.Json
import java.io.File

fun main(args: Array<String>) {
    val owner = "11111111-1111-4111-8111-111111111111"
    val other = "22222222-2222-4222-8222-222222222222"
    val codec = Json { encodeDefaults = true }
    var passed = 0
    fun scenario(name: String, action: () -> Unit) {
        action(); passed++; println("PASS $name")
    }
    val context = Context(File(args.single(), "unpopulated"))
    val prefs = context.getSharedPreferences("vinetrack_spray_tank_actuals", 0)
    fun inspect(bytes: String, actor: String? = owner, clean: Boolean = false): Set<String>? {
        prefs.all = mapOf("cache" to bytes)
        val inspector = AccountTransitionEvidence(context)
        val result = if (clean) inspector.inspectCleanExit() else inspector.inspect(actor)
        check(prefs.all == mapOf("cache" to bytes)) { "Inspection modified retained cache bytes" }
        return result?.vineyards
    }
    val draft = SprayActualInputDraft("review:" + "a".repeat(64), owner, "vineyard",
        mapOf("water" to "", "chemical" to "0.63"))
    fun cache(vararg drafts: SprayActualInputDraft): String {
        val entries = drafts.joinToString(",") { codec.encodeToString(SprayActualInputDraft.serializer(), it) }
        return """{"records":[],"pendingIds":[],"inputDrafts":[$entries]}"""
    }
    val actual = SprayTankActual("actual", "vineyard", "spray", "trip", "session", 1,
        waterVolumeL = 123.0, chemicals = emptyList(), confirmedAt = "2026-11-01T00:00:00Z", confirmedBy = owner)
    fun oldCache(record: SprayTankActual = actual, pending: String = "actual"): String {
        val encoded = codec.encodeToString(SprayTankActual.serializer(), record)
        return """{"records":[$encoded],"pendingIds":["$pending"]}"""
    }
    scenario("legacy empty cache and omitted defaults remain admitted") {
        for (bytes in listOf("{}", """{"records":[],"pendingIds":[]}""", cache())) {
            check(inspect(bytes, clean = true) == emptySet<String>())
            check(inspect(bytes, actor = null) == emptySet<String>())
        }
    }
    scenario("legacy confirmed actuals require their exact original owner") {
        check(inspect(oldCache()) == setOf("vineyard"))
        check(inspect(oldCache(), other) == null)
        check(inspect(oldCache(), clean = true) == null)
    }
    scenario("legacy invalid pending markers and correction authorship still reject") {
        check(inspect(oldCache(pending = "missing")) == null)
        check(inspect(oldCache(actual.copy(correctionVersion = 1))) == null)
        check(inspect(oldCache(actual.copy(lastCorrectedAt = "2026-11-01T01:00:00Z"))) == null)
        check(inspect(oldCache(actual.copy(clientUpdatedAt = "2026-11-01T01:00:00Z"))) == null)
    }
    scenario("pretrip raw input requires original owner and contributes its vineyard scope") {
        check(inspect(cache(draft)) == setOf("vineyard"))
        check(inspect(cache(draft), other) == null)
    }
    scenario("input drafts cannot disappear through clean exit or unattributed admission") {
        check(inspect(cache(draft), clean = true) == null)
        check(inspect(cache(draft), actor = null) == null)
    }
    val tank = draft.copy(key = "tank:original-trip:original-tank", tripId = "original-trip",
        tankId = "original-tank", sprayRecordId = "original-spray")
    scenario("exact trip/tank input draft remains draft-only scoped evidence") {
        check(inspect(cache(tank)) == setOf("vineyard"))
    }
    scenario("every retained vineyard remains subject to membership verification") {
        check(inspect(cache(draft, draft.copy(vineyardId = "other-vineyard"))) == setOf("vineyard", "other-vineyard"))
    }
    scenario("mixed owners reject the entire cache for either account") {
        val mixed = cache(draft, draft.copy(ownerUserId = other))
        check(inspect(mixed) == null); check(inspect(mixed, other) == null)
    }
    scenario("duplicate scope keys reject equal and differing input rather than selecting one") {
        check(inspect(cache(draft, draft)) == null)
        check(inspect(cache(draft, draft.copy(text = mapOf("water" to "999")))) == null)
    }
    scenario("malformed scope and partial tank identities remain held") {
        for (bad in listOf(draft.copy(key = ""), draft.copy(key = "review:short"),
            draft.copy(ownerUserId = ""), draft.copy(vineyardId = " "), draft.copy(tripId = "trip"),
            draft.copy(tankId = "tank"), draft.copy(sprayRecordId = "spray"),
            tank.copy(tripId = "wrong"), tank.copy(tankId = "wrong"), tank.copy(sprayRecordId = ""))) {
            check(inspect(cache(bad)) == null)
        }
    }
    scenario("unknown outer and nested payload fields remain strict") {
        val valid = cache(draft)
        check(inspect(valid.replace("\"inputDrafts\":", "\"unreviewed\":true,\"inputDrafts\":")) == null)
        check(inspect(valid.replace("\"ownerUserId\":", "\"unreviewed\":true,\"ownerUserId\":")) == null)
    }
    scenario("null malformed and missing draft payloads remain held") {
        for (value in listOf("null", "{}", "[{}]", "[1]")) {
            check(inspect("""{"records":[],"pendingIds":[],"inputDrafts":$value}""") == null)
        }
    }
    scenario("new input does not relax the confirmed-actual contract in a mixed cache") {
        val entry = codec.encodeToString(SprayActualInputDraft.serializer(), draft)
        val mixed = oldCache().dropLast(1) + ",\"inputDrafts\":[$entry]}"
        check(inspect(mixed) == setOf("vineyard"))
        check(inspect(mixed.replace("\"confirmed_by\":\"$owner\"", "\"confirmed_by\":\"$other\"")) == null)
    }
    println("HOST TOTAL: $passed scenarios passed. Real classifier/models/JSON; Android/files/unrelated stores are explicit doubles. NOT native or full auth recovery.")
}
''',
}

with tempfile.TemporaryDirectory(prefix="vinetrack-draft-recovery-host-") as directory:
    work = Path(directory)
    sources = []
    for name, source in STUBS.items():
        target = work / name
        target.write_text(source)
        sources.append(target)
    app = ROOT / "android-vinetrack/app/src/main/java/com/rork/vinetrack/data"
    sources.extend([app / "auth/AccountTransitionEvidence.kt", app / "model/SprayTankActual.kt",
                    app / "model/SprayActualInputDraft.kt"])
    libraries = [args.library_dir / f"kotlinx-serialization-{kind}-jvm-1.10.0.jar" for kind in ("core", "json")]
    classpath = os.pathsep.join(map(str, libraries))
    output = work / "probe.jar"
    subprocess.run([str(args.kotlin_home / "bin/kotlinc"), *map(str, sources),
                    "-Xplugin=" + str(args.kotlin_home / "lib/kotlinx-serialization-compiler-plugin.jar"),
                    "-cp", classpath, "-include-runtime", "-d", str(output)], check=True)
    subprocess.run(["java", "-cp", os.pathsep.join([str(output), classpath]),
                    "com.rork.vinetrack.data.auth.ProbeKt", str(work)], check=True)

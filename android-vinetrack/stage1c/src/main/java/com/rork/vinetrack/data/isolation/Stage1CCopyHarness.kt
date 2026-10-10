package com.rork.vinetrack.data.isolation

import android.content.Context
import android.os.Build
import android.os.Debug
import android.os.SystemClock
import android.provider.Settings
import android.system.Os
import android.system.OsConstants
import com.rork.vinetrack.stage1c.BuildConfig
import java.io.File
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Separate UID, test-only APK. No repository, auth, dispatcher, repair, seeder or source-write entry. */
internal class Stage1CCopyHarness(private val context: Context) {
    private val started = SystemClock.elapsedRealtime()
    @Volatile private var stopped: Boolean = false
    fun requestStop() { stopped = true }
    private fun checkpoint() {
        check(!stopped && !Thread.currentThread().isInterrupted && SystemClock.elapsedRealtime() - started < 300_000L) { "Operator stop or time budget reached" }
    }
    private val json = Json { encodeDefaults = true }
    private val files = context.filesDir.canonicalFile
    private val input = File(files, "trial-source")
    private val diagnostics = File(files, "trial-diagnostics")
    private val destination = File(files, "trial-destination")
    private val disk = IsolationDisk(syncDirectory = { directory ->
        check(directory == files || directory.toPath().startsWith(diagnostics.toPath()) || directory.toPath().startsWith(destination.toPath()))
        val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
        try { Os.fsync(fd) } finally { Os.close(fd) }
    }, checkpoint = { checkpoint() })
    private val requiredFamilies = setOf("pins", "pin-photos", "trip", "gps", "tank", "growth", "scout", "pending", "recovery")
    private val requiredEvidence = setOf("writer-stop", "idle", "provenance", "root-inventory", "reference-audit", "durability", "offline", "metadata-policy")

    fun preflight(): TrialReport {
        val start = SystemClock.elapsedRealtime()
        return try {
            val baseline = admission()
            val first = inventory(baseline)
            check(first == inventory(baseline)) { "Source baseline changed" }
            val sourceBytes = first.fold(0L) { total, row -> Math.addExact(total, row.file.length()) }
            val rawManifestBytes = json.encodeToString(VaultManifest(entries = baseline.sources.sortedBy { it.path }.mapIndexed { index, row ->
                VaultEntry(row.path, row.length, row.sha256, "$index.raw")
            })).toByteArray().size.toLong()
            val manifestBudget = Math.addExact(Math.addExact(1024L * 1024L, Math.multiplyExact(first.size.toLong(), 8192L)),
                Math.addExact(Math.multiplyExact(rawManifestBytes, 4L), Math.multiplyExact(File(diagnostics, "preflight-input.json").length(), 2L)))
            val reserve = maxOf(64L * 1024L * 1024L, Math.addExact(sourceBytes, 9L) / 10L)
            val required = Math.addExact(Math.multiplyExact(sourceBytes, 2L), Math.addExact(manifestBudget, reserve))
            val free = files.usableSpace
            check(free >= required) { "Insufficient free storage" }
            report("PREFLIGHT_READY_EXECUTION_LOCKED", "Independent evidence validated; execution approval absent", start)
                .copy(sourceBytes = sourceBytes, sourceCount = first.size, manifestBudgetBytes = manifestBudget,
                    scratchBudgetBytes = sourceBytes, reserveBytes = reserve, requiredFreeBytes = required, availableBytes = free)
                .also { saveDiagnostic(it) }
        } catch (_: Exception) {
            // No raw paths, data, account IDs or exception messages in visible diagnostics.
            report("NO_GO", "Missing or mismatched device pin, baseline, reviewed evidence, idle state, metadata policy or space", start)
        }
    }

    /** Not callable successfully in this preparation APK, even via an explicit intent. */
    fun copyAfterSeparateApproval(): String {
        check(BuildConfig.DEVICE_TRIAL_EXECUTION_APPROVED) { "Device execution not approved" }
        val baseline = admission()
        val preflight = preflight()
        check(preflight.status == "PREFLIGHT_READY_EXECUTION_LOCKED")
        check(!destination.exists()) { "Existing destination retained; no automatic retry" }
        disk.directory(destination)
        return requireNotNull(disk.tryLocked(destination) {
            disk.publishBytes(File(destination, "original-manifest.json"), File(diagnostics, "preflight-input.json").readBytes())
            val vaultRoot = File(destination, "vault")
            val vault = RawEvidenceVault(vaultRoot, disk, { inventory(baseline) },
                availableBytes = { (files.usableSpace - preflight.reserveBytes).coerceAtLeast(0L) }, checkpoint = { checkpoint() })
            vault.preserve()
            inventory(baseline)
            val anchor = ClosedEvidenceSet(disk).seal(vaultRoot, File(destination, "archive-set.json"))
            disk.publishBytes(File(diagnostics, "archive-anchor.txt"), anchor.toByteArray())
            anchor
        }) { "Lease busy; defer" }
    }

    /** A new process must receive the archive anchor retained independently by the operator. */
    fun verifyAfterRestart(independentAnchor: String) {
        check(BuildConfig.DEVICE_TRIAL_EXECUTION_APPROVED) { "Device execution not approved" }
        val baseline = admission()
        check(independentAnchor.matches(Regex("[a-f0-9]{64}")))
        check(File(destination, "original-manifest.json").readBytes().contentEquals(File(diagnostics, "preflight-input.json").readBytes()))
        val vault = File(destination, "vault")
        RawEvidenceVault(vault, disk, { inventory(baseline) }).verifyArchive()
        ClosedEvidenceSet(disk).verify(vault, File(destination, "archive-set.json"), independentAnchor)
        inventory(baseline)
    }

    private fun admission(): TrialPreflight {
        checkpoint()
        check(BuildConfig.DEBUG && !BuildConfig.FIELD_STORAGE_ISOLATION_ACTIVATED)
        val androidId = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: error("Device identity absent")
        check(BuildConfig.DEVICE_PIN.matches(Regex("[a-f0-9]{64}")))
        check(IsolationDisk.digest("$androidId\n${Build.FINGERPRINT}".toByteArray()) == BuildConfig.DEVICE_PIN)
        check(Settings.Global.getInt(context.contentResolver, "airplane_mode_on", 0) == 1)
        check(Settings.Global.getInt(context.contentResolver, "wifi_on", 1) == 0)
        check(Settings.Global.getInt(context.contentResolver, "bluetooth_on", 1) == 0)
        check(Settings.Global.getInt(context.contentResolver, "mobile_data", 1) == 0)
        check(input.absoluteFile == input.canonicalFile && input.isDirectory)
        // Frozen Stage 1B primitives use ordinary read streams. Require noatime BEFORE reading sources.
        val mount = File("/proc/mounts").readLines().map { it.split(' ') }.filter {
            it.size >= 4 && (input.path == it[1] || input.path.startsWith(it[1].trimEnd('/') + "/"))
        }.maxByOrNull { it[1].length } ?: error("Mount policy unavailable")
        check("noatime" in mount[3].split(',')) { "Unchanged source atime cannot be demonstrated" }
        val pack = File(diagnostics, "preflight-input.json")
        check(pack.absoluteFile == pack.canonicalFile && pack.isFile && pack.length() <= 8L * 1024L * 1024L)
        check(BuildConfig.PREFLIGHT_PIN.matches(Regex("[a-f0-9]{64}")))
        check(IsolationDisk.digest(pack) == BuildConfig.PREFLIGHT_PIN)
        val baseline = json.decodeFromString<TrialPreflight>(pack.readText())
        check(baseline.version == 1 && baseline.syntheticAccount.startsWith("synthetic-stage1c-"))
        val now = System.currentTimeMillis()
        check(baseline.observedAtUtcMillis <= now && now <= baseline.validUntilUtcMillis)
        check(baseline.validUntilUtcMillis > baseline.observedAtUtcMillis &&
            baseline.validUntilUtcMillis - baseline.observedAtUtcMillis <= 3_600_000L) { "Stale external preflight" }
        check(baseline.syntheticOnly && baseline.noCredentialsOrProduction && baseline.normalWritersStopped && baseline.durableIdleBaseline)
        check(baseline.noActiveTrip && baseline.noOpenTank && baseline.noCaptureInFlight && baseline.noOperationInFlight && baseline.noUnresolvedOwnership && baseline.allDeviceRootsReviewed)
        check(baseline.evidence.keys == requiredEvidence)
        baseline.evidence.values.forEach { proof ->
            check(proof.reviewedBy.isNotBlank())
            val file = safeChild(diagnostics, proof.path)
            check(file.isFile && IsolationDisk.digest(file) == proof.sha256)
        }
        check(baseline.sources.isNotEmpty() && baseline.sources.size <= 10000)
        check(baseline.sources.flatMap { it.families }.toSet().containsAll(requiredFamilies))
        check(baseline.sources.all { it.syntheticAccount == baseline.syntheticAccount && it.families.isNotEmpty() })
        check(baseline.references.isNotEmpty())
        baseline.references.forEach { reference ->
            check(baseline.sources.any { it.path == reference.metadataPath })
            check(baseline.sources.any { it.path == reference.photoPath && it.length > 0 })
        }
        return baseline
    }

    private fun inventory(baseline: TrialPreflight): List<RawEvidenceSource> {
        val expected = baseline.sources.map { it.path } + baseline.exclusions.map { it.path }
        check(expected.distinct().size == expected.size)
        check(expected.none { it.contains("vinetrack_session") || it.contains("vinetrack_biometric") })
        val actual = mutableListOf<String>()
        fun walk(directory: File) {
            check(directory.absoluteFile == directory.canonicalFile)
            checkNotNull(directory.listFiles()).sortedBy { it.name }.forEach { child ->
                check(child.absoluteFile == child.canonicalFile)
                if (child.isDirectory) {
                    val relative = input.toPath().relativize(child.toPath()).toString()
                    check(expected.any { it.startsWith("$relative/") }) { "Unreviewed directory" }
                    walk(child)
                } else {
                    check(child.isFile)
                    actual += input.toPath().relativize(child.toPath()).toString()
                }
            }
        }
        walk(input)
        check(actual.sorted() == expected.sorted()) { "Unknown or missing file" }
        baseline.exclusions.forEach { exclusion ->
            check(exclusion.reason.isNotBlank())
            val file = safeChild(input, exclusion.path)
            check(file.length() == exclusion.length && IsolationDisk.digest(file) == exclusion.sha256)
        }
        val sources = baseline.sources.sortedBy { it.path }.map { entry ->
            checkpoint()
            check(!entry.path.contains("vinetrack_session") && !entry.path.contains("vinetrack_biometric"))
            val file = safeChild(input, entry.path)
            val before = Os.stat(file.path)
            check(before.st_size == entry.length && before.st_mode == entry.mode && before.st_uid == entry.uid && before.st_gid == entry.gid)
            check(before.st_mtime == entry.modifiedSeconds && before.st_atime == entry.accessedSeconds && before.st_ctime == entry.changedSeconds)
            check(IsolationDisk.digest(file) == entry.sha256)
            val after = Os.stat(file.path)
            check(after.st_mtime == before.st_mtime && after.st_atime == before.st_atime && after.st_ctime == before.st_ctime)
            RawEvidenceSource(entry.path, file)
        }
        // Existing reviewed path policy, in addition to the independently closed register.
        val reviewed = ReviewedBusinessInventory.sources(File(input, "shared_prefs"), File(input, "files"), File(input, "cache"))
        check(reviewed.map { it.identity.replace("sharedpref/", "shared_prefs/") }.sorted() == baseline.sources.map { it.path }.sorted())
        return sources
    }

    private fun safeChild(root: File, relative: String): File {
        check(relative.isNotBlank() && !relative.startsWith('/') && relative.split('/').none { it.isBlank() || it == "." || it == ".." })
        return File(root, relative).also {
            check(it.absoluteFile == it.canonicalFile && it.toPath().startsWith(root.toPath()))
        }
    }

    private fun report(status: String, reason: String, start: Long): TrialReport {
        val memory = Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }
        return TrialReport(status, reason, Build.MODEL, Build.VERSION.RELEASE, Build.VERSION.SDK_INT,
            BuildConfig.SOURCE_DIGEST, availableBytes = files.usableSpace,
            elapsedMillis = SystemClock.elapsedRealtime() - start, sampledPssKiB = memory.totalPss)
    }

    private fun saveDiagnostic(report: TrialReport) {
        check(diagnostics.isDirectory && diagnostics.absoluteFile == diagnostics.canonicalFile)
        disk.publishBytes(File(diagnostics, "preflight-${SystemClock.elapsedRealtimeNanos()}.json"), json.encodeToString(report).toByteArray())
    }
}

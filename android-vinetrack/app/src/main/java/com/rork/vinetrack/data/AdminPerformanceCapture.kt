package com.rork.vinetrack.data

import android.content.Context
import android.os.SystemClock
import com.rork.vinetrack.BuildConfig
import java.util.Locale

/** Opt-in bounded memory evidence. Only fixed phases and elapsed numbers are accepted. */
internal class AdminPerformanceCapture(context: Context, private val currentOwner: () -> String?) {
    enum class Phase {
        VINEYARD_REFRESH, LOCAL_HYDRATION, CACHED_DATA_PUBLISHED,
        SESSION_RESTORE, VINEYARD_MEMBERSHIP_READ, TEAM_MEMBERSHIP_READ,
        BLOCKS_READ, PINS_READ, TRIPS_READ, WORK_TASKS_READ,
        HOME_APPEARED, TRIP_APPEARED, PROGRAM_APPEARED, OTHER_SURFACE_APPEARED,
    }
    data class Span(val generation: Long, val phase: Phase, val startMs: Long)

    private val prefs = context.applicationContext.getSharedPreferences("admin_performance_capture", Context.MODE_PRIVATE)
    private var owner: String? = prefs.getString("opted_in_owner", null)
    private var verifiedOwner: String? = null
    private var generation: Long = 0L
    private var originMs: Long = SystemClock.elapsedRealtime()
    private val rows = ArrayDeque<String>()
    private var dropped: Int = 0

    val isRequested: Boolean get() = owner != null && owner == currentOwner()

    fun authorize(allowed: Boolean, checkedOwner: String?) {
        if (!allowed || checkedOwner == null || checkedOwner != currentOwner()) {
            revoke()
            return
        }
        if (owner != null && owner != checkedOwner) revoke()
        verifiedOwner = checkedOwner
    }

    fun setEnabled(enabled: Boolean): Boolean {
        val current = currentOwner() ?: return false
        if (verifiedOwner != current) return false
        if (!prefs.edit().putString("opted_in_owner", if (enabled) current else null).commit()) return false
        owner = if (enabled) current else null
        clear()
        return true
    }

    fun revoke() {
        owner = null
        verifiedOwner = null
        prefs.edit().remove("opted_in_owner").apply()
        clear()
    }

    private fun canCapture(): Boolean {
        if (owner == null) return false
        if (owner != currentOwner()) {
            revoke()
            return false
        }
        // Opt-in permits early numeric buffering, never viewing or exporting.
        return true
    }

    fun begin(phase: Phase): Span? = if (canCapture())
        Span(generation, phase, SystemClock.elapsedRealtime()) else null

    fun end(span: Span?) {
        if (span == null || span.generation != generation || !canCapture()) return
        append(String.format(Locale.US, "%s elapsed=%dms", span.phase.name,
            SystemClock.elapsedRealtime() - span.startMs))
    }

    fun mark(phase: Phase) {
        if (canCapture()) append(phase.name)
    }

    fun clear() {
        rows.clear()
        dropped = 0
        generation += 1
        originMs = SystemClock.elapsedRealtime()
    }

    private fun append(text: String) {
        if (rows.size >= 2000) {
            repeat(200) { rows.removeFirst() }
            dropped += 200
        }
        rows.addLast("${SystemClock.elapsedRealtime() - originMs}ms | $text")
    }

    /** Called only after a fresh server admin check for the current account. */
    fun report(): String? {
        if (verifiedOwner == null || verifiedOwner != currentOwner()) {
            revoke()
            return null
        }
        return buildString {
            appendLine("VineTrack Android performance timing report")
            appendLine("Version: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
            appendLine("OS API: ${android.os.Build.VERSION.SDK_INT}")
            appendLine("Retained events: ${rows.size}; older events dropped: $dropped")
            appendLine("Monotonic elapsed timings. Refresh spans include network waits, not CPU attribution.")
            appendLine("Surface markers indicate composition, not proof of fully usable data or a rendered frame.")
            appendLine("Early numeric buffering requires prior verified opt-in. Export requires fresh verification.")
            appendLine("Memory-only; lost on termination. No IDs, coordinates, keys, URLs, tokens or raw errors.")
            rows.forEach { appendLine(it) }
        }
    }
}

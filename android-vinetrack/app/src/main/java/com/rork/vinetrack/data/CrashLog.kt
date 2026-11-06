package com.rork.vinetrack.data

import android.content.Context
import java.io.File

/**
 * Minimal on-device crash journal. The app has no crash-reporting service, so
 * a field crash otherwise leaves no trace. The last few uncaught exceptions are
 * written to app-private storage and included in support diagnostics (Trips
 * recovery card → Copy diagnostics). The platform's default handler always
 * runs afterwards, so crash behaviour itself is unchanged.
 *
 * Only exception types, a truncated message and stack frames are kept — no
 * payloads, tokens or user data are read.
 */
object CrashLog {
    private const val DIR = "crash"
    private const val MAX_ENTRIES = 3
    private const val MAX_FRAMES = 40
    private const val MAX_MESSAGE = 200

    @Volatile private var installed = false

    fun install(context: Context) {
        if (installed) return
        synchronized(this) {
            if (installed) return
            installed = true
            val dir = File(context.applicationContext.filesDir, DIR)
            val previous = Thread.getDefaultUncaughtExceptionHandler()
            Thread.setDefaultUncaughtExceptionHandler { thread, error ->
                runCatching { record(dir, thread.name, error, System.currentTimeMillis()) }
                previous?.uncaughtException(thread, error)
            }
        }
    }

    internal fun format(threadName: String, error: Throwable, atMs: Long): String = buildString {
        appendLine("time=${java.time.Instant.ofEpochMilli(atMs)} thread=$threadName")
        var cause: Throwable? = error
        var depth = 0
        while (cause != null && depth < 4) {
            val message = cause.message?.replace('\n', ' ')?.take(MAX_MESSAGE)
            appendLine((if (depth == 0) "" else "Caused by: ") + cause.javaClass.name + (message?.let { ": $it" } ?: ""))
            cause.stackTrace.take(MAX_FRAMES).forEach { appendLine("    at $it") }
            cause = cause.cause?.takeIf { it !== cause }
            depth++
        }
    }

    internal fun record(dir: File, threadName: String, error: Throwable, atMs: Long) {
        dir.mkdirs()
        File(dir, "crash_$atMs.txt").writeText(format(threadName, error, atMs))
        entries(dir).drop(MAX_ENTRIES).forEach { it.delete() }
    }

    private fun entries(dir: File): List<File> =
        dir.listFiles { f -> f.name.startsWith("crash_") && f.name.endsWith(".txt") }
            ?.sortedByDescending { it.name.removePrefix("crash_").removeSuffix(".txt").toLongOrNull() ?: 0L }
            ?: emptyList()

    /** Diagnostics block: crash count plus the most recent crash in full. */
    fun summary(context: Context): String = summary(File(context.applicationContext.filesDir, DIR))

    internal fun summary(dir: File): String {
        val files = runCatching { entries(dir) }.getOrDefault(emptyList())
        if (files.isEmpty()) return "Recent crashes: none recorded\n"
        return buildString {
            appendLine("Recent crashes: ${files.size}")
            appendLine("Latest crash:")
            append(runCatching { files.first().readText() }.getOrDefault("(unreadable)\n"))
        }
    }
}

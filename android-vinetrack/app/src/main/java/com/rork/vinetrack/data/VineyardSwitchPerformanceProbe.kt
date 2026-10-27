package com.rork.vinetrack.data

import android.os.Looper
import android.os.SystemClock
import com.rork.vinetrack.BuildConfig
import kotlinx.coroutines.flow.MutableStateFlow

/** Debug-only opt-in. Bounded numerical evidence; no account, vineyard or record data. */
internal object VineyardSwitchPerformanceProbe {
    data class Sample(val stage: String, val milliseconds: Double, val mainThread: Boolean, val publications: Int)
    @Volatile private var enabled = false
    private var publications = 0
    private val samples = ArrayList<Sample>()
    @Synchronized fun start() { if (BuildConfig.DEBUG) { samples.clear(); publications = 0; enabled = true } }
    @Synchronized fun stop(): List<Sample> { enabled = false; return samples.toList() }
    fun isRecording(): Boolean = BuildConfig.DEBUG && enabled
    fun begin(): Pair<Long, Int>? = if (isRecording()) SystemClock.elapsedRealtimeNanos() to count() else null
    @Synchronized private fun count() = publications
    @Synchronized fun published() { if (BuildConfig.DEBUG && enabled) publications++ }
    @Synchronized fun end(stage: String, start: Pair<Long, Int>?) {
        if (BuildConfig.DEBUG && enabled && start != null && samples.size < 512) samples.add(Sample(stage,
            (SystemClock.elapsedRealtimeNanos() - start.first) / 1_000_000.0,
            Looper.myLooper() == Looper.getMainLooper(), publications - start.second))
    }
}

/** Counts successful changed StateFlow transitions, not retry attempts or Compose renders. */
internal class SwitchMeasuredStateFlow<T>(private val source: MutableStateFlow<T>) : MutableStateFlow<T> by source {
    override fun compareAndSet(expect: T, update: T): Boolean {
        val changed = source.compareAndSet(expect, update)
        // Never deep-compare AppUiState's large collections for instrumentation
        // during ordinary use. Only an explicitly enabled DEBUG capture pays it.
        if (changed && VineyardSwitchPerformanceProbe.isRecording() && expect != update)
            VineyardSwitchPerformanceProbe.published()
        return changed
    }
}

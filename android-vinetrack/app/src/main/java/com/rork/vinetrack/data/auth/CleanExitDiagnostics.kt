package com.rork.vinetrack.data.auth

/** Test-installed observer only; release registration and checkpoint delivery are disabled. */
internal object CleanExitDiagnostics {
    @Volatile var observer: ((String) -> Unit)? = null
        set(value) {
            field = if (com.rork.vinetrack.BuildConfig.DEBUG) value else null
        }

    fun checkpoint(stage: String) {
        if (com.rork.vinetrack.BuildConfig.DEBUG) observer?.invoke(stage)
    }
}

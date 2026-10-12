package com.rork.vinetrack.data.auth

/** Temporary instrumentation observer: stage names only, no credentials or account data. */
internal object CleanExitDiagnostics {
    @Volatile var observer: ((String) -> Unit)? = null

    fun checkpoint(stage: String) {
        if (com.rork.vinetrack.BuildConfig.DEBUG) observer?.invoke(stage)
    }
}

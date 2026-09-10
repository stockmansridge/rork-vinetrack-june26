package com.rork.vinetrack.data

/** Testable foreground/environment owner for a warm automatic-placement subscription. */
class ForegroundLocationSubscriptionController(
    private val start: () -> Unit,
    private val stop: () -> Unit,
) {
    private var isForeground: Boolean = false

    fun onForegroundChanged(foreground: Boolean) {
        isForeground = foreground
        if (foreground) restart() else stop()
    }

    fun onEnvironmentChanged() {
        if (isForeground) restart()
    }

    fun dispose() {
        isForeground = false
        stop()
    }

    private fun restart() {
        stop()
        start()
    }
}

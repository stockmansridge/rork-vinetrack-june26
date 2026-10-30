package com.rork.vinetrack.data

/** Existing public enum moved here so admission can be tested without Android. */
enum class RefreshOutcome {
    REFRESHED,
    REJECTED,
    TRANSIENT,
}

/** A failed refresh is not a successful empty vineyard download. */
internal object SyncSessionPolicy {
    enum class Admission { SEND_WITH_CURRENT_TOKEN, RETAIN_OFFLINE, REAUTHENTICATE }

    fun afterRefresh(outcome: RefreshOutcome, hasCurrentToken: Boolean): Admission = when (outcome) {
        RefreshOutcome.REFRESHED -> if (hasCurrentToken) Admission.SEND_WITH_CURRENT_TOKEN else Admission.RETAIN_OFFLINE
        RefreshOutcome.REJECTED -> Admission.REAUTHENTICATE
        RefreshOutcome.TRANSIENT -> Admission.RETAIN_OFFLINE
    }
}

package com.rork.vinetrack.data

/** A failed refresh is not an empty vineyard response or a successful login. */
enum class RefreshOutcome {
    REFRESHED,
    REJECTED,
    TRANSIENT,
}

/** Pure admission policy; shared transport must act on every refresh outcome. */
object SessionRefreshAdmission {
    enum class Decision { SEND_WITH_CURRENT_TOKEN, REQUIRE_REAUTHENTICATION, RETAIN_AND_RETRY }

    fun decision(outcome: RefreshOutcome): Decision = when (outcome) {
        RefreshOutcome.REFRESHED -> Decision.SEND_WITH_CURRENT_TOKEN
        RefreshOutcome.REJECTED -> Decision.REQUIRE_REAUTHENTICATION
        RefreshOutcome.TRANSIENT -> Decision.RETAIN_AND_RETRY
    }
}

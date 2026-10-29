package com.rork.vinetrack.data

import org.junit.Assert.assertEquals
import org.junit.Test

class SessionRefreshAdmissionTest {
    @Test fun refreshedSessionCanSendWithTheCurrentToken() {
        assertEquals(
            SessionRefreshAdmission.Decision.SEND_WITH_CURRENT_TOKEN,
            SessionRefreshAdmission.decision(RefreshOutcome.REFRESHED),
        )
    }

    @Test fun rejectedRefreshRequiresReauthenticationNotAnEmptyDataResponse() {
        assertEquals(
            SessionRefreshAdmission.Decision.REQUIRE_REAUTHENTICATION,
            SessionRefreshAdmission.decision(RefreshOutcome.REJECTED),
        )
    }

    @Test fun transientRefreshFailureRetainsLocalWorkAndDoesNotSendExpiredToken() {
        assertEquals(
            SessionRefreshAdmission.Decision.RETAIN_AND_RETRY,
            SessionRefreshAdmission.decision(RefreshOutcome.TRANSIENT),
        )
    }
}

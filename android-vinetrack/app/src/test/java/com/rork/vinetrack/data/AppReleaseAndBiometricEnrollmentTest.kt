package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.BiometricEnrollmentEligibility
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppReleaseAndBiometricEnrollmentTest {
    private fun release(latest: Long = 12, minimum: Long = 9, version: String = "3.1.3") = AppReleasePolicy(
        platform = "android", latestVersion = version, latestBuild = latest,
        minimumSupportedVersion = "3.0", minimumSupportedBuild = minimum,
        updateTitle = "Update available", updateMessage = "A newer version is available",
        storeUrl = "https://play.google.com/store/apps/details?id=com.rork.vinetrack",
        active = true, updatedAt = "2026-09-23T00:00:00Z",
    )

    @Test fun existingAuthenticatedCustomerGetsOneTimeOfferAfterShellIsReady() {
        assertTrue(BiometricEnrollmentEligibility.shouldOffer(true, true, false, false))
        assertFalse(BiometricEnrollmentEligibility.shouldOffer(false, true, false, false))
        assertFalse(BiometricEnrollmentEligibility.shouldOffer(true, false, false, false))
    }

    @Test fun notNowAndEnableSuppressFutureOffers() {
        assertFalse(BiometricEnrollmentEligibility.shouldOffer(true, true, false, true))
        assertFalse(BiometricEnrollmentEligibility.shouldOffer(true, true, true, false))
    }

    @Test fun restoredSessionLocksButExplicitSignOutNeedsAccountLogin() {
        assertTrue(BiometricEnrollmentEligibility.shouldLock(true, true))
        assertFalse(BiometricEnrollmentEligibility.shouldLock(false, true))
    }

    @Test fun installedBuildEqualsLatestDoesNotPrompt() {
        assertEquals(ReleaseDecision.NONE, release().decision(12))
        assertEquals(ReleaseDecision.NONE, release().decision(13))
    }

    @Test fun betweenMinimumAndLatestIsOptional() {
        assertEquals(ReleaseDecision.OPTIONAL, release().decision(10))
    }

    @Test fun belowMinimumIsRequiredOnlyIfMinimumRaised() {
        assertEquals(ReleaseDecision.REQUIRED, release().decision(8))
        assertEquals(ReleaseDecision.OPTIONAL, release(minimum = 0).decision(8))
    }

    @Test fun numericBuildIsAuthorityAndUnavailablePolicyHasNoDecision() {
        assertEquals(ReleaseDecision.OPTIONAL, release(version = "0.1").decision(10))
        assertEquals(ReleaseDecision.NONE, release(version = "99.0").decision(12))
        val unavailable: AppReleasePolicy? = null
        assertEquals(ReleaseDecision.NONE, unavailable?.decision(1) ?: ReleaseDecision.NONE)
    }
}

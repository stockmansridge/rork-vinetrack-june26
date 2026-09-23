package com.rork.vinetrack.data.auth

/** Shared decision for a fresh login or a restored session after the main shell is ready. */
object BiometricEnrollmentEligibility {
    fun shouldOffer(isInMainShell: Boolean, supportsDeviceAuth: Boolean, isEnabled: Boolean, hasPrompted: Boolean): Boolean =
        isInMainShell && supportsDeviceAuth && !isEnabled && !hasPrompted

    fun shouldLock(hasRestoredSession: Boolean, isEnabled: Boolean): Boolean =
        hasRestoredSession && isEnabled
}

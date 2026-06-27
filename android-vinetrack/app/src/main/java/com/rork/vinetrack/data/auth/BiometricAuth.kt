package com.rork.vinetrack.data.auth

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * Device biometric capability snapshot, the Android equivalent of the iOS
 * `BiometricAuthService` capability flags.
 */
data class BiometricCapability(
    val canUseBiometrics: Boolean,
    val canUseDeviceCredential: Boolean,
) {
    /** Either a fingerprint/face OR a device PIN/pattern is available. */
    val canUseAnyAuth: Boolean get() = canUseBiometrics || canUseDeviceCredential

    /**
     * Human-readable modality name for UI copy, the Android counterpart of the
     * iOS `BiometricAuthService.displayName` ("Face ID" / "Touch ID"). Android's
     * BiometricManager doesn't expose fingerprint-vs-face reliably, so we use an
     * honest generic label.
     */
    val displayName: String
        get() = when {
            canUseBiometrics -> "biometric unlock"
            canUseDeviceCredential -> "device unlock"
            else -> "biometric unlock"
        }
}

/** Result of a single authentication attempt. */
sealed interface BiometricResult {
    data object Success : BiometricResult
    /** User cancelled — not a real error, surface no message. */
    data object Cancelled : BiometricResult
    data class Failed(val message: String) : BiometricResult
}

/**
 * Thin wrapper around AndroidX [BiometricPrompt]. The prompt must run against a
 * [FragmentActivity], so authentication is triggered from the UI layer while the
 * persisted preference lives in [BiometricStore].
 */
object BiometricAuth {

    fun capability(context: Context): BiometricCapability {
        val manager = BiometricManager.from(context)
        val bio = manager.canAuthenticate(BIOMETRIC_WEAK) == BiometricManager.BIOMETRIC_SUCCESS
        val cred = manager.canAuthenticate(DEVICE_CREDENTIAL) == BiometricManager.BIOMETRIC_SUCCESS
        return BiometricCapability(canUseBiometrics = bio, canUseDeviceCredential = cred)
    }

    suspend fun authenticate(
        activity: FragmentActivity,
        title: String,
        subtitle: String?,
        reason: String?,
    ): BiometricResult = suspendCancellableCoroutine { cont ->
        val capability = capability(activity)
        // Prefer biometrics; fall back to the device PIN/pattern so the user is
        // never locked out. When only device credential is available we cannot
        // attach a negative ("Cancel") button — the system provides its own.
        val useBiometrics = capability.canUseBiometrics
        val authenticators = if (useBiometrics) BIOMETRIC_WEAK else DEVICE_CREDENTIAL

        val executor = ContextCompat.getMainExecutor(activity)
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            private var settled = false

            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                if (settled) return
                settled = true
                if (cont.isActive) cont.resume(BiometricResult.Success)
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                if (settled) return
                settled = true
                val cancelled = errorCode == BiometricPrompt.ERROR_USER_CANCELED ||
                    errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON ||
                    errorCode == BiometricPrompt.ERROR_CANCELED
                val outcome = if (cancelled) {
                    BiometricResult.Cancelled
                } else {
                    BiometricResult.Failed(errString.toString())
                }
                if (cont.isActive) cont.resume(outcome)
            }

            override fun onAuthenticationFailed() {
                // A single non-matching attempt — the prompt stays open, so do
                // not resolve here.
            }
        }

        val prompt = BiometricPrompt(activity, executor, callback)
        val builder = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setAllowedAuthenticators(authenticators)
        subtitle?.let { builder.setSubtitle(it) }
        reason?.let { builder.setDescription(it) }
        if (useBiometrics) {
            builder.setNegativeButtonText("Cancel")
        }

        runCatching { prompt.authenticate(builder.build()) }
            .onFailure {
                if (cont.isActive) {
                    cont.resume(BiometricResult.Failed(it.message ?: "Biometric authentication is unavailable."))
                }
            }
    }
}

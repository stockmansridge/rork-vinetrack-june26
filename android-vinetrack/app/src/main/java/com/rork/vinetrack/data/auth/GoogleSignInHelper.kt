package com.rork.vinetrack.data.auth

import android.content.Context
import android.util.Log
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.NoCredentialException
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.rork.vinetrack.data.AppConfig
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * Native Google sign-in via Credential Manager, mirroring the iOS
 * AppleSignInHelper: a raw nonce is generated, its SHA-256 is sent to Google,
 * and the raw nonce + returned ID token are handed to Supabase's id_token
 * grant, which verifies the hash against the token's nonce claim.
 *
 * No secrets are stored here — the WEB client ID is a public identifier
 * resolved from build config ([AppConfig.googleWebClientId]).
 */
object GoogleSignInHelper {

    sealed interface SignInResult {
        data class Success(val idToken: String, val rawNonce: String) : SignInResult
        data object Cancelled : SignInResult
        data class Failure(val message: String) : SignInResult
    }

    /**
     * Launches the Sign in with Google UI. [activityContext] must be an
     * Activity context — Credential Manager needs it to show its sheet.
     */
    suspend fun signIn(activityContext: Context): SignInResult {
        val webClientId = AppConfig.googleWebClientId
        if (webClientId.isBlank()) {
            return SignInResult.Failure("Google sign-in isn't configured for this build yet.")
        }
        val rawNonce = randomNonce()
        val option = GetSignInWithGoogleOption.Builder(webClientId)
            .setNonce(sha256Hex(rawNonce))
            .build()
        val request = GetCredentialRequest.Builder()
            .addCredentialOption(option)
            .build()
        return try {
            val response = CredentialManager.create(activityContext)
                .getCredential(activityContext, request)
            val credential = response.credential
            if (credential is CustomCredential &&
                credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
            ) {
                val googleCredential = GoogleIdTokenCredential.createFrom(credential.data)
                SignInResult.Success(idToken = googleCredential.idToken, rawNonce = rawNonce)
            } else {
                SignInResult.Failure("Google did not return a valid identity token.")
            }
        } catch (_: GetCredentialCancellationException) {
            SignInResult.Cancelled
        } catch (_: NoCredentialException) {
            SignInResult.Failure(
                "No Google account found on this device. Add a Google account in device Settings and try again.",
            )
        } catch (e: Exception) {
            Log.w(TAG, "Google sign-in failed: ${e.message}")
            SignInResult.Failure("Google sign-in failed. Please try again.")
        }
    }

    private fun randomNonce(): String {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return bytes.toHex()
    }

    private fun sha256Hex(input: String): String =
        MessageDigest.getInstance("SHA-256").digest(input.toByteArray()).toHex()

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    private const val TAG = "VineTrackAuth"
}

package com.rork.vinetrack.data.auth

import kotlinx.serialization.json.Json
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Runs the real JSON classifier, not only its extracted pure code policy. */
class RefreshRejectionLegacyTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    @Test fun legacyNumericHttpCodeCannotMaskMachineReadableRejection() {
        assertTrue(RefreshRejection.isDefinitive(400,
            """{"code":400,"error_code":"refresh_token_not_found","msg":"Invalid Refresh Token: Refresh Token Not Found"}""", json))
        assertTrue(RefreshRejection.isDefinitive(401,
            """{"code":401,"error_code":"session_expired"}""", json))
    }

    @Test fun modernAndMatchingDualStringCodesStillWork() {
        assertTrue(RefreshRejection.isDefinitive(400,
            """{"code":"refresh_token_already_used"}""", json))
        assertTrue(RefreshRejection.isDefinitive(403,
            """{"code":"user_banned","error_code":"user_banned"}""", json))
        assertTrue(RefreshRejection.isDefinitive(400,
            """{"code":null,"error_code":"session_not_found"}""", json))
    }

    @Test fun everySupportedRejectionRetainsBothWireFormats() {
        val codes = listOf("refresh_token_not_found", "refresh_token_already_used",
            "session_not_found", "session_expired", "user_banned", "user_not_found")
        for (status in listOf(400, 401, 403)) for (code in codes) {
            assertTrue(RefreshRejection.isDefinitive(status,
                """{"code":$status,"error_code":"$code"}""", json))
            assertTrue(RefreshRejection.isDefinitive(status,
                """{"code":"$code"}""", json))
        }
    }

    @Test fun rateLimitsServerErrorsAndSuccessNeverRevokeCredentials() {
        for (status in listOf(200, 429, 500, 503)) {
            assertFalse(RefreshRejection.isDefinitive(status,
                """{"code":$status,"error_code":"refresh_token_not_found"}""", json))
        }
        assertFalse(RefreshRejection.isDefinitive(400,
            """{"code":400,"error_code":"over_request_rate_limit"}""", json))
    }

    @Test fun statusFreeTextMalformedBodiesAndGenericGrantErrorsAreNotProof() {
        val bodies = listOf("", "<html>session expired</html>", "[]", "null",
            """{"code":400,"msg":"Refresh Token Not Found"}""",
            """{"code":"invalid_grant"}""",
            """{"error_code":{},"code":400}""",
            """{"error_code":400}""",
            """{"code":"insufficient_aal"}""")
        for (body in bodies) assertFalse(body, RefreshRejection.isDefinitive(400, body, json))
    }

    @Test fun contradictoryMachineCodesStayUnverified() {
        assertFalse(RefreshRejection.isDefinitive(400,
            """{"code":"insufficient_aal","error_code":"refresh_token_not_found"}""", json))
        assertFalse(RefreshRejection.isDefinitive(400,
            """{"code":"session_expired","error_code":"refresh_token_not_found"}""", json))
    }
}

package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.call.body
import io.ktor.client.request.headers
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.content.ByteArrayContent
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

/** Category for an in-app support / feedback / feature request (mirrors iOS). */
enum class SupportRequestCategory(val raw: String, val label: String) {
    General("general", "General"),
    Bug("bug", "Bug / Issue"),
    Feature("feature", "Feature Request"),
    Account("account", "Account"),
    Billing("billing", "Billing"),
    Other("other", "Other"),
}

/** Device / app snapshot attached to a support request. */
data class SupportDiagnostics(
    val appPlatform: String,
    val appVersion: String,
    val appBuild: String,
    val deviceModel: String,
    val osVersion: String,
)

/**
 * Outcome of submitting a support request. The DB insert is the durable path,
 * so success means the request is stored; each email delivery outcome is
 * reported independently.
 */
data class SupportSubmissionResult(
    val requestSaved: Boolean,
    val staffEmailSent: Boolean,
    val receiptEmailSent: Boolean,
    val attachmentCount: Int,
) {
    val bothEmailsSent: Boolean get() = staffEmailSent && receiptEmailSent
}

/**
 * Backend pathway for the in-app support / feedback / feature-request form,
 * mirroring the iOS `SupabaseSupportRepository`.
 *
 * Flow (durable-first):
 *   1. Upload any attachments to the private `support-attachments` bucket,
 *      namespaced as `{user_id}/{request_id}/attachment-N.jpg`.
 *   2. Insert a `support_requests` row (RLS: own user only) — the durable path.
 *   3. Best-effort: invoke the `support-request` edge function to email support
 *      and record `email_status`. A failure here does NOT fail the submission.
 */
class SupportRepository(private val session: SessionStore) {

    suspend fun submit(
        category: SupportRequestCategory,
        subject: String,
        message: String,
        submitterName: String?,
        submitterEmail: String?,
        vineyardId: String?,
        vineyardName: String?,
        attachments: List<ByteArray>,
        diagnostics: SupportDiagnostics,
    ): SupportSubmissionResult = withContext(Dispatchers.IO) {
        requireConfig()
        val token = session.accessToken ?: throw BackendError.Unauthorized
        val userId = session.userId ?: throw BackendError.Unauthorized
        val requestId = UUID.randomUUID().toString().lowercase()

        // 1. Upload attachments first; a failed upload aborts before insert so
        //    the row never references a missing file.
        val attachmentPaths = mutableListOf<String>()
        attachments.forEachIndexed { index, jpeg ->
            val path = "${userId.lowercase()}/$requestId/attachment-$index.jpg"
            val response = SupabaseClient.http.post(
                SupabaseClient.storageUrl("object/$ATTACHMENTS_BUCKET/$path")
            ) {
                authHeaders(token)
                headers {
                    append("x-upsert", "true")
                    append("cache-control", "3600")
                }
                setBody(ByteArrayContent(jpeg, ContentType.Image.JPEG))
            }
            when {
                response.status.isSuccess() -> attachmentPaths.add(path)
                response.status.value == 401 || response.status.value == 403 -> throw BackendError.Unauthorized
                else -> throw BackendError.Server(response.status.value, response.bodyAsText())
            }
        }

        // 2. Insert the durable row.
        fun String?.nonEmpty(): String? = this?.trim()?.takeIf { it.isNotEmpty() }
        val insert = SupportRequestInsert(
            id = requestId,
            userId = userId.lowercase(),
            submitterName = submitterName.nonEmpty(),
            submitterEmail = submitterEmail.nonEmpty(),
            vineyardId = vineyardId?.lowercase(),
            vineyardName = vineyardName.nonEmpty(),
            category = category.raw,
            subject = subject,
            message = message,
            attachmentPaths = attachmentPaths,
            attachmentCount = attachmentPaths.size,
            appPlatform = diagnostics.appPlatform,
            appVersion = diagnostics.appVersion,
            appBuild = diagnostics.appBuild,
            deviceModel = diagnostics.deviceModel,
            osVersion = diagnostics.osVersion,
        )
        val insertResponse = SupabaseClient.http.post(
            SupabaseClient.restUrl("support_requests")
        ) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(insert)
        }
        when {
            insertResponse.status.isSuccess() -> Unit
            insertResponse.status.value == 401 || insertResponse.status.value == 403 -> throw BackendError.Unauthorized
            else -> throw BackendError.Server(insertResponse.status.value, insertResponse.bodyAsText())
        }

        // 3. Invoke production email delivery after the durable row is saved.
        // A delivery failure is non-fatal because the request already exists.
        val emailOutcome = notifyEmail(requestId, token)
        SupportSubmissionResult(
            requestSaved = true,
            staffEmailSent = emailOutcome.staffEmailSent,
            receiptEmailSent = emailOutcome.receiptEmailSent,
            attachmentCount = attachmentPaths.size,
        )
    }

    private suspend fun notifyEmail(requestId: String, token: String): SupportEmailOutcome = try {
        val response = SupabaseClient.http.post(SupabaseClient.functionUrl(EDGE_FUNCTION)) {
            authHeaders(token)
            contentType(ContentType.Application.Json)
            setBody(NotifyArgs(requestId = requestId, sourcePlatform = "android"))
        }
        if (response.status.isSuccess()) {
            response.body<NotifyResponse>().let { result ->
                if (result.success) {
                    SupportEmailOutcome(result.staffEmailSent, result.receiptEmailSent)
                } else {
                    SupportEmailOutcome.NotSent
                }
            }
        } else {
            SupportEmailOutcome.NotSent
        }
    } catch (_: Exception) {
        SupportEmailOutcome.NotSent
    }

    private fun requireConfig() {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
    }

    private fun io.ktor.client.request.HttpRequestBuilder.authHeaders(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }

    @Serializable
    private data class NotifyArgs(
        @SerialName("request_id") val requestId: String,
        @SerialName("source_platform") val sourcePlatform: String,
    )

    @Serializable
    private data class NotifyResponse(
        val success: Boolean = false,
        @SerialName("staff_email_sent") val staffEmailSent: Boolean = false,
        @SerialName("receipt_email_sent") val receiptEmailSent: Boolean = false,
    )

    private data class SupportEmailOutcome(
        val staffEmailSent: Boolean,
        val receiptEmailSent: Boolean,
    ) {
        companion object {
            val NotSent = SupportEmailOutcome(staffEmailSent = false, receiptEmailSent = false)
        }
    }

    @Serializable
    private data class SupportRequestInsert(
        val id: String,
        @SerialName("user_id") val userId: String,
        @SerialName("submitter_name") val submitterName: String?,
        @SerialName("submitter_email") val submitterEmail: String?,
        @SerialName("vineyard_id") val vineyardId: String?,
        @SerialName("vineyard_name") val vineyardName: String?,
        val category: String,
        val subject: String,
        val message: String,
        @SerialName("attachment_paths") val attachmentPaths: List<String>,
        @SerialName("attachment_count") val attachmentCount: Int,
        @SerialName("app_platform") val appPlatform: String?,
        @SerialName("app_version") val appVersion: String?,
        @SerialName("app_build") val appBuild: String?,
        @SerialName("device_model") val deviceModel: String?,
        @SerialName("os_version") val osVersion: String?,
    )

    companion object {
        const val ATTACHMENTS_BUCKET = "support-attachments"
        const val EDGE_FUNCTION = "support-request"
    }
}

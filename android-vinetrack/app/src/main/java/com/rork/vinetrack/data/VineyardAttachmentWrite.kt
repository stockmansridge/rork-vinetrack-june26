package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import io.ktor.client.request.HttpRequestBuilder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Capture before dispatcher suspension; each independent follow-up captures its own scope. */
internal suspend fun <T> vineyardAttachmentWrite(
    session: SessionStore,
    vineyardId: String,
    operation: suspend (MaintenanceWriteScope) -> T,
): T {
    val scope = MaintenanceWriteScope(session)
    scope.requireLocalWrite(vineyardId)
    return withContext(Dispatchers.IO) {
        val result = scope.send(vineyardId) { operation(scope) }
        scope.requireCurrent()
        result
    }
}

internal fun HttpRequestBuilder.attachmentScope(scope: MaintenanceWriteScope, vineyardId: String) {
    scope.requireLocalWrite(vineyardId)
    attributes.put(SupabaseClient.accountRequestScope, scope.account)
    attributes.put(SupabaseClient.operationalWriteVineyard, vineyardId)
}

internal fun attachmentVineyard(path: String): String {
    val parts = path.split('/')
    if (parts.size < 2 || parts.any { it.isBlank() || it == "." || it == ".." } ||
        path.contains('\\') || path.contains('%') || path.contains('?') || path.contains('#')) {
        throw VineyardWriteAuthority.Restricted("WRITE_SCOPE_UNRESOLVED")
    }
    MaintenanceWriteScope.requireUuid(parts.first())
    return parts.first().lowercase(java.util.Locale.ROOT)
}

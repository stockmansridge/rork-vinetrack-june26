package com.rork.vinetrack.data

import com.rork.vinetrack.data.auth.SessionStore
import com.rork.vinetrack.data.model.SampleSite
import com.rork.vinetrack.data.model.Paddock
import io.ktor.client.call.body
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.headers
import io.ktor.client.request.patch
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * Issue #54: separate yield fixed sample sets with server confirmation.
 * No use of Trip/Spray/Tank queues, no writes to general Permanent Items.
 * The canonical source for a trip is ONLY a confirmed set read back from
 * the authenticated Supabase endpoint, never an optimistic draft.
 */
@Serializable
data class YieldSiteSet(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("paddock_id") val paddockId: String,
    @SerialName("set_key") val setKey: String,
    val version: Int,
    val name: String,
    val status: String,
) {
    val isConfirmed get() = status == "confirmed"
}

@Serializable
data class YieldFixedSite(
    val id: String,
    @SerialName("site_set_id") val siteSetId: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("paddock_id") val paddockId: String,
    @SerialName("site_id") val siteId: String,
    @SerialName("site_number") val siteNumber: Int,
    val name: String,
    @SerialName("row_number") val rowNumber: String? = null,
    @SerialName("panel_number") val panelNumber: String? = null,
    val latitude: Double,
    val longitude: Double,
    val notes: String? = null,
)

data class ConfirmedYieldSites(val set: YieldSiteSet, val sites: List<YieldFixedSite>)

/** Immutable session snapshot independent of a future site move/revision. */
@Serializable
data class YieldSiteSetSource(
    val setKey: String,
    val siteSetId: String,
    val version: Int,
)

fun YieldFixedSite.toSampleSite(paddock: Paddock, globalIndex: Int): SampleSite {
    require(this.paddockId.equals(paddock.id, true))
    return SampleSite(
        id = siteId,
        paddockId = paddock.id,
        paddockName = paddock.name,
        rowNumber = rowNumber?.toIntOrNull() ?: 0,
        latitude = latitude,
        longitude = longitude,
        siteIndex = globalIndex,
        yieldRowReference = rowNumber,
        yieldPanelReference = panelNumber,
    )
}

class YieldSamplingSiteRepository(private val session: SessionStore) {
    private fun token(): String {
        if (!SupabaseClient.isConfigured) throw BackendError.NotConfigured
        return session.accessToken ?: throw BackendError.Unauthorized
    }
    private fun io.ktor.client.request.HttpRequestBuilder.auth(token: String) {
        headers {
            append("apikey", SupabaseClient.anonKey)
            append("Authorization", "Bearer $token")
        }
    }
    private fun fail(status: Int, reason: String): Nothing {
        if (status == 401 || status == 403) throw BackendError.Unauthorized
        throw BackendError.Server(status, reason)
    }

    suspend fun listSets(vineyard: String, paddock: String): List<YieldSiteSet> = withContext(Dispatchers.IO) {
        val t = token()
        val response = SupabaseClient.http.get(SupabaseClient.restUrl(
            "yield_sample_site_sets?select=id,vineyard_id,paddock_id,set_key,version,name,status&vineyard_id=eq.$vineyard&paddock_id=eq.$paddock&order=version.desc"
        )) { auth(t) }
        if (!response.status.isSuccess()) fail(response.status.value, response.bodyAsText())
        response.body<List<YieldSiteSet>>().also { rows ->
            check(rows.all { it.vineyardId.equals(vineyard, true) && it.paddockId.equals(paddock, true) })
        }
    }

    suspend fun listSites(set: YieldSiteSet): List<YieldFixedSite> = withContext(Dispatchers.IO) {
        val t = token()
        val response = SupabaseClient.http.get(SupabaseClient.restUrl(
            "yield_sample_sites?select=id,site_set_id,vineyard_id,paddock_id,site_id,site_number,name,row_number,panel_number,latitude,longitude,notes&site_set_id=eq.${set.id}&vineyard_id=eq.${set.vineyardId}&paddock_id=eq.${set.paddockId}&order=site_number.asc"
        )) { auth(t) }
        if (!response.status.isSuccess()) fail(response.status.value, response.bodyAsText())
        response.body<List<YieldFixedSite>>().also { rows ->
            check(rows.all { it.siteSetId.equals(set.id, true) &&
                it.vineyardId.equals(set.vineyardId, true) && it.paddockId.equals(set.paddockId, true) })
        }
    }

    suspend fun confirmed(vineyard: String, paddock: String): ConfirmedYieldSites? {
        val set = listSets(vineyard, paddock).firstOrNull { it.isConfirmed } ?: return null
        val sites = listSites(set)
        if (sites.isEmpty()) return null // Last confirmed site was hard-deleted.
        check(sites.all { it.siteNumber > 0 }) { "Confirmed set had invalid site readback." }
        return ConfirmedYieldSites(set, sites)
    }

    @Serializable
    private data class DraftInput(
        val id: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String,
        @SerialName("set_key") val setKey: String,
        val version: Int,
        val name: String,
        val status: String = "draft",
    )
    @Serializable
    private data class ConfirmArgs(
        @SerialName("p_set_id") val id: String,
        @SerialName("p_expected_version") val expectedVersion: Int,
    )
    @Serializable
    private data class SiteInput(
        val id: String,
        @SerialName("site_set_id") val siteSetId: String,
        @SerialName("vineyard_id") val vineyardId: String,
        @SerialName("paddock_id") val paddockId: String,
        @SerialName("site_id") val siteId: String,
        @SerialName("site_number") val siteNumber: Int,
        val name: String,
        @SerialName("row_number") val rowNumber: String?,
        @SerialName("panel_number") val panelNumber: String?,
        val latitude: Double,
        val longitude: Double,
        val notes: String?,
    ) {
        constructor(source: YieldFixedSite) : this(source.id, source.siteSetId,
            source.vineyardId, source.paddockId, source.siteId, source.siteNumber, source.name,
            source.rowNumber, source.panelNumber, source.latitude, source.longitude, source.notes)
    }

    suspend fun beginDraft(vineyard: String, paddock: String): YieldSiteSet = withContext(Dispatchers.IO) {
        val previous = listSets(vineyard, paddock)
        previous.firstOrNull { it.status == "draft" }?.let { return@withContext it }
        val confirmed = previous.firstOrNull { it.isConfirmed }
        val input = DraftInput(
            id = UUID.randomUUID().toString(),
            vineyardId = vineyard, paddockId = paddock,
            setKey = confirmed?.setKey ?: UUID.randomUUID().toString(),
            version = if (confirmed == null) 1 else (previous.filter { it.setKey == confirmed.setKey }.maxOfOrNull { it.version } ?: 0) + 1,
            name = confirmed?.name ?: "Permanent Yield Sampling Locations",
        )
        val t = token()
        val response = SupabaseClient.http.post(SupabaseClient.restUrl("yield_sample_site_sets")) {
            auth(t); headers { append("Prefer", "return=representation") }
            contentType(ContentType.Application.Json); setBody(listOf(input))
        }
        if (!response.status.isSuccess()) fail(response.status.value, response.bodyAsText())
        val draft = response.body<List<YieldSiteSet>>().single()
        check(draft.id.equals(input.id, true) && draft.status == "draft")
        if (confirmed != null) {
            val original = listSites(confirmed)
            if (original.isNotEmpty()) {
                val copies = original.map {
                    SiteInput(UUID.randomUUID().toString(), draft.id, vineyard, paddock,
                        it.siteId, it.siteNumber, it.name, it.rowNumber, it.panelNumber,
                        it.latitude, it.longitude, it.notes)
                }
                val copied = SupabaseClient.http.post(SupabaseClient.restUrl("yield_sample_sites")) {
                    auth(t); headers { append("Prefer", "return=representation") }
                    contentType(ContentType.Application.Json); setBody(copies)
                }
                if (!copied.status.isSuccess()) fail(copied.status.value, copied.bodyAsText())
                check(listSites(draft).size == original.size) { "Copied draft sites were not fully acknowledged." }
            }
        }
        draft
    }

    suspend fun saveSite(set: YieldSiteSet, row: YieldFixedSite): YieldFixedSite = withContext(Dispatchers.IO) {
        require(set.status == "draft" && row.siteSetId.equals(set.id, true)
            && row.vineyardId.equals(set.vineyardId, true)
            && row.paddockId.equals(set.paddockId, true)
            && row.siteNumber > 0 && row.latitude.isFinite() && row.longitude.isFinite()
            && row.latitude in -90.0..90.0 && row.longitude in -180.0..180.0)
        val t = token()
        val previous = listSites(set)
        val request = SiteInput(row)
        val response = if (previous.any { it.id.equals(row.id, true) }) {
            SupabaseClient.http.patch(SupabaseClient.restUrl(
                "yield_sample_sites?id=eq.${row.id}&site_set_id=eq.${set.id}"
            )) {
                auth(t); headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json); setBody(request)
            }
        } else {
            SupabaseClient.http.post(SupabaseClient.restUrl("yield_sample_sites")) {
                auth(t); headers { append("Prefer", "return=representation") }
                contentType(ContentType.Application.Json); setBody(listOf(request))
            }
        }
        if (!response.status.isSuccess()) fail(response.status.value, response.bodyAsText())
        val saved = response.body<List<YieldFixedSite>>().single()
        check(saved.id.equals(row.id, true) && saved.siteId.equals(row.siteId, true)
            && saved.latitude == row.latitude && saved.longitude == row.longitude)
        saved
    }

    @Serializable
    private data class SiteDeleteArgs(
        val p_id: String, val p_set_id: String, val p_vineyard_id: String, val p_expected_status: String,
    )
    @Serializable
    private data class SiteDeletionReceipt(
        val deleted_row_id: String, val site_set_id: String, val vineyard_id: String,
        val paddock_id: String, val site_id: String, val was_confirmed: Boolean,
    )

    suspend fun hardDeleteSite(set: YieldSiteSet, site: YieldFixedSite) = withContext(Dispatchers.IO) {
        require(set.status in listOf("draft", "confirmed") && site.siteSetId.equals(set.id, true)
            && site.vineyardId.equals(set.vineyardId, true) && site.paddockId.equals(set.paddockId, true))
        val t = token()
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("hard_delete_yield_sample_site")) {
            auth(t); contentType(ContentType.Application.Json)
            setBody(SiteDeleteArgs(site.id, set.id, set.vineyardId, set.status))
        }
        if (!response.status.isSuccess()) fail(response.status.value, response.bodyAsText())
        check(response.body<Boolean>()) { "Site deletion was not acknowledged." }
        val result = SupabaseClient.http.get(SupabaseClient.restUrl(
            "yield_sample_site_deletion_receipts?select=deleted_row_id,site_set_id,vineyard_id,paddock_id,site_id,was_confirmed" +
                "&deleted_row_id=eq.${site.id}&site_set_id=eq.${set.id}&vineyard_id=eq.${set.vineyardId}"
        )) { auth(t) }
        if (!result.status.isSuccess()) fail(result.status.value, result.bodyAsText())
        val receipt = result.body<List<SiteDeletionReceipt>>().singleOrNull()
        check(receipt != null && receipt.deleted_row_id.equals(site.id, true)
            && receipt.site_set_id.equals(set.id, true) && receipt.vineyard_id.equals(set.vineyardId, true)
            && receipt.paddock_id.equals(site.paddockId, true) && receipt.site_id.equals(site.siteId, true)
            && receipt.was_confirmed == set.isConfirmed
            && listSites(set).none { it.id.equals(site.id, true) }) { "Site receipt or absence could not be confirmed. Reload before retrying." }
    }

    suspend fun confirm(set: YieldSiteSet): ConfirmedYieldSites = withContext(Dispatchers.IO) {
        require(set.status == "draft" && listSites(set).isNotEmpty())
        val t = token()
        val response = SupabaseClient.http.post(SupabaseClient.rpcUrl("confirm_yield_sample_site_set")) {
            auth(t); contentType(ContentType.Application.Json)
            setBody(ConfirmArgs(set.id, set.version))
        }
        if (!response.status.isSuccess()) fail(response.status.value, response.bodyAsText())
        val verified = confirmed(set.vineyardId, set.paddockId)
            ?: throw IllegalStateException("Confirmation receipt missing from server.")
        check(verified.set.id.equals(set.id, true) && verified.set.version == set.version && verified.sites.isNotEmpty())
        verified
    }
}

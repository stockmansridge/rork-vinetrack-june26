package com.rork.vinetrack.data.spray

import io.ktor.client.HttpClient
import io.ktor.client.plugins.ResponseException
import io.ktor.client.request.post
import io.ktor.client.request.header
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.contentType

/** Captured credentials cannot be substituted by a switched account midway through an attempt. */
class SprayPlanningHTTPTransport(private val client: HttpClient, private val baseUrl: String,
    private val apiKey: String, private val capturedAccessToken: String) : SprayPlanningTransport {
    override suspend fun call(rpc: String, body: String): SprayPlanningTransport.Response {
        require(rpc in SprayPlanningProtocol.Kind.entries.map { it.rpc } +
            listOf("get_spray_planning_capability_v1", "get_spray_planning_recovery_v1"))
        val response = try { client.post("${baseUrl.trimEnd('/')}/rest/v1/rpc/$rpc") {
            header("Authorization", "Bearer $capturedAccessToken"); header("apikey", apiKey)
            contentType(ContentType.Application.Json); setBody(body)
        } } catch (error: ResponseException) { error.response }
        return SprayPlanningTransport.Response(response.status.value, response.bodyAsText())
    }
}

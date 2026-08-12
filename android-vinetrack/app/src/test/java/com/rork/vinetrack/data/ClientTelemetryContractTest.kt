package com.rork.vinetrack.data

import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Contract tests for the SQL 154 client telemetry heartbeat: canonical
 * app/platform values, exact RPC parameter names, manufacturer/model
 * formatting, and version/build passthrough.
 */
class ClientTelemetryContractTest {

    // ---- Device model formatting -------------------------------------

    @Test
    fun `samsung manufacturer is title-cased`() {
        assertEquals(
            "Samsung SM-S938B",
            ClientDeviceMetadata.formatModel("samsung", "SM-S938B"),
        )
    }

    @Test
    fun `manufacturer already in model is not duplicated`() {
        assertEquals(
            "Google Pixel 9 Pro",
            ClientDeviceMetadata.formatModel("google", "google Pixel 9 Pro"),
        )
        assertEquals(
            "Google Pixel 9 Pro",
            ClientDeviceMetadata.formatModel("Google", "Pixel 9 Pro"),
        )
    }

    @Test
    fun `missing pieces degrade gracefully`() {
        assertEquals("SM-S938B", ClientDeviceMetadata.formatModel(null, "SM-S938B"))
        assertEquals("Samsung", ClientDeviceMetadata.formatModel("samsung", ""))
        assertEquals("Android Device", ClientDeviceMetadata.formatModel(null, null))
        assertEquals("Android Device", ClientDeviceMetadata.formatModel("  ", "  "))
    }

    @Test
    fun `model is sanitised and length-limited like the server`() {
        val noisy = "sam\u0000sung" // embedded control character
        val formatted = ClientDeviceMetadata.formatModel(noisy, "SM-X\u0001900")
        assertFalse(formatted.any { it.isISOControl() })

        val long = ClientDeviceMetadata.formatModel("m".repeat(60), "x".repeat(60))
        assertTrue(long.length <= 80)
    }

    // ---- Heartbeat payload contract -----------------------------------

    @Test
    fun `payload uses exact rpc parameter names and canonical values`() {
        val body = ClientDeviceMetadata.buildHeartbeatPayload(
            clientInstanceId = "0e6f5f2a-1111-4222-8333-444455556666",
            deviceFamily = "Phone",
            deviceModel = "Samsung SM-S938B",
            osVersion = "16",
            appVersion = "2.6.4",
            appBuild = "264",
            vineyardId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        )

        assertEquals("android", body["p_app_type"]?.jsonPrimitive?.content)
        assertEquals("android", body["p_platform"]?.jsonPrimitive?.content)
        assertEquals("Phone", body["p_device_family"]?.jsonPrimitive?.content)
        assertEquals("Samsung SM-S938B", body["p_device_model"]?.jsonPrimitive?.content)
        assertEquals("Android", body["p_os_name"]?.jsonPrimitive?.content)
        assertEquals("16", body["p_os_version"]?.jsonPrimitive?.content)
        assertEquals("2.6.4", body["p_app_version"]?.jsonPrimitive?.content)
        assertEquals("264", body["p_app_build"]?.jsonPrimitive?.content)
        assertEquals(
            "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            body["p_vineyard_id"]?.jsonPrimitive?.content,
        )
        assertEquals(
            "0e6f5f2a-1111-4222-8333-444455556666",
            body["p_client_instance_id"]?.jsonPrimitive?.content,
        )

        // Nothing beyond the documented contract — no extra identifiers.
        val allowed = setOf(
            "p_client_instance_id", "p_app_type", "p_platform",
            "p_device_family", "p_device_model", "p_os_name", "p_os_version",
            "p_app_version", "p_app_build", "p_vineyard_id",
        )
        assertTrue(
            "unexpected telemetry fields: ${body.keys - allowed}",
            allowed.containsAll(body.keys),
        )
    }

    @Test
    fun `vineyard id is omitted entirely when none selected`() {
        val body = ClientDeviceMetadata.buildHeartbeatPayload(
            clientInstanceId = "0e6f5f2a-1111-4222-8333-444455556666",
            deviceFamily = "Tablet",
            deviceModel = "Samsung SM-X910",
            osVersion = "15",
            appVersion = "2.6.4",
            appBuild = "264",
            vineyardId = null,
        )
        assertNull(body["p_vineyard_id"])
        assertEquals("Tablet", body["p_device_family"]?.jsonPrimitive?.content)
    }
}

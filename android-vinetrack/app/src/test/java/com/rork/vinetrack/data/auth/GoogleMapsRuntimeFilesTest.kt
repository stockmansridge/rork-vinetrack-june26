package com.rork.vinetrack.data.auth

import org.junit.Assert.*
import org.junit.Test

class GoogleMapsRuntimeFilesTest {
    private val app = "com.rork.vinetrack"
    private val parameters = "DATA_ServerControlledParametersManager.data.v1.$app"

    @Test fun recognisesAllThreeObservedNames() {
        listOf(parameters, "SavedClientParameters.data.cs", "_m_t").forEach {
            assertTrue(GoogleMapsRuntimeFiles.recognises(it, app))
        }
    }
    @Test fun parameterCacheRequiresExactCurrentPackage() {
        assertFalse(GoogleMapsRuntimeFiles.recognises(parameters, "com.other.app"))
        assertFalse(GoogleMapsRuntimeFiles.recognises(parameters + ".other", app))
        assertFalse(GoogleMapsRuntimeFiles.recognises("DATA_ServerControlledParametersManager.data.v1.com.other.app", app))
    }
    @Test fun noBroadPrefixOrExtensionExemption() {
        listOf("DATA_private-work", "something.data.cs", "_m_private", "SavedClientParameters", "_m_t_extra").forEach {
            assertFalse(GoogleMapsRuntimeFiles.recognises(it, app))
        }
    }
    @Test fun backupAndReplacementNamesRemainUnknown() {
        listOf(parameters, "SavedClientParameters.data.cs", "_m_t").forEach { name ->
            listOf(".bak", ".new", ".tmp", "~").forEach { suffix ->
                assertFalse(GoogleMapsRuntimeFiles.recognises(name + suffix, app))
            }
        }
    }
    @Test fun caseChangesAreNotRecognised() {
        listOf(parameters.uppercase(), "savedclientparameters.data.cs", "_M_T").forEach {
            assertFalse(GoogleMapsRuntimeFiles.recognises(it, app))
        }
    }
    @Test fun pathsAndTraversalAreNotBasenames() {
        listOf("../_m_t", "files/_m_t", "/_m_t", "subdir/SavedClientParameters.data.cs", "_m_t/child").forEach {
            assertFalse(GoogleMapsRuntimeFiles.recognises(it, app))
        }
    }
    @Test fun invalidPackageInputIsRejected() {
        listOf("", "..", "com/other/app", "com.rork/../vinetrack", "com.rork.vinetrack\n", "com.rork.").forEach {
            assertFalse(GoogleMapsRuntimeFiles.recognises("_m_t", it))
        }
    }
    @Test fun fieldStoreAndPhotoNamesAreNotRuntimeFiles() {
        listOf("vinetrack_domain_cache.xml", "pending_pin_photos", "scout_photos", "field-isolation-v2",
            "pin_capture_evidence_recovery_v2.json", "maintenance-photo-evidence-v1", "private-note").forEach {
            assertFalse(GoogleMapsRuntimeFiles.recognises(it, app))
        }
    }
    @Test fun historicUnobservedParameterNamesAreNotSilentlyAdded() {
        assertFalse(GoogleMapsRuntimeFiles.recognises("DATA_ServerControlledParametersManager.data.$app", app))
        assertFalse(GoogleMapsRuntimeFiles.recognises("ZoomTables.data", app))
    }
}

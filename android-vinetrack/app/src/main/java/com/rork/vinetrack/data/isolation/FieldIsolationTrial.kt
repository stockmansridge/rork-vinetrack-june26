package com.rork.vinetrack.data.isolation

import java.io.File

/** Operator-safe condition: never includes business payloads, ownership guesses or raw exception text. */
internal sealed interface FieldBootstrapState {
    data object NotStarted : FieldBootstrapState
    data object PreservedNotActivated : FieldBootstrapState
    data class RecoveryRequired(val message: String =
        "Field data is retained but storage verification could not finish. Do not clear app storage, uninstall or sign out. Free unrelated storage and retry; contact support if verification still fails.") : FieldBootstrapState
}

/** Single entry for controlled fixtures. Not wired into MainActivity, AppViewModel or production repositories. */
internal class FieldIsolationTrial(
    private val vault: RawEvidenceVault,
    accountRoot: File,
    disk: IsolationDisk,
) {
    private val accounts = AccountEvidenceStore(accountRoot, disk)
    private var manifest: VaultManifest? = null
    var state: FieldBootstrapState = FieldBootstrapState.NotStarted
        private set

    @Synchronized
    fun bootstrap(): FieldBootstrapState {
        accounts.revoke()
        manifest = null
        state = try {
            manifest = vault.preserve()
            FieldBootstrapState.PreservedNotActivated
        } catch (_: Exception) {
            FieldBootstrapState.RecoveryRequired()
        }
        return state
    }

    /** The caller must supply an independently verified session; auth alone never adopts vault data. */
    @Synchronized
    fun acceptVerifiedSession(account: String, vineyards: Set<String>): FieldAccountCapability {
        check(state == FieldBootstrapState.PreservedNotActivated && manifest != null) { "Bootstrap verification required" }
        return accounts.authenticateVerifiedAccount(account, vineyards)
    }

    @Synchronized
    fun rejectOrSignOut() = accounts.revoke()

    @Synchronized
    fun append(capability: FieldAccountCapability, vineyard: String, collection: String, recordId: String,
               bytes: ByteArray, originalPhotoPath: String? = null): String {
        check(state == FieldBootstrapState.PreservedNotActivated)
        if (collection == "active-trip") {
            check(manifest?.entries?.none { it.source.contains("vinetrack_active_trip") } == true) {
                "Existing active-Trip evidence requires review; absence cannot be inferred from decode failure"
            }
        }
        return accounts.append(capability, vineyard, collection, recordId, bytes, originalPhotoPath)
    }

    @Synchronized
    fun read(capability: FieldAccountCapability, vineyard: String, collection: String): List<OwnedEvidence> =
        accounts.read(capability, vineyard, collection)

    @Synchronized
    fun acknowledge(capability: FieldAccountCapability, vineyard: String, collection: String, revision: String): Boolean =
        accounts.acknowledge(capability, vineyard, collection, revision)

    @Synchronized
    fun photoBytes(capability: FieldAccountCapability, vineyard: String, collection: String, revision: String,
                   originalPath: String): ByteArray? = accounts.photoBytes(capability, vineyard, collection, revision, originalPath)
}

package com.rork.vinetrack.data

import kotlinx.serialization.Serializable

/** App-private label photo retained independently of the Saved Chemical CREATE marker. */
@Serializable
data class ChemicalLabelAttachment(
    val id: String,
    val ownerId: String,
    val chemicalId: String,
    val vineyardId: String,
    val localPath: String,
    val remotePath: String,
    val createdAt: Long,
    val status: String = PENDING,
    val attempts: Int = 0,
    val lastError: String? = null,
) {
    companion object {
        const val PENDING = "pending"
        const val IN_PROGRESS = "in_progress"
        const val FAILED = "failed"
        const val BLOCKED = "blocked"
    }
}

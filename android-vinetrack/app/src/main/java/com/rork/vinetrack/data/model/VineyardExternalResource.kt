package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Directory identity only: no login account and no labour-rate authority. */
@Serializable
data class VineyardExternalResource(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    val name: String,
    val kind: String,
    @SerialName("contact_name") val contactName: String? = null,
    val phone: String? = null,
    val email: String? = null,
    val notes: String? = null,
    @SerialName("is_active") val isActive: Boolean = true,
    @SerialName("deleted_at") val deletedAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)

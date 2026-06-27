package com.rork.vinetrack.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Metadata row for a vineyard's custom E-L growth-stage reference image,
 * mirroring iOS `BackendGrowthStageImage` and the `vineyard_growth_stage_images`
 * table (sql/013). The actual JPEG lives in the private `vineyard-el-stage-images`
 * bucket at `{vineyard_id}/el-stages/{stage_code}.jpg`; this row records the
 * object [imagePath] plus soft-delete/versioning fields shared with iOS and the
 * Lovable portal.
 */
@Serializable
data class GrowthStageImage(
    val id: String,
    @SerialName("vineyard_id") val vineyardId: String,
    @SerialName("stage_code") val stageCode: String,
    @SerialName("image_path") val imagePath: String,
    @SerialName("created_by") val createdBy: String? = null,
    @SerialName("updated_by") val updatedBy: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("deleted_at") val deletedAt: String? = null,
    @SerialName("client_updated_at") val clientUpdatedAt: String? = null,
    @SerialName("sync_version") val syncVersion: Int? = null,
)

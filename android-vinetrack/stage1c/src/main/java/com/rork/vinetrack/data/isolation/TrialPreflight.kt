package com.rork.vinetrack.data.isolation

import kotlinx.serialization.Serializable

/** Independent workstation baseline; it is not an ownership adoption record. */
@Serializable
internal data class TrialSource(
    val path: String,
    val length: Long,
    val sha256: String,
    val mode: Int,
    val uid: Int,
    val gid: Int,
    val modifiedSeconds: Long,
    val accessedSeconds: Long,
    val changedSeconds: Long,
    val syntheticAccount: String,
    val families: Set<String>,
)

@Serializable
internal data class TrialReference(val metadataPath: String, val photoPath: String)

@Serializable
internal data class TrialExclusion(val path: String, val reason: String, val length: Long, val sha256: String)

@Serializable
internal data class TrialEvidence(val path: String, val sha256: String, val reviewedBy: String)

/** All evidence must be independently reviewed and pinned at build time. Missing values deny admission. */
@Serializable
internal data class TrialPreflight(
    val version: Int,
    val observedAtUtcMillis: Long,
    val validUntilUtcMillis: Long,
    val syntheticAccount: String,
    val syntheticOnly: Boolean,
    val noCredentialsOrProduction: Boolean,
    val normalWritersStopped: Boolean,
    val durableIdleBaseline: Boolean,
    val noActiveTrip: Boolean,
    val noOpenTank: Boolean,
    val noCaptureInFlight: Boolean,
    val noOperationInFlight: Boolean,
    val noUnresolvedOwnership: Boolean,
    val allDeviceRootsReviewed: Boolean,
    val sources: List<TrialSource>,
    val exclusions: List<TrialExclusion>,
    val references: List<TrialReference>,
    val evidence: Map<String, TrialEvidence>,
)

@Serializable
internal data class TrialReport(
    val status: String,
    val reason: String,
    val model: String,
    val androidRelease: String,
    val api: Int,
    val sourceDigest: String,
    val sourceBytes: Long = 0,
    val sourceCount: Int = 0,
    val manifestBudgetBytes: Long = 0,
    val scratchBudgetBytes: Long = 0,
    val reserveBytes: Long = 0,
    val requiredFreeBytes: Long = 0,
    val availableBytes: Long = 0,
    val elapsedMillis: Long = 0,
    val sampledPssKiB: Int = 0,
    val measurementNote: String = "Single PSS sample, not peak. Device trial not executed.",
)

package com.rork.vinetrack.data

/** Numeric evidence only. Callers never pass keys, owner IDs or vineyard contents. */
data class VineyardCacheTiming(
    val operation: String,
    val records: Int,
    val bytes: Int,
    val codecNanos: Long,
    val reused: Boolean,
    val changed: Boolean? = null,
)

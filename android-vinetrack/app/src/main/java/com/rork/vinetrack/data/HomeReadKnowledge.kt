package com.rork.vinetrack.data

/** Display provenance only. Never grants access, permits a write or controls Trip recovery. */
enum class HomeReadKnowledge {
    Unknown, Cached, Fresh;
    val isKnown: Boolean get() = this != Unknown
}

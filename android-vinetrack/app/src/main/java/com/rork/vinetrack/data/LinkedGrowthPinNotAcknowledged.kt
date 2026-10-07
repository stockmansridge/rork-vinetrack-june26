package com.rork.vinetrack.data

/** Dependency waiting is not a rejected Growth Stage write and must not consume retries. */
internal class LinkedGrowthPinNotAcknowledged : Exception("Waiting for the Growth Stage pin to sync.")

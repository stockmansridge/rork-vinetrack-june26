package com.rork.vinetrack.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.distinctUntilChanged

/**
 * Observes device connectivity via [ConnectivityManager.NetworkCallback] and
 * exposes it as a cold [Flow] of online/offline booleans.
 *
 * Read-only field-reliability plumbing (Stage 4A-i): this only reports whether
 * a validated internet-capable network is available. It does NOT queue, retry,
 * or alter any repository write — those remain online-first and unchanged.
 *
 * The flow emits the current status immediately on collection, then updates as
 * networks come and go. Callbacks are unregistered automatically when the
 * collector cancels (e.g. the ViewModel scope clears), so there are no leaks.
 */
class ConnectivityObserver(context: Context) {

    private val manager =
        context.applicationContext.getSystemService(ConnectivityManager::class.java)

    /** True when at least one network reports validated internet capability. */
    fun isCurrentlyOnline(): Boolean {
        val mgr = manager ?: return true // default safely to online when unknown
        val network = mgr.activeNetwork ?: return false
        val caps = mgr.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    /**
     * Cold flow of connectivity changes. Emits the current value on collection,
     * then tracks add/lose/capability events. Defaults to online until a real
     * status is known so the app never blocks startup on connectivity.
     */
    fun observe(): Flow<Boolean> = callbackFlow {
        val mgr = manager
        if (mgr == null) {
            trySend(true)
            awaitClose { }
            return@callbackFlow
        }

        // Track validated networks so we report online only while at least one
        // internet-capable network is present.
        val online = mutableSetOf<Network>()

        fun emit() {
            trySend(online.isNotEmpty())
        }

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                val usable = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                if (usable) online.add(network) else online.remove(network)
                emit()
            }

            override fun onLost(network: Network) {
                online.remove(network)
                emit()
            }

            override fun onUnavailable() {
                emit()
            }
        }

        // Seed the initial value before any callback fires.
        trySend(isCurrentlyOnline())

        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        try {
            mgr.registerNetworkCallback(request, callback)
        } catch (_: Exception) {
            // If registration fails for any reason, stay optimistically online.
            trySend(true)
        }

        awaitClose {
            runCatching { mgr.unregisterNetworkCallback(callback) }
        }
    }.distinctUntilChanged()
}

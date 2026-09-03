package com.rork.vinetrack.data.auth

/**
 * What the app should do about the local session after some event.
 *
 * Every automatic sign-out in VineTrack must be traceable to
 * [SessionDecision.SignOut] produced here, so the rules live in one pure,
 * testable place instead of being scattered across catch blocks.
 */
enum class SessionDecision {
    /** Keep the session; the backend is reachable and the credentials are good. */
    KeepOnline,

    /** Keep the session; the backend is unreachable. Work offline. */
    KeepOffline,

    /** Clear the local session and return to the login screen. */
    SignOut,
}

/**
 * Pure session-lifecycle rules.
 *
 * The single governing principle: **loss of connectivity is never loss of
 * authentication.** Only an explicit logout, or a server-confirmed rejection
 * of the stored credentials while that server is reachable, may sign a user
 * out.
 */
object SessionDecisions {

    /**
     * Decide what a [BackendError.Unauthorized]-style failure means.
     *
     * A 401/403 from a data request is not proof on its own: the same error is
     * produced by an RLS/permission denial and by a request that raced token
     * hydration. So we only sign out when a reachable auth server has
     * explicitly rejected the refresh token.
     *
     * @param isOnline whether the device currently has connectivity.
     * @param validity the answer from the auth server, or null when we did not
     *   ask because the device is known to be offline.
     */
    fun onUnauthorized(isOnline: Boolean, validity: SessionValidity?): SessionDecision = when {
        !isOnline -> SessionDecision.KeepOffline
        validity == SessionValidity.Rejected -> SessionDecision.SignOut
        validity == SessionValidity.Valid -> SessionDecision.KeepOnline
        // Unreachable, or we never got an answer.
        else -> SessionDecision.KeepOffline
    }

    /**
     * Phase to move to when connectivity flips. Only ever moves an already
     * authenticated user between online and offline; it can never sign anyone
     * out and never touches [SessionPhase.Restoring].
     */
    fun onConnectivityChange(current: SessionPhase, online: Boolean): SessionPhase = when {
        !current.isAuthenticated -> current
        online -> SessionPhase.AuthenticatedOnline
        else -> SessionPhase.AuthenticatedOffline
    }

    /**
     * Whether a transiently-null user may be treated as signed out. It may
     * not, while the session is still being restored — that null is a
     * hydration artefact, not an answer.
     */
    fun mayTreatNullUserAsSignedOut(phase: SessionPhase): Boolean = phase != SessionPhase.Restoring
}

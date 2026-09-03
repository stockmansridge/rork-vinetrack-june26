package com.rork.vinetrack.data.auth

/**
 * Explicit lifecycle of the local authentication session.
 *
 * Modelling this as four distinct states — rather than inferring "signed out"
 * from a transiently-null user — is what stops hydration races and network
 * failures from bouncing a field user to the login screen.
 *
 * Only [SignedOut] means the user must authenticate again, and it is only ever
 * reached by an explicit logout or a server-confirmed credential rejection.
 */
enum class SessionPhase {
    /**
     * Persisted tokens are being read/refreshed. Nothing about the user is
     * known yet, so NOTHING may treat a null user as "signed out" here.
     */
    Restoring,

    /** Session is valid and the backend is reachable. */
    AuthenticatedOnline,

    /**
     * Session is valid locally but the backend could not be reached (airplane
     * mode, DNS failure, timeout, Supabase down). The user keeps working
     * against the local database and outbox.
     */
    AuthenticatedOffline,

    /** No local session — explicit logout, or credentials definitively revoked. */
    SignedOut,
    ;

    /** True when the user may use the app (online or offline). */
    val isAuthenticated: Boolean
        get() = this == AuthenticatedOnline || this == AuthenticatedOffline
}

/**
 * Outcome of asking the server to confirm whether the stored session is still
 * valid. Deliberately three-valued: [Unreachable] must never be treated as a
 * rejection.
 */
enum class SessionValidity {
    /** Server answered and the session is good (or was refreshed). */
    Valid,

    /** Server answered and definitively rejected the stored credentials. */
    Rejected,

    /** Server could not be reached — say nothing about validity. */
    Unreachable,
}

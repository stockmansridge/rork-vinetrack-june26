package com.rork.vinetrack.data.auth

/** Fixed stage diagnostics only: no response bodies, identifiers, email, tokens or exception messages. */
class AuthRecoveryFailure(val stage: Stage) : IllegalStateException(stage.name) {
    enum class Stage(val guidance: String) {
        ORIGINAL_IDENTITY("The original sign-in identity is unavailable. Keep this installation and contact recovery support."),
        SIGN_IN("Sign-in was not completed. Check the original account credentials and connection, then try again."),
        IDENTITY("The verified original account is required. Sign in with that account; retained work has not been reassigned."),
        VINEYARD_ACCESS("Current vineyard access could not be confirmed for all retained data. Check your connection or ask your vineyard manager to review access."),
        RETAINED_EVIDENCE("Retained records or files could not be attributed safely. Keep this installation and contact recovery support. Do not clear app storage."),
        PERSISTENCE("The restored session could not be saved on this device. Local work remains protected. Check device storage and retry."),
        IN_FLIGHT("An earlier operation is still finishing or this request is obsolete. Wait briefly and try again."),
        UNEXPECTED("Recovery could not be completed. Keep this installation and contact recovery support."),
    }
    val userMessage: String get() = "${stage.guidance} Recovery stage: ${stage.name}."
}

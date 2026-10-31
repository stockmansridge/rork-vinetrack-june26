package com.rork.vinetrack.ui.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.rork.vinetrack.data.auth.AuthRecoveryRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Recovery stays pre-business until original identity, current access and every retained dependency pass. */
class ProtectedWorkRecoveryViewModel internal constructor(
    private val verifyAccount: suspend (String, String) -> Unit,
) : ViewModel() {
    constructor(context: android.content.Context) : this({ email, password ->
        check(AuthRecoveryRepository().recover(com.rork.vinetrack.data.auth.SessionStore(context), email, password)) {
            "Retained work needs further ownership review."
        }
    }) {
        diagnosticProvider = {
            val session = com.rork.vinetrack.data.auth.SessionStore(context.applicationContext)
            session.retentionGuard.serialized {
                val inspector = com.rork.vinetrack.data.auth.AccountTransitionEvidence(context.applicationContext)
                if (session.retentionGuard.isLocked) inspector.inspect(session.recoveryPrincipal)
                inspector.failureDiagnostic
            }
        }
    }
    private var diagnosticProvider: (() -> com.rork.vinetrack.data.auth.RecoveryEvidenceDiagnostic?)? = null
    private var lastFailure: com.rork.vinetrack.data.auth.AuthRecoveryFailure? = null
    private val mutableState = MutableStateFlow(RecoveryUiState())
    val state = mutableState.asStateFlow()

    fun copyDiagnostics(copy: (String) -> Unit) {
        if (mutableState.value.isBusy) return
        viewModelScope.launch {
            val failure = lastFailure
            val evidence = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                failure?.evidence ?: runCatching { diagnosticProvider?.invoke() }.getOrNull()
            }
            copy(com.rork.vinetrack.data.auth.RecoveryDiagnostics.format(failure?.stage?.name ?: "LOCKED", evidence))
        }
    }

    fun verify(email: String, password: String) {
        if (mutableState.value.isBusy) return
        lastFailure = null
        mutableState.value = RecoveryUiState(isBusy = true)
        viewModelScope.launch {
            try {
                verifyAccount(email, password)
                mutableState.value = RecoveryUiState(message = "Original account restored. Returning to vineyard access; existing field records were preserved.")
            } catch (cancelled: CancellationException) {
                mutableState.value = RecoveryUiState()
                throw cancelled
            } catch (failure: com.rork.vinetrack.data.auth.AuthRecoveryFailure) {
                lastFailure = failure
                mutableState.value = RecoveryUiState(message = failure.userMessage)
            } catch (_: Exception) {
                mutableState.value = RecoveryUiState(message = com.rork.vinetrack.data.auth.AuthRecoveryFailure(
                    com.rork.vinetrack.data.auth.AuthRecoveryFailure.Stage.UNEXPECTED,
                ).userMessage)
            }
        }
    }
}

package com.rork.vinetrack.ui.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.rork.vinetrack.data.auth.AuthRecoveryRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** Recovery authentication is isolated from normal login and cannot unlock retained work. */
class ProtectedWorkRecoveryViewModel internal constructor(
    private val verifyAccount: suspend (String, String) -> Unit,
) : ViewModel() {
    constructor() : this({ email, password -> AuthRecoveryRepository().verify(email, password) })
    private val mutableState = MutableStateFlow(RecoveryUiState())
    val state = mutableState.asStateFlow()

    fun verify(email: String, password: String) {
        if (mutableState.value.isBusy) return
        mutableState.value = RecoveryUiState(isBusy = true)
        viewModelScope.launch {
            try {
                verifyAccount(email, password)
                mutableState.value = RecoveryUiState(message = "Account verified. Local work is still protected. Support must verify the original ownership of retained work before access can be restored.")
            } catch (cancelled: CancellationException) {
                mutableState.value = RecoveryUiState()
                throw cancelled
            } catch (_: Exception) {
                mutableState.value = RecoveryUiState(message = "Couldn't verify the account. Check your credentials and connection, then retry. Local work remains protected.")
            }
        }
    }
}

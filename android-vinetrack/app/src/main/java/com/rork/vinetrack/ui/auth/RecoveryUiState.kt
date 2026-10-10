package com.rork.vinetrack.ui.auth

/** Contains no account identity, credential, business data or unlock state. */
data class RecoveryUiState(val isBusy: Boolean = false, val message: String? = null)

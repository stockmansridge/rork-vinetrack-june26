package com.rork.vinetrack.ui.auth

import android.app.Application
import android.os.Bundle
import androidx.lifecycle.HasDefaultViewModelProviderFactory
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.SAVED_STATE_REGISTRY_OWNER_KEY
import androidx.lifecycle.SavedStateViewModelFactory
import androidx.lifecycle.VIEW_MODEL_STORE_OWNER_KEY
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.enableSavedStateHandles
import androidx.lifecycle.viewmodel.CreationExtras
import androidx.lifecycle.viewmodel.MutableCreationExtras
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner

/** Account-incarnation UI lifetime. Saved handles survive recreation, never another account exit. */
internal class AccountViewModelOwner(application: Application, restored: Bundle? = null) :
    ViewModelStoreOwner, SavedStateRegistryOwner, HasDefaultViewModelProviderFactory {
    override val viewModelStore = ViewModelStore()
    private val registry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = registry
    private val controller = SavedStateRegistryController.create(this)
    override val savedStateRegistry: SavedStateRegistry get() = controller.savedStateRegistry
    override val defaultViewModelProviderFactory: ViewModelProvider.Factory = SavedStateViewModelFactory(application, this)
    override val defaultViewModelCreationExtras: CreationExtras = MutableCreationExtras().apply {
        set(ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY, application)
        set(SAVED_STATE_REGISTRY_OWNER_KEY, this@AccountViewModelOwner)
        set(VIEW_MODEL_STORE_OWNER_KEY, this@AccountViewModelOwner)
    }

    init {
        controller.performAttach()
        enableSavedStateHandles()
        controller.performRestore(restored)
        registry.currentState = Lifecycle.State.CREATED
    }

    fun moveTo(state: Lifecycle.State) {
        if (registry.currentState != Lifecycle.State.DESTROYED) registry.currentState = state
    }

    fun save(): Bundle = Bundle().also(controller::performSave)

    fun close() {
        registry.currentState = Lifecycle.State.DESTROYED
        viewModelStore.clear()
    }
}

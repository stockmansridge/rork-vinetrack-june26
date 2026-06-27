package com.rork.vinetrack

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.getValue
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rork.vinetrack.data.AppConfig
import com.rork.vinetrack.data.AppPreferencesStore
import com.rork.vinetrack.data.DisplayMode
import com.rork.vinetrack.ui.RootScreen
import com.rork.vinetrack.ui.theme.AppTheme

class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppConfig.logDiagnostics()
        AppPreferencesStore.seedDisplayMode(this)
        enableEdgeToEdge()
        setContent {
            val displayMode by AppPreferencesStore.displayModeFlow.collectAsStateWithLifecycle()
            val darkTheme = when (displayMode) {
                DisplayMode.System -> isSystemInDarkTheme()
                DisplayMode.Light -> false
                DisplayMode.Dark -> true
            }
            AppTheme(darkTheme = darkTheme) {
                RootScreen()
            }
        }
    }
}

package com.rork.vinetrack

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.getValue
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.rork.vinetrack.data.AppConfig
import com.rork.vinetrack.data.AppPreferencesStore
import com.rork.vinetrack.data.DisplayMode
import com.rork.vinetrack.data.chemical.MasterFrontLabelRepository
import com.rork.vinetrack.ui.RootScreen
import com.rork.vinetrack.ui.theme.AppTheme

class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            setRecentsScreenshotEnabled(false)
        }
        MasterFrontLabelRepository.initialize(applicationContext)
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

    override fun onUserLeaveHint() {
        // Protect older task snapshots before a user-initiated background transition.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        super.onUserLeaveHint()
    }

    override fun onPause() {
        // Also cover interruptions that do not deliver onUserLeaveHint.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        super.onPause()
    }

    override fun onResume() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        super.onResume()
    }
}

package com.rork.vinetrack.ui.components

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.core.content.FileProvider
import androidx.compose.ui.platform.LocalContext
import java.io.File
import java.util.UUID

/** Camera and gallery launchers that keep the output target stable across recreation. */
data class PhotoCaptureCoordinator(
    val takePhoto: () -> Unit,
    val chooseFromGallery: () -> Unit,
)

@Composable
fun rememberPhotoCaptureCoordinator(
    onPhoto: (Uri?) -> Unit,
    onError: (String) -> Unit,
): PhotoCaptureCoordinator {
    val context = LocalContext.current
    val currentOnPhoto by rememberUpdatedState(onPhoto)
    val currentOnError by rememberUpdatedState(onError)
    var pendingPath by rememberSaveable { mutableStateOf<String?>(null) }

    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { saved ->
        val path = pendingPath
        pendingPath = null
        val file = path?.let(::File)
        if (saved && file?.exists() == true && file.length() > 0L) {
            currentOnPhoto(FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file))
        } else {
            file?.delete()
            if (saved) currentOnError("The camera didn't return a readable photo.")
        }
    }
    val gallery = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) currentOnPhoto(uri)
    }

    return remember(context, camera, gallery) {
        PhotoCaptureCoordinator(
            takePhoto = {
                try {
                    val directory = File(context.cacheDir, "camera-captures").apply { mkdirs() }
                    val file = File(directory, "capture-${UUID.randomUUID()}.jpg")
                    pendingPath = file.absolutePath
                    val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
                    camera.launch(uri)
                } catch (_: Exception) {
                    pendingPath?.let(::File)?.delete()
                    pendingPath = null
                    currentOnError("No camera app is available on this device.")
                }
            },
            chooseFromGallery = {
                gallery.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            },
        )
    }
}

package com.rork.vinetrack.ui.components

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.compose.ui.platform.LocalContext
import com.rork.vinetrack.data.auth.PhotoCaptureReceipt
import java.io.File
import java.io.RandomAccessFile
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Camera and gallery launchers retain their initiating authority until durable photo acknowledgement. */
data class PhotoCaptureCoordinator(val takePhoto: () -> Unit, val chooseFromGallery: () -> Unit)

@Composable
fun rememberPhotoCaptureCoordinator(
    onPhoto: (Uri?, PhotoCaptureReceipt?) -> Unit,
    onError: (String) -> Unit,
): PhotoCaptureCoordinator {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val currentOnPhoto by rememberUpdatedState(onPhoto)
    val currentOnError by rememberUpdatedState(onError)
    var acquisitionId by rememberSaveable { mutableStateOf<String?>(null) }
    // Older saved paths have no acquisition authority. Preserve them rather than adopt or delete them.
    var pendingPath by rememberSaveable { mutableStateOf<String?>(null) }
    val retainedMessage = "The photograph is retained but its save is unfinished or account access changed. Do not clear app storage."

    fun receipt(): PhotoCaptureReceipt? = acquisitionId?.let { PhotoCaptureReceipt.restore(context, it) }
    fun uri(file: File): Uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
    fun deliver(capture: PhotoCaptureReceipt) {
        if (!capture.admitted { currentOnPhoto(uri(File(capture.path)), capture) }) currentOnError(retainedMessage)
        acquisitionId = null
        pendingPath = null
    }
    fun cancel(capture: PhotoCaptureReceipt?) {
        if (capture?.cancelIfEmpty() == true) {
            acquisitionId = null; pendingPath = null
            currentOnPhoto(null, null)
        } else currentOnError(retainedMessage)
    }
    fun begin(kind: String): PhotoCaptureReceipt? {
        if (acquisitionId != null || pendingPath != null) {
            currentOnError(retainedMessage); return null
        }
        return try {
            PhotoCaptureReceipt.begin(context, kind)?.also {
                acquisitionId = it.id; pendingPath = it.path
            } ?: run { currentOnError("Couldn't durably start the photograph. Try again before leaving."); null }
        } catch (_: Exception) {
            currentOnError("Couldn't durably start the photograph. Try again before leaving."); null
        }
    }

    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { saved ->
        val capture = receipt()
        if (capture == null) currentOnError(retainedMessage)
        else if (!saved) cancel(capture)
        else scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    check(capture.admitted {
                        val file = File(capture.path)
                        check(file.isFile && file.length() > 0)
                        RandomAccessFile(file, "rw").use { it.fd.sync() }
                    })
                }
                deliver(capture)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { currentOnError(retainedMessage) }
        }
    }
    val gallery = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { source ->
        val capture = receipt()
        if (capture == null) currentOnError(retainedMessage)
        else if (source == null) cancel(capture)
        else if (!capture.recordExternalSource(source.toString())) currentOnError(retainedMessage)
        else scope.launch {
            try {
                runCatching { context.contentResolver.takePersistableUriPermission(source, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                withContext(Dispatchers.IO) {
                    check(capture.admitted {
                        // Never let a temporary external URI escape as the only retained evidence.
                        context.contentResolver.openInputStream(source).use { input ->
                            checkNotNull(input)
                            File(capture.path).outputStream().use { output -> input.copyTo(output); output.fd.sync() }
                        }
                        check(File(capture.path).length() > 0)
                    })
                }
                deliver(capture)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { currentOnError(retainedMessage) }
        }
    }
    val launchCamera: () -> Unit = {
        val capture = receipt()
        if (capture == null) currentOnError(retainedMessage)
        else try {
            if (!capture.admitted { camera.launch(uri(File(capture.path))) }) currentOnError(retainedMessage)
        } catch (_: Exception) {
            cancel(capture)
            currentOnError("The camera could not be opened. Any returned photograph has been retained.")
        }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) launchCamera() else {
            cancel(receipt())
            currentOnError("Camera permission is required to take photographs.")
        }
    }

    return PhotoCaptureCoordinator(
        takePhoto = {
            begin("camera")?.let { capture ->
                try {
                    if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) launchCamera()
                    else if (!capture.admitted { permission.launch(Manifest.permission.CAMERA) }) currentOnError(retainedMessage)
                } catch (_: Exception) { cancel(capture); currentOnError("The camera could not be opened.") }
            }
        },
        chooseFromGallery = {
            begin("gallery")?.let { capture ->
                try {
                    if (!capture.admitted { gallery.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) currentOnError(retainedMessage)
                } catch (_: Exception) { cancel(capture); currentOnError("The gallery could not be opened.") }
            }
        },
    )
}

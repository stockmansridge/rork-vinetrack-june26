package com.rork.vinetrack.ui.components

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ImageNotSupported
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import com.rork.vinetrack.data.chemical.MasterFrontLabel
import com.rork.vinetrack.data.chemical.MasterFrontLabelRepository

/** Immutable version path is the cache key; a new PDF hash can never reuse an old bitmap. */
private val imageCache = LruCache<String, Bitmap>(48)

@Composable
fun MasterFrontLabelThumbnail(media: MasterFrontLabel?, modifier: Modifier = Modifier, expanded: Boolean = false, interactive: Boolean = true) {
    var thumb by remember(media?.thumbnailPath) { mutableStateOf<Bitmap?>(null) }
    var full by remember(media?.fullImagePath) { mutableStateOf<Bitmap?>(null) }
    var showing by remember { mutableStateOf(false) }
    val uriHandler = LocalUriHandler.current
    LaunchedEffect(media?.thumbnailPath) {
        thumb = null
        val path = media?.thumbnailPath ?: return@LaunchedEffect
        thumb = imageCache.get(path) ?: runCatching {
            MasterFrontLabelRepository().image(path, thumbnail = true)?.let { bytes ->
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.also {
                    imageCache.put(path, it)
                }
            }
        }.getOrNull()
    }
    val frame = modifier.width(if (expanded) 130.dp else 48.dp).height(if (expanded) 130.dp else 56.dp)
        .background(MaterialTheme.colorScheme.surfaceVariant)
        .then(if (media != null && interactive) Modifier.clickable { showing = true } else Modifier)
    if (thumb != null) {
        Image(bitmap = thumb!!.asImageBitmap(), contentDescription = "Confirmed front label thumbnail",
            modifier = frame, contentScale = ContentScale.Fit)
    } else {
        Icon(Icons.Filled.ImageNotSupported, contentDescription = "No confirmed front label", modifier = frame.padding(10.dp))
    }
    if (showing && media != null) {
        LaunchedEffect(media.fullImagePath) {
            full = null
            full = runCatching {
                MasterFrontLabelRepository().image(media.fullImagePath)?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
            }.getOrNull()
        }
        AlertDialog(onDismissRequest = { showing = false }, title = { Text("Front label") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (full != null) Image(bitmap = full!!.asImageBitmap(), contentDescription = "Full confirmed front label",
                        modifier = Modifier.height(320.dp), contentScale = ContentScale.Fit)
                    else Text("Image unavailable. The chemical is still available.")
                    Text("Identification aid only. Offline copies reflect the last approved version seen on this device; check the complete label for current directions.")
                    Text("${media.registrationIdentityKey} · ${media.documentVersion.orEmpty()}")
                    TextButton(onClick = { runCatching { uriHandler.openUri(media.sourceUrl) } }) { Text("View Full Label") }
                }
            }, confirmButton = { TextButton(onClick = { showing = false }) { Text("Done") } })
    }
}

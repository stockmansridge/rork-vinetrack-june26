package com.rork.vinetrack.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import androidx.exifinterface.media.ExifInterface
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

/**
 * Reads a picked image [Uri], corrects EXIF orientation, scales it to a max
 * edge and compresses to JPEG — mirroring the iOS `PinPhotoStorage.compress`
 * (max edge 1600 px, quality ~0.8) so all clients upload comparably sized
 * images.
 */
object PinPhotoImageUtil {

    private const val MAX_EDGE = 1600
    private const val QUALITY = 80

    suspend fun compress(context: Context, uri: Uri): ByteArray = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val original = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
            ?: throw IllegalStateException("Couldn't read the selected image.")

        val rotation = resolver.openInputStream(uri)?.use { stream ->
            when (ExifInterface(stream).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                else -> 0f
            }
        } ?: 0f

        val rotated = if (rotation != 0f) {
            val m = Matrix().apply { postRotate(rotation) }
            Bitmap.createBitmap(original, 0, 0, original.width, original.height, m, true)
        } else {
            original
        }

        val w = rotated.width
        val h = rotated.height
        val maxDim = maxOf(w, h)
        val scale = if (maxDim > MAX_EDGE) MAX_EDGE.toFloat() / maxDim else 1f
        val resized = if (scale < 1f) {
            Bitmap.createScaledBitmap(rotated, (w * scale).toInt(), (h * scale).toInt(), true)
        } else {
            rotated
        }

        ByteArrayOutputStream().use { out ->
            resized.compress(Bitmap.CompressFormat.JPEG, QUALITY, out)
            out.toByteArray()
        }
    }
}

package com.rork.vinetrack.data

import android.util.AtomicFile
import com.rork.vinetrack.data.model.PendingPhotoAttachment
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.security.MessageDigest
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** A single durable envelope tracks the original attachment AND bytes before either is published. */
internal class PendingPhotoCaptureJournal(private val directory: File) {
    @Serializable
    private data class Header(val ownerUserId: String?, val identityEpoch: Long, val attachment: PendingPhotoAttachment, val sha256: String)
    internal data class Capture(val ownerUserId: String?, val identityEpoch: Long, val attachment: PendingPhotoAttachment, val jpeg: ByteArray)
    private val json = Json { encodeDefaults = true }

    fun retain(ownerUserId: String?, identityEpoch: Long, attachment: PendingPhotoAttachment, jpeg: ByteArray): File {
        val file = File(directory, "${attachment.revision}.capture")
        val header = json.encodeToString(Header(ownerUserId, identityEpoch, attachment, digest(jpeg))).encodeToByteArray()
        val atomic = AtomicFile(file)
        val stream = atomic.startWrite()
        try {
            val output = DataOutputStream(stream)
            output.writeInt(header.size)
            output.write(header)
            output.writeInt(jpeg.size)
            output.write(jpeg)
            output.flush()
            stream.fd.sync()
            atomic.finishWrite(stream)
            check(file.isFile && file.length() == 8L + header.size + jpeg.size) { "Photo intent was not durably published." }
            syncDirectory()
        } catch (failure: Throwable) {
            atomic.failWrite(stream)
            throw failure
        }
        return file
    }

    fun pending(): List<Pair<File, Capture>> {
        if (!directory.exists()) return emptyList()
        val files = requireNotNull(directory.listFiles()) { "Retained photo intents couldn't be inspected." }
        check(files.none { it.name.endsWith(".capture.new") && !File(directory, it.name.removeSuffix(".new")).exists() }) {
            "An interrupted photo intent needs storage review. Its bytes remain protected."
        }
        val bases = files.filter { it.name.endsWith(".capture") || it.name.endsWith(".capture.bak") }
            .map { File(directory, it.name.removeSuffix(".bak")) }.distinct()
        return bases.map { file ->
            val capture = DataInputStream(AtomicFile(file).openRead()).use { input ->
                val headerSize = input.readInt()
                check(headerSize in 1..1_048_576)
                val headerBytes = ByteArray(headerSize).also(input::readFully)
                val header = json.decodeFromString<Header>(headerBytes.decodeToString())
                val size = input.readInt()
                check(size in 1..20_971_520)
                val jpeg = ByteArray(size).also(input::readFully)
                check(input.read() == -1 && digest(jpeg) == header.sha256)
                check(file.name == "${header.attachment.revision}.capture")
                check(File(header.attachment.localPath).canonicalFile.parentFile == directory.canonicalFile)
                Capture(header.ownerUserId, header.identityEpoch, header.attachment, jpeg)
            }
            file to capture
        }.sortedBy { it.second.attachment.createdAt }
    }

    fun finish(file: File) {
        AtomicFile(file).delete()
        syncDirectory()
    }

    fun writeJpeg(file: File, jpeg: ByteArray) {
        val atomic = AtomicFile(file)
        val stream = atomic.startWrite()
        try {
            stream.write(jpeg)
            stream.fd.sync()
            atomic.finishWrite(stream)
            check(file.isFile && file.readBytes().contentEquals(jpeg)) { "Photo bytes were not durably published. The capture intent remains protected." }
            syncDirectory()
        } catch (failure: Throwable) {
            atomic.failWrite(stream)
            throw failure
        }
    }

    private fun syncDirectory() {
        val descriptor = android.system.Os.open(directory.absolutePath, android.system.OsConstants.O_RDONLY, 0)
        try { android.system.Os.fsync(descriptor) } finally { android.system.Os.close(descriptor) }
    }

    private fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it) }
}

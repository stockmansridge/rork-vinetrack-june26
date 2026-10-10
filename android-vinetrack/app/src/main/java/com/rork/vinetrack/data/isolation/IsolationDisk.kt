package com.rork.vinetrack.data.isolation

import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.security.MessageDigest

/** Durable immutable publication. Directory synchronization is supplied by the platform. */
internal class IsolationDisk(
    private val syncDirectory: (File) -> Unit,
    private val checkpoint: (String) -> Unit = {},
) {
    fun directory(file: File) {
        check(file.absoluteFile == file.canonicalFile) { "Linked protected directory" }
        if (file.isDirectory) return
        val parent = requireNotNull(file.parentFile)
        directory(parent)
        check(file.mkdir()) { "Cannot create protected storage" }
        syncDirectory(parent)
        syncDirectory(file)
    }

    fun <T> locked(root: File, action: () -> T): T {
        directory(root)
        return RandomAccessFile(File(root, "storage.lock"), "rw").use { handle ->
            handle.channel.lock().use { action() }
        }
    }

    /** Existing committed files are never overwritten, even when unreadable. */
    fun publish(file: File, write: (FileOutputStream) -> Unit) {
        check(!file.exists()) { "Protected evidence already exists" }
        val parent = requireNotNull(file.parentFile)
        directory(parent)
        val partial = File(parent, "${file.name}.partial")
        check(partial.absoluteFile == partial.canonicalFile) { "Linked partial evidence" }
        FileOutputStream(partial).use { output ->
            write(output)
            checkpoint("before-file-sync:${file.name}")
            output.fd.sync()
        }
        checkpoint("before-rename:${file.name}")
        check(partial.renameTo(file)) { "Cannot publish protected evidence" }
        checkpoint("after-rename:${file.name}")
        syncDirectory(parent)
        checkpoint("after-directory-sync:${file.name}")
    }

    fun publishBytes(file: File, bytes: ByteArray) = publish(file) { it.write(bytes) }

    fun verify(file: File, length: Long, hash: String) {
        check(file.absoluteFile == file.canonicalFile && file.isFile && file.length() == length && digest(file) == hash) { "Protected evidence verification failed" }
    }

    /** Re-establish durability after an interrupted rename; readback alone is not a durable commit. */
    fun confirmPublished(file: File) {
        check(file.absoluteFile == file.canonicalFile && file.isFile)
        RandomAccessFile(file, "rw").use { it.fd.sync() }
        syncDirectory(requireNotNull(file.parentFile))
    }

    companion object {
        fun digest(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
        }

        fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
            .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    }
}

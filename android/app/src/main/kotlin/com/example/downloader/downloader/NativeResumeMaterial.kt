package com.example.downloader.downloader

import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardOpenOption.READ
import java.security.MessageDigest

/** A separate algorithm, NOT the ordinary file SHA256. Bounded 64KiB tail, no provider clone. */
internal class NativePrefixDigest {
    private var chain = hash("downloader/native-prefix/v1/seed".toByteArray())
    private val block = ByteArray(BLOCK)
    private var used = 0
    private var blocks = 0L
    var length = 0L
        private set

    fun update(
        bytes: ByteArray,
        count: Int,
    ) {
        require(count in 0..bytes.size)
        length = Math.addExact(length, count.toLong())
        var offset = 0
        while (offset < count) {
            val take = minOf(count - offset, BLOCK - used)
            bytes.copyInto(block, used, offset, offset + take)
            used += take
            offset += take
            if (used == BLOCK) {
                chain = digest("downloader/native-prefix/v1/block", chain, blocks, block, used)
                blocks = Math.addExact(blocks, 1)
                used = 0
            }
        }
    }

    fun snapshot(): String = digest("downloader/native-prefix/v1/end", chain, length, block, used).joinToString("") { "%02x".format(it) }

    companion object {
        const val ALGORITHM = "native-prefix-v1-65536"
        const val BLOCK = 65536

        private fun hash(value: ByteArray) = MessageDigest.getInstance("SHA-256").digest(value)

        private fun digest(
            domain: String,
            chain: ByteArray,
            index: Long,
            tail: ByteArray,
            size: Int,
        ): ByteArray {
            val digest = MessageDigest.getInstance("SHA-256")
            digest.update(domain.toByteArray(Charsets.US_ASCII))
            digest.update(0.toByte())
            digest.update(chain)
            digest.update(
                ByteBuffer
                    .allocate(12)
                    .putLong(index)
                    .putInt(size)
                    .array(),
            )
            digest.update(tail, 0, size)
            return digest.digest()
        }

        fun read(
            source: File,
            offset: Long,
            consume: (ByteArray, Int) -> Unit = { _, _ -> },
        ): NativePrefixDigest {
            if (offset < 0) conflict("restartRequired")
            val digest = NativePrefixDigest()
            FileChannel.open(source.toPath(), READ, NOFOLLOW_LINKS).use { input ->
                if (input.size() < offset) conflict("restartRequired")
                val bytes = ByteArray(BLOCK)
                while (digest.length < offset) {
                    val count = input.read(ByteBuffer.wrap(bytes, 0, minOf(BLOCK.toLong(), offset - digest.length).toInt()))
                    if (count <= 0) conflict("restartRequired")
                    digest.update(bytes, count)
                    consume(bytes, count)
                }
            }
            return digest
        }
    }
}

/** Draft emitted only AFTER force, never from progress samples. Journal supplies command/version. */
internal data class ForcedMaterial(
    val key: ExecutionKey,
    val source: File,
    val offset: Long,
    val total: Long?,
    val effectiveUrl: String,
    val etag: String,
    val prefixDigest: String,
    val algorithm: String = NativePrefixDigest.ALGORITHM,
)

internal data class NativeResumeMaterial(
    val ref: String,
    val commandId: String,
    val receiptVersion: Long,
    val forced: ForcedMaterial,
)

internal object NativeMaterialPaths {
    fun validate(
        root: File,
        source: File,
        mustExist: Boolean = true,
    ) {
        val directory = File(root, "http_staging_v1")
        if (root != root.canonicalFile || directory != directory.canonicalFile || !directory.isDirectory ||
            Files.isSymbolicLink(directory.toPath()) || source.absoluteFile.parentFile != directory ||
            source != source.canonicalFile || Files.isSymbolicLink(source.toPath()) ||
            !source.name.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.part")) ||
            (mustExist && (!source.isFile || !Files.isRegularFile(source.toPath(), NOFOLLOW_LINKS))) ||
            (!mustExist && source.exists())
        ) {
            conflict("restartRequired")
        }
    }

    fun strongEtag(value: String?): Boolean =
        value != null && value.length >= 2 && value.first() == '"' && value.last() == '"' &&
            value.substring(1, value.length - 1).all { it.code == 0x21 || it.code in 0x23..0x7e || it.code in 0x80..0xff }
}

/** Candidate branch evidence, deliberately distinct from the currently authorized source proof. */
internal data class CandidateCheckpoint(
    val operationId: String,
    val resumeCommandId: String,
    val sourceRef: String,
    val sourceReceiptVersion: Long,
    val receiptVersion: Long,
    val forced: ForcedMaterial,
)

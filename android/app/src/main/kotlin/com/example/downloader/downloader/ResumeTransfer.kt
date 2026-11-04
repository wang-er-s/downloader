package com.example.downloader.downloader

import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardOpenOption.CREATE_NEW
import java.nio.file.StandardOpenOption.WRITE
import java.security.MessageDigest
import java.util.UUID

/** Internal explicit recovery core. Not reachable from public resume until coordinator authorization closes. */
internal class ResumeTransfer(
    private val root: File,
    private val material: NativeResumeMaterial,
    private val registerCandidate: (String, File) -> Unit,
    private val stagedCandidate: (String) -> Unit,
    private val beforeRequest: () -> Unit,
    private val closeCandidate: (java.io.Closeable) -> Unit = { it.close() },
    private val disconnect: (HttpURLConnection) -> Unit = { it.disconnect() },
) {
    private val used = java.util.concurrent.atomic.AtomicBoolean(false)
    private fun <T> stage(phase: HttpTransfer.Phase, action: () -> T): T = try { action() } catch (error: Exception) {
        if (error is EngineProtocolException || error is HttpTransfer.StageFailure) throw error
        val code = when (phase) {
            HttpTransfer.Phase.JOURNAL -> "persistenceFailure"
            HttpTransfer.Phase.NETWORK -> if (error is java.net.SocketTimeoutException) "timeout" else "networkUnavailable"
            HttpTransfer.Phase.HTTP -> "httpFailure"
            HttpTransfer.Phase.FILE -> "fileWriteFailure"
        }
        throw HttpTransfer.StageFailure(phase, code, error)
    }
    data class Range(
        val end: Long,
        val total: Long,
        val length: Long,
    )

    companion object {
        fun responseRange(
            offset: Long,
            oldTotal: Long?,
            header: String?,
            contentLength: String?,
        ): Range {
            if (offset <= 0 || oldTotal?.let { it <= offset } == true) conflict("restartRequired")
            val match = header?.let { Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+)").matchEntire(it) } ?: conflict("restartRequired")
            val start = match.groupValues[1].toLongOrNull() ?: conflict("restartRequired")
            val end = match.groupValues[2].toLongOrNull() ?: conflict("restartRequired")
            val total = match.groupValues[3].toLongOrNull() ?: conflict("restartRequired")
            if (start != offset || total <= offset || end != total - 1 ||
                (oldTotal != null && oldTotal != total)
            ) {
                conflict("restartRequired")
            }
            val remaining = total - offset
            if (contentLength != null &&
                (!contentLength.matches(Regex("[0-9]+")) || contentLength.toLongOrNull() != remaining)
            ) {
                conflict("restartRequired")
            }
            return Range(end, total, remaining)
        }
    }

    fun run(
        stop: HttpTransfer.Stop = HttpTransfer.Stop(),
        onSample: (HttpTransfer.Sample) -> Unit = {},
        onCopied: (Long) -> Unit = {},
        onVerified: (Long) -> Unit = {},
    ): HttpTransfer.Staged {
        if (!used.compareAndSet(false, true)) conflict("commandOutcomeUnknown")
        val source = material.forced
        NativeMaterialPaths.validate(root, source.source)
        if (source.offset <= 0 || source.total?.let { it <= source.offset } == true || source.algorithm != NativePrefixDigest.ALGORITHM ||
            !NativeMaterialPaths.strongEtag(source.etag)
        ) {
            conflict("restartRequired")
        }
        if (stop.reason != null) conflict("restartRequired")
        var verified = 0L
        val authenticated = stage(HttpTransfer.Phase.FILE) {
            NativePrefixDigest.read(source.source, source.offset) { _, count ->
                verified = Math.addExact(verified, count.toLong())
                onVerified(verified)
                if (stop.reason != null) conflict("restartRequired")
            }
        }
        if (authenticated.snapshot() != source.prefixDigest) conflict("restartRequired")
        val uri = URI(source.effectiveUrl)
        if (uri.scheme !in listOf("http", "https") || uri.host.isNullOrBlank() || uri.rawUserInfo != null || uri.fragment != null ||
            uri.port !in -1..65535
        ) {
            conflict("restartRequired")
        }
        if (stop.reason != null) conflict("restartRequired")
        stage(HttpTransfer.Phase.JOURNAL) { beforeRequest() } // one-use native journal intent, not permission derived from file existence
        val connection = stage(HttpTransfer.Phase.NETWORK) { uri.toURL().openConnection() as HttpURLConnection }
        connection.instanceFollowRedirects = false
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        connection.setRequestProperty("Accept-Encoding", "identity")
        connection.setRequestProperty("Range", "bytes=${source.offset}-")
        connection.setRequestProperty("If-Range", source.etag)
        stop.attach(connection)
        var failure: Exception? = null
        try {
            if (stop.reason != null) conflict("restartRequired")
            // This is the actual GET response. No output/candidate exists before all gates pass.
            if (stage(HttpTransfer.Phase.NETWORK) { connection.responseCode } != 206 || connection.getHeaderField("ETag") != source.etag ||
                !NativeMaterialPaths.strongEtag(connection.getHeaderField("ETag")) ||
                connection.getHeaderField("Content-Encoding")?.equals("identity", true) == false
            ) {
                conflict("restartRequired")
            }
            val range =
                responseRange(
                    source.offset,
                    source.total,
                    connection.getHeaderField("Content-Range"),
                    connection.getHeaderField("Content-Length"),
                )
            if (stop.reason != null) conflict("restartRequired")
            val id = UUID.randomUUID().toString()
            val target = File(source.source.parentFile, "$id.part")
            NativeMaterialPaths.validate(root, target, false)
            stage(HttpTransfer.Phase.JOURNAL) { registerCandidate(id, target) } // must commit intent before CREATE_NEW or prefix copy
            val hash = MessageDigest.getInstance("SHA-256")
            var bytes = source.offset
            val helper = HttpTransfer(root, closeResource = closeCandidate, onAllocation = { _, _, _ -> error("not an allocation path") })
            stage(HttpTransfer.Phase.FILE) {
            helper.fileUse(FileChannel.open(target.toPath(), CREATE_NEW, WRITE, NOFOLLOW_LINKS)) { output ->
                var copied = 0L
                val prefix =
                    NativePrefixDigest.read(source.source, source.offset) { buffer, count ->
                        if (stop.reason != null) conflict("restartRequired")
                        val chunk = ByteBuffer.wrap(buffer, 0, count)
                        stage(HttpTransfer.Phase.FILE) { while (chunk.hasRemaining()) output.write(chunk) }
                        hash.update(buffer, 0, count)
                        copied = Math.addExact(copied, count.toLong())
                        onCopied(copied)
                    }
                if (prefix.snapshot() != source.prefixDigest) conflict("restartRequired")
                stage(HttpTransfer.Phase.NETWORK) { connection.inputStream.use { input ->
                    val buffer = ByteArray(65536)
                    while (true) {
                        if (stop.reason != null) conflict("restartRequired")
                        val count = input.read(buffer)
                        if (count == -1) break
                        if (count == 0) continue
                        val next = stage(HttpTransfer.Phase.HTTP) { Math.addExact(bytes, count.toLong()) }
                        if (next > range.total) throw HttpTransfer.StageFailure(HttpTransfer.Phase.HTTP, "httpFailure", IOException("resumedLengthExceeded"))
                        val chunk = ByteBuffer.wrap(buffer, 0, count)
                        stage(HttpTransfer.Phase.FILE) { while (chunk.hasRemaining()) output.write(chunk) }
                        hash.update(buffer, 0, count)
                        bytes = next
                        stage(HttpTransfer.Phase.JOURNAL) { onSample(HttpTransfer.Sample(bytes, range.total, System.nanoTime() / 1_000_000)) }
                    }
                } }
                if (bytes != range.total) throw HttpTransfer.StageFailure(HttpTransfer.Phase.HTTP, "httpFailure", IOException("resumedShortEof"))
                output.force(true)
            } }
            if (stop.reason != null) conflict("restartRequired")
            stage(HttpTransfer.Phase.JOURNAL) { stagedCandidate(id) } // only after exact EOF, force and real output close
            return HttpTransfer.Staged(
                target,
                bytes,
                range.total,
                source.effectiveUrl,
                null,
                hash.digest().joinToString("") { "%02x".format(it) },
            )
        } catch (error: Exception) {
            failure = error
            throw error
        } finally {
            stop.attach(null)
            try {
                stage(HttpTransfer.Phase.NETWORK) { disconnect(connection) }
            } catch (error: Exception) {
                if (failure != null) failure.addSuppressed(error) else throw error
            }
            // Source and registered incomplete candidates are intentionally never deleted.
        }
    }
}

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

/** Verified recovery core; production callers supply a frozen native source and live worker authorization. */
internal class ResumeTransfer(
    private val root: File,
    private val material: NativeResumeMaterial,
    private val registerCandidate: (String, File) -> Unit,
    private val stagedCandidate: (String) -> Unit,
    private val beforeRequest: () -> Unit,
    private val closeCandidate: (java.io.Closeable) -> Unit = { it.close() },
    private val disconnect: (HttpURLConnection) -> Unit = { it.disconnect() },
    private val onCheckpoint: (String, ForcedMaterial) -> Unit = { _, _ -> },
    private val monotonicNanos: () -> Long = System::nanoTime,
    private val verifiedPrefix: (Long) -> Unit = {},
    private val copiedPrefix: (Long) -> Unit = {},
) {
    /** Before a complete candidate prefix exists, stop is a real interruption, not unsafe HTTP.
     * bytes is diagnostic copied/source position only: neither task download progress nor a forced proof.
     */
    class Stopped(
        val reason: HttpTransfer.Stop.Reason,
        val candidate: File?,
        val bytes: Long,
    ) : IOException("recoveryStopped")

    private val used =
        java.util.concurrent.atomic
            .AtomicBoolean(false)

    private fun <T> stage(
        phase: HttpTransfer.Phase,
        action: () -> T,
    ): T =
        try {
            action()
        } catch (error: Exception) {
            // Stopped is control flow. A real close failure must remain an error, not paused success.
            if (error is Stopped && error.suppressed.isNotEmpty()) {
                val close = error.suppressed.first()
                throw HttpTransfer
                    .StageFailure(
                        HttpTransfer.Phase.FILE,
                        "fileWriteFailure",
                        (close.cause as? Exception) ?: (close as? Exception) ?: IOException("closeFailure", close),
                    ).also { it.addSuppressed(error) }
            }
            if (error is EngineProtocolException || error is HttpTransfer.StageFailure || error is Stopped) throw error
            val code =
                when (phase) {
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
        onCopied: (Long) -> Unit = copiedPrefix,
        onVerified: (Long) -> Unit = verifiedPrefix,
    ): HttpTransfer.Staged {
        if (!used.compareAndSet(false, true)) conflict("commandOutcomeUnknown")
        val source = material.forced
        NativeMaterialPaths.validate(root, source.source)
        if (source.offset <= 0 || source.total?.let { it <= source.offset } == true || source.algorithm != NativePrefixDigest.ALGORITHM ||
            !NativeMaterialPaths.strongEtag(source.etag)
        ) {
            conflict("restartRequired")
        }

        fun checkStop(
            candidate: File? = null,
            bytes: Long = source.offset,
        ) {
            stop.reason?.let { throw Stopped(it, candidate, bytes) }
        }
        checkStop()
        var verified = 0L
        val authenticated =
            stage(HttpTransfer.Phase.FILE) {
                NativePrefixDigest.read(source.source, source.offset) { _, count ->
                    verified = Math.addExact(verified, count.toLong())
                    onVerified(verified)
                    checkStop()
                }
            }
        if (authenticated.snapshot() != source.prefixDigest) conflict("restartRequired")
        val uri = URI(source.effectiveUrl)
        if (uri.scheme !in listOf("http", "https") || uri.host.isNullOrBlank() || uri.rawUserInfo != null || uri.fragment != null ||
            uri.port !in -1..65535
        ) {
            conflict("restartRequired")
        }
        checkStop()
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
            checkStop()
            // This is the actual GET response. No output/candidate exists before all gates pass.
            val status =
                stage(HttpTransfer.Phase.NETWORK) {
                    try {
                        connection.responseCode
                    } catch (error: IOException) {
                        checkStop()
                        throw error
                    }
                }
            checkStop()
            if (status != 206 || connection.getHeaderField("ETag") != source.etag ||
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
            checkStop()
            val id = UUID.randomUUID().toString()
            val target = File(source.source.parentFile, "$id.part")
            NativeMaterialPaths.validate(root, target, false)
            stage(HttpTransfer.Phase.JOURNAL) { registerCandidate(id, target) } // must commit intent before CREATE_NEW or prefix copy
            val hash = MessageDigest.getInstance("SHA-256")
            var bytes = source.offset
            val prefix = NativePrefixDigest()
            val factsFile = File(target.parentFile, "$id.facts")
            if (factsFile != factsFile.canonicalFile ||
                java.nio.file.Files
                    .isSymbolicLink(factsFile.toPath())
            ) {
                conflict("restartRequired")
            }
            val helper = HttpTransfer(root, closeResource = closeCandidate, onAllocation = { _, _, _ -> error("not an allocation path") })

            fun checkpoint() {
                if (stop.reason != HttpTransfer.Stop.Reason.CANCEL) {
                    stage(HttpTransfer.Phase.JOURNAL) {
                        onCheckpoint(
                            id,
                            ForcedMaterial(source.key, target, bytes, range.total, source.effectiveUrl, source.etag, prefix.snapshot()),
                        )
                    }
                }
            }
            stage(HttpTransfer.Phase.FILE) {
                helper.fileUse(FileChannel.open(factsFile.toPath(), CREATE_NEW, WRITE, NOFOLLOW_LINKS)) { facts ->
                    fun record(text: String) {
                        val data = ByteBuffer.wrap((text + "\n").toByteArray(Charsets.UTF_8))
                        while (data.hasRemaining()) facts.write(data)
                        facts.force(true)
                    }
                    record("recovery-v1 $id ${material.ref} ${source.offset}")
                    helper.fileUse(FileChannel.open(target.toPath(), CREATE_NEW, WRITE, NOFOLLOW_LINKS)) { output ->
                        var copied = 0L
                        val copiedPrefix =
                            NativePrefixDigest.read(source.source, source.offset) { buffer, count ->
                                checkStop(target, copied)
                                val chunk = ByteBuffer.wrap(buffer, 0, count)
                                while (chunk.hasRemaining()) output.write(chunk)
                                hash.update(buffer, 0, count)
                                prefix.update(buffer, count)
                                copied = Math.addExact(copied, count.toLong())
                                onCopied(copied)
                                checkStop(target, copied)
                            }
                        if (copiedPrefix.snapshot() != source.prefixDigest) conflict("restartRequired")
                        var checkpointAt = monotonicNanos()
                        stage(HttpTransfer.Phase.NETWORK) {
                            val stream =
                                if (stop.reason != null) {
                                    null
                                } else {
                                    try {
                                        connection.inputStream
                                    } catch (error: IOException) {
                                        if (stop.reason == null) throw error else null
                                    }
                                }
                            stream?.use { input ->
                                val buffer = ByteArray(65536)
                                while (stop.reason == null) {
                                    val count =
                                        try {
                                            input.read(buffer)
                                        } catch (error: IOException) {
                                            if (stop.reason != null) break else throw error
                                        }
                                    if (count == -1) break
                                    if (count == 0) continue
                                    val next = stage(HttpTransfer.Phase.HTTP) { Math.addExact(bytes, count.toLong()) }
                                    if (next >
                                        range.total
                                    ) {
                                        throw HttpTransfer.StageFailure(
                                            HttpTransfer.Phase.HTTP,
                                            "httpFailure",
                                            IOException("resumedLengthExceeded"),
                                        )
                                    }
                                    val chunk = ByteBuffer.wrap(buffer, 0, count)
                                    stage(HttpTransfer.Phase.FILE) { while (chunk.hasRemaining()) output.write(chunk) }
                                    hash.update(buffer, 0, count)
                                    prefix.update(buffer, count)
                                    bytes = next
                                    val now = monotonicNanos()
                                    stage(HttpTransfer.Phase.JOURNAL) { onSample(HttpTransfer.Sample(bytes, range.total, now / 1_000_000)) }
                                    if (now - checkpointAt >= 1_000_000_000L) {
                                        stage(HttpTransfer.Phase.FILE) {
                                            output.force(true)
                                            record("progress $bytes")
                                        }
                                        checkpoint()
                                        checkpointAt = now
                                    }
                                }
                            }
                        }
                        if (stop.reason == null &&
                            bytes != range.total
                        ) {
                            throw HttpTransfer.StageFailure(HttpTransfer.Phase.HTTP, "httpFailure", IOException("resumedShortEof"))
                        }
                        output.force(true)
                    }
                    record("closed ${stop.reason?.name ?: "staged"} $bytes")
                }
            }
            // BOTH payload and facts close must succeed; cancelled work never advances a proof.
            checkpoint()
            val terminalStop = stop.reason // re-read after BOTH closes and the final journal callback
            if (terminalStop == null) stage(HttpTransfer.Phase.JOURNAL) { stagedCandidate(id) }
            return HttpTransfer.Staged(
                target,
                bytes,
                range.total,
                source.effectiveUrl,
                terminalStop,
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
                if (failure is Stopped) {
                    error.addSuppressed(failure)
                    throw error // disconnect failure must not be disguised as a successful stop
                }
                if (failure != null) failure.addSuppressed(error) else throw error
            }
            // Source and registered incomplete candidates are intentionally never deleted.
        }
    }
}

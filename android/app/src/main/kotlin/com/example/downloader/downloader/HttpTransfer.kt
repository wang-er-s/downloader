package com.example.downloader.downloader

import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardOpenOption.CREATE_NEW
import java.nio.file.StandardOpenOption.WRITE
import java.security.MessageDigest
import java.util.UUID

/** Native worker building block only; no publication, retry, or resume. */
internal class HttpTransfer(
    private val appFiles: File,
    private val authorizedUrl: String? = null,
    private val onCheckpoint: (ForcedMaterial) -> Unit = {},
    private val monotonicNanos: () -> Long = System::nanoTime,
    private val closeResource: (java.io.Closeable) -> Unit = { it.close() },
    // Required: production callers persist in ExecutionJournal before returning.
    // Only host tests explicitly supply a no-op diagnostic registrar.
    private val onAllocation: (ExecutionKey, File, File) -> Unit,
) {
    data class Sample(
        val bytes: Long,
        val total: Long?,
        val monotonicMs: Long,
    )

    data class Staged(
        val file: File,
        val bytes: Long,
        val total: Long?,
        val effectiveUrl: String,
        val stop: Stop.Reason?,
        val sha256: String,
    )

    enum class Phase { JOURNAL, NETWORK, HTTP, FILE }

    class StageFailure(
        val phase: Phase,
        val code: String,
        cause: Exception,
    ) : IOException("transferStageFailure", cause)

    class Failure(
        val material: File,
        val bytes: Long,
        cause: Exception,
        val code: String = "fileWriteFailure",
        val phase: Phase = Phase.FILE,
    ) : IOException("transferFailed", cause)

    private fun <T> at(
        phase: Phase,
        action: () -> T,
    ): T =
        try {
            action()
        } catch (error: Exception) {
            if (error is StageFailure) throw error
            val code =
                when (phase) {
                    Phase.JOURNAL -> "persistenceFailure"
                    Phase.HTTP -> "httpFailure"
                    Phase.FILE -> "fileWriteFailure"
                    Phase.NETWORK -> if (error is java.net.SocketTimeoutException) "timeout" else "networkUnavailable"
                }
            throw StageFailure(phase, code, error)
        }

    internal fun <T : java.io.Closeable, R> fileUse(
        resource: T,
        action: (T) -> R,
    ): R {
        var failure: Throwable? = null
        try {
            return action(resource)
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            try {
                at(Phase.FILE) { closeResource(resource) }
            } catch (error: Exception) {
                if (failure != null) failure.addSuppressed(error) else throw error
            }
        }
    }

    /** Atomic priority publication never waits for disconnect, including attach/request races. */
    class Stop(
        private val disconnect: (HttpURLConnection) -> Unit = { it.disconnect() },
    ) {
        enum class Reason { PAUSE, CANCEL }

        private val requested =
            java.util.concurrent.atomic
                .AtomicReference<Reason?>(null)
        private val connection =
            java.util.concurrent.atomic
                .AtomicReference<HttpURLConnection?>(null)
        val reason: Reason? get() = requested.get()

        fun request(value: Reason) {
            requested.updateAndGet { prior -> if (prior == Reason.CANCEL || value == Reason.CANCEL) Reason.CANCEL else Reason.PAUSE }
            connection.get()?.let { value -> disconnectAsync(value) }
        }

        private fun disconnectAsync(value: HttpURLConnection) {
            disconnects.execute {
                try {
                    disconnect(value)
                } catch (_: Exception) {
                }
            }
        }

        internal fun attach(value: HttpURLConnection?) {
            connection.set(value)
            if (value != null && reason != null) disconnectAsync(value)
        }

        companion object {
            private val disconnects =
                java.util.concurrent.Executors.newCachedThreadPool { action ->
                    Thread(action, "download-disconnect").apply {
                        isDaemon =
                            true
                    }
                }
        }
    }

    /** appFiles must be native Context.filesDir, never a channel path. Native UUID names only.
     * Root/staging aliases are rejected. App sandbox ownership excludes hostile native writers.
     * Forced intent precedes exclusive payload creation; facts are NOT resume proofs.
     */
    fun run(
        key: ExecutionKey,
        url: String,
        stop: Stop = Stop(),
        onSample: (Sample) -> Unit = {},
    ): Staged {
        if (authorizedUrl != null && url != authorizedUrl) conflict("commandPayloadChanged")
        var current = at(Phase.HTTP) { checkedUrl(URI(url)) }
        val root = appFiles.absoluteFile
        require(root == root.canonicalFile && root.isDirectory) { "privateRootRequired" }
        val directory = File(root, "http_staging_v1")
        try {
            Files.createDirectory(directory.toPath())
        } catch (_: java.nio.file.FileAlreadyExistsException) {
        }
        require(
            !Files.isSymbolicLink(directory.toPath()) && directory.isDirectory &&
                directory.canonicalFile.parentFile == root,
        ) { "privateStagingRequired" }
        val id = UUID.randomUUID().toString()
        val file = File(directory, "$id.part")
        val journal = File(directory, "$id.facts")
        var bytes = 0L
        var total: Long? = null
        var active: HttpURLConnection? = null
        var strongEtag: String? = null
        val prefix = NativePrefixDigest()
        val digest = MessageDigest.getInstance("SHA-256")
        var primaryFailure: Failure? = null
        try {
            // Register BOTH names before the first exclusive file creation or network request.
            // A failed transaction leaves no facts/payload and must not be retried implicitly.
            at(Phase.JOURNAL) { onAllocation(key, file, journal) }
            val staged =
                fileUse(at(Phase.FILE) { FileChannel.open(journal.toPath(), CREATE_NEW, WRITE, NOFOLLOW_LINKS) }) { facts ->
                    fun record(text: String) {
                        val buffer = ByteBuffer.wrap((text + "\n").toByteArray(Charsets.UTF_8))
                        at(Phase.FILE) {
                            while (buffer.hasRemaining()) facts.write(buffer)
                            facts.force(true)
                        }
                    }

                    fun checkpoint() {
                        val etag = strongEtag ?: return
                        if (bytes > 0) {
                            at(Phase.JOURNAL) {
                                onCheckpoint(ForcedMaterial(key, file, bytes, total, current.toASCIIString(), etag, prefix.snapshot()))
                            }
                        }
                    }

                    fun hex(value: String) = value.toByteArray(Charsets.UTF_8).joinToString("") { "%02x".format(it) }
                    record("v1 intent $id ${hex(key.taskId)} ${hex(key.engineId)} ${key.generation} resume=unsupported")
                    fileUse(at(Phase.FILE) { FileChannel.open(file.toPath(), CREATE_NEW, WRITE, NOFOLLOW_LINKS) }) { output ->
                        val seen = mutableSetOf<String>()
                        var redirects = 0
                        while (stop.reason == null) {
                            if (!seen.add(current.normalize().toASCIIString())) at(Phase.HTTP) { throw IOException("redirectLoop") }
                            val connection = at(Phase.NETWORK) { current.toURL().openConnection() as HttpURLConnection }
                            active = connection
                            connection.instanceFollowRedirects = false
                            connection.connectTimeout = 15_000
                            connection.readTimeout = 30_000
                            connection.setRequestProperty("Accept-Encoding", "identity")
                            stop.attach(connection)
                            if (stop.reason != null) break
                            val status =
                                try {
                                    connection.responseCode
                                } catch (error: IOException) {
                                    if (stop.reason != null) break else at(Phase.NETWORK) { throw error }
                                }
                            if (status in listOf(301, 302, 303, 307, 308)) {
                                if (++redirects > 10) at(Phase.HTTP) { throw IOException("tooManyRedirects") }
                                val location =
                                    connection.getHeaderField("Location") ?: at(Phase.HTTP) { throw IOException("missingLocation") }
                                current = at(Phase.HTTP) { checkedUrl(current.resolve(location)) }
                                at(Phase.NETWORK) { connection.disconnect() }
                                stop.attach(null)
                                continue
                            }
                            if (status != 200) at(Phase.HTTP) { throw IOException("httpStatus:$status") }
                            val encoding = connection.getHeaderField("Content-Encoding")
                            if (encoding != null &&
                                !encoding.equals("identity", true)
                            ) {
                                at(Phase.HTTP) { throw IOException("unexpectedEncoding") }
                            }
                            total =
                                connection.getHeaderField("Content-Length")?.let {
                                    if (!it.matches(Regex("[0-9]+"))) at(Phase.HTTP) { throw IOException("invalidLength") }
                                    it.toLongOrNull() ?: at(Phase.HTTP) { throw IOException("invalidLength") }
                                }
                            strongEtag = connection.getHeaderField("ETag").takeIf { NativeMaterialPaths.strongEtag(it) }
                            var checkpointAt = monotonicNanos()
                            at(Phase.NETWORK) {
                                connection.inputStream.use { input ->
                                    val buffer = ByteArray(64 * 1024)
                                    while (stop.reason == null) {
                                        val count =
                                            try {
                                                input.read(buffer)
                                            } catch (error: IOException) {
                                                if (stop.reason != null) break else at(Phase.NETWORK) { throw error }
                                            }
                                        if (count == -1) break
                                        if (count == 0) continue
                                        val next = Math.addExact(bytes, count.toLong())
                                        if (total != null && next > total!!) at(Phase.HTTP) { throw IOException("lengthExceeded") }
                                        val chunk = ByteBuffer.wrap(buffer, 0, count)
                                        at(Phase.FILE) { while (chunk.hasRemaining()) output.write(chunk) }
                                        digest.update(buffer, 0, count)
                                        prefix.update(buffer, count)
                                        bytes = next
                                        val now = monotonicNanos()
                                        at(Phase.JOURNAL) { onSample(Sample(bytes, total, now / 1_000_000)) }
                                        if (now - checkpointAt >= 1_000_000_000L) {
                                            at(Phase.FILE) { output.force(true) }
                                            record("progress $bytes")
                                            checkpoint()
                                            checkpointAt = now
                                        }
                                    }
                                }
                            }
                            break
                        }
                        if (stop.reason == null && total != null && bytes != total) at(Phase.HTTP) { throw IOException("shortEof") }
                        at(Phase.FILE) { output.force(true) }
                    }
                    // Output close/force must succeed before a stopped/staged record.
                    val hash = digest.digest().joinToString("") { "%02x".format(it) }
                    // Freeze the result at this boundary: a late request cannot change only the return value.
                    val terminalStop = stop.reason
                    record("closed ${terminalStop?.name ?: "staged"} $bytes ${total ?: "unknown"} $hash")
                    Staged(file, bytes, total, current.toASCIIString(), terminalStop, hash)
                }
            // Final proof requires BOTH payload and facts close, not merely their force calls.
            strongEtag?.let { etag ->
                if (bytes > 0) {
                    at(Phase.JOURNAL) {
                        onCheckpoint(ForcedMaterial(key, file, bytes, total, staged.effectiveUrl, etag, prefix.snapshot()))
                    }
                }
            }
            return staged
        } catch (error: Exception) {
            val typed = error as? StageFailure
            val original = (typed?.cause as? Exception) ?: error
            if (typed != null) typed.suppressed.forEach { original.addSuppressed(it) }
            val failure = Failure(file, bytes, original, typed?.code ?: "fileWriteFailure", typed?.phase ?: Phase.FILE)
            primaryFailure = failure
            throw failure
        } finally {
            stop.attach(null)
            try {
                at(Phase.NETWORK) { active?.disconnect() }
            } catch (error: StageFailure) {
                if (primaryFailure != null) {
                    primaryFailure.addSuppressed(error)
                } else {
                    throw Failure(file, bytes, error.cause as Exception, error.code, error.phase)
                }
            }
        }
    }

    fun resume(): Nothing = throw EngineProtocolException("stateConflict", "restartRequired")

    private fun checkedUrl(uri: URI): URI {
        if (uri.scheme !in listOf("http", "https") || uri.host.isNullOrBlank() ||
            uri.rawUserInfo != null || uri.fragment != null || uri.port < -1 || uri.port > 65535
        ) {
            throw IOException("invalidHttpUrl")
        }
        return uri
    }
}

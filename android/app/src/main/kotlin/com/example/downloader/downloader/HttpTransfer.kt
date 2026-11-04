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

    class Failure(
        val material: File,
        val bytes: Long,
        cause: Exception,
    ) : IOException("transferFailed", cause)

    /** request signals only. run returning is the actual stopped/closed barrier. */
    class Stop {
        enum class Reason { PAUSE, CANCEL }

        @Volatile var reason: Reason? = null
            private set
        private var connection: HttpURLConnection? = null

        @Synchronized fun request(value: Reason) {
            if (reason == null) reason = value
            connection?.disconnect()
        }

        @Synchronized internal fun attach(value: HttpURLConnection?) {
            connection = value
            if (reason != null) value?.disconnect()
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
        var current = checkedUrl(URI(url))
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
        val digest = MessageDigest.getInstance("SHA-256")
        try {
            // Register BOTH names before the first exclusive file creation or network request.
            // A failed transaction leaves no facts/payload and must not be retried implicitly.
            onAllocation(key, file, journal)
            FileChannel.open(journal.toPath(), CREATE_NEW, WRITE, NOFOLLOW_LINKS).use { facts ->
                fun record(text: String) {
                    val buffer = ByteBuffer.wrap((text + "\n").toByteArray(Charsets.UTF_8))
                    while (buffer.hasRemaining()) facts.write(buffer)
                    facts.force(true)
                }

                fun hex(value: String) = value.toByteArray(Charsets.UTF_8).joinToString("") { "%02x".format(it) }
                record("v1 intent $id ${hex(key.taskId)} ${hex(key.engineId)} ${key.generation} resume=unsupported")
                FileChannel.open(file.toPath(), CREATE_NEW, WRITE, NOFOLLOW_LINKS).use { output ->
                    val seen = mutableSetOf<String>()
                    var redirects = 0
                    while (stop.reason == null) {
                        if (!seen.add(current.normalize().toASCIIString())) throw IOException("redirectLoop")
                        val connection = current.toURL().openConnection() as HttpURLConnection
                        active = connection
                        connection.instanceFollowRedirects = false
                        connection.connectTimeout = 15_000
                        connection.readTimeout = 30_000
                        connection.setRequestProperty("Accept-Encoding", "identity")
                        stop.attach(connection)
                        val status =
                            try {
                                connection.responseCode
                            } catch (error: IOException) {
                                if (stop.reason != null) break else throw error
                            }
                        if (status in listOf(301, 302, 303, 307, 308)) {
                            if (++redirects > 10) throw IOException("tooManyRedirects")
                            val location = connection.getHeaderField("Location") ?: throw IOException("missingLocation")
                            current = checkedUrl(current.resolve(location))
                            connection.disconnect()
                            stop.attach(null)
                            continue
                        }
                        if (status != 200) throw IOException("httpStatus:$status")
                        val encoding = connection.getHeaderField("Content-Encoding")
                        if (encoding != null && !encoding.equals("identity", true)) throw IOException("unexpectedEncoding")
                        total =
                            connection.getHeaderField("Content-Length")?.let {
                                if (!it.matches(Regex("[0-9]+"))) throw IOException("invalidLength")
                                it.toLongOrNull() ?: throw IOException("invalidLength")
                            }
                        var checkpointAt = System.nanoTime()
                        connection.inputStream.use { input ->
                            val buffer = ByteArray(64 * 1024)
                            while (stop.reason == null) {
                                val count =
                                    try {
                                        input.read(buffer)
                                    } catch (error: IOException) {
                                        if (stop.reason != null) break else throw error
                                    }
                                if (count == -1) break
                                if (count == 0) continue
                                val next = Math.addExact(bytes, count.toLong())
                                if (total != null && next > total!!) throw IOException("lengthExceeded")
                                val chunk = ByteBuffer.wrap(buffer, 0, count)
                                while (chunk.hasRemaining()) output.write(chunk)
                                digest.update(buffer, 0, count)
                                bytes = next
                                val now = System.nanoTime()
                                onSample(Sample(bytes, total, now / 1_000_000))
                                if (now - checkpointAt >= 1_000_000_000L) {
                                    output.force(true)
                                    record("progress $bytes")
                                    checkpointAt = now
                                }
                            }
                        }
                        break
                    }
                    if (stop.reason == null && total != null && bytes != total) throw IOException("shortEof")
                    output.force(true)
                }
                // Output close/force must succeed before a stopped/staged record.
                val hash = digest.digest().joinToString("") { "%02x".format(it) }
                // Freeze the result at this boundary: a late request cannot change only the return value.
                val terminalStop = stop.reason
                record("closed ${terminalStop?.name ?: "staged"} $bytes ${total ?: "unknown"} $hash")
                return Staged(file, bytes, total, current.toASCIIString(), terminalStop, hash)
            }
        } catch (error: Exception) {
            throw Failure(file, bytes, error)
        } finally {
            active?.disconnect()
            stop.attach(null)
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

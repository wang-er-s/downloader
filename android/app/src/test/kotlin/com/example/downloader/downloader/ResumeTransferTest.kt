package com.example.downloader.downloader

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.net.ServerSocket
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

class ResumeTransferTest {
    private val key = ExecutionKey("task", "engine", 0)

    private fun hash(file: File) = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).toList()

    private class Fixture : AutoCloseable {
        val root = Files.createTempDirectory("resume-http").toFile().canonicalFile
        val dir = File(root, "http_staging_v1").apply { mkdirs() }
        val source = File(dir, "${UUID.randomUUID()}.part").apply { writeBytes(ByteArray(24576) { (it % 251).toByte() }) }

        override fun close() {
            root.deleteRecursively()
        }
    }

    private fun material(
        f: Fixture,
        url: String,
        total: Long? = 16384,
    ): NativeResumeMaterial =
        NativeResumeMaterial(
            "opaque-ref",
            "enqueue",
            3,
            ForcedMaterial(key, f.source, 8192, total, url, "\"strong\"", NativePrefixDigest.read(f.source, 8192).snapshot()),
        )

    private fun server(
        response: (String) -> ByteArray,
        action: (String, AtomicInteger) -> Unit,
    ) {
        ServerSocket(0).use { server ->
            val requests = AtomicInteger()
            val thread =
                Thread {
                    server.accept().use { socket ->
                        requests.incrementAndGet()
                        val reader = socket.getInputStream().bufferedReader()
                        val request = StringBuilder(reader.readLine()).append("\n")
                        while (true) {
                            val line = reader.readLine() ?: break
                            if (line.isEmpty()) break
                            request.append(line).append("\n")
                        }
                        socket.getOutputStream().write(response(request.toString()))
                    }
                }.apply {
                    isDaemon = true
                    start()
                }
            action("http://127.0.0.1:${server.localPort}/", requests)
            thread.join(5000)
            assertFalse("responder did not finish", thread.isAlive)
        }
    }

    private fun response(
        status: Int = 206,
        range: String = "bytes 8192-16383/16384",
        etag: String? = "\"strong\"",
        length: String? = "8192",
        body: ByteArray =
            ByteArray(8192) {
                42
            },
    ): ByteArray {
        val headers =
            "HTTP/1.1 $status Result\r\nConnection: close\r\nContent-Range: $range\r\n" + (etag?.let { "ETag: $it\r\n" } ?: "") +
                (length?.let { "Content-Length: $it\r\n" } ?: "") +
                "\r\n"
        return headers.toByteArray() + body
    }

    @Test fun exact206CreatesOwnedCandidateAndPreservesUncommittedSourceTail() {
        for (length in listOf("8192", null)) {
            server({ request ->
                assertTrue(request.startsWith("GET /"))
                assertTrue(request.contains("Range: bytes=8192-"))
                assertTrue(request.contains("If-Range: \"strong\""))
                response(length = length)
            }) { url, requests ->
                Fixture().use { f ->
                    val original = hash(f.source)
                    var owned: File? = null
                    var staged = false
                    var claimed = 0
                    val samples = mutableListOf<Long>()
                    val transfer =
                        ResumeTransfer(f.root, material(f, url), { _, file ->
                            assertFalse(file.exists())
                            owned = file
                        }, { staged = true }, { claimed++ })
                    val result = transfer.run(onSample = { samples.add(it.bytes) })
                    assertEquals(owned, result.file)
                    assertTrue(staged)
                    assertEquals(1, claimed)
                    assertEquals(16384L, result.bytes)
                    assertEquals(16384L, result.file.length())
                    assertArrayEquals(f.source.readBytes().copyOf(8192) + ByteArray(8192) { 42 }, result.file.readBytes())
                    assertEquals(24576L, f.source.length())
                    assertEquals(original, hash(f.source))
                    assertEquals(1, requests.get())
                    assertTrue(samples.last() > 8192)
                    try {
                        transfer.run()
                        fail("reused core")
                    } catch (
                        error: EngineProtocolException,
                    ) {
                        assertEquals("commandOutcomeUnknown", error.reason)
                    }
                }
            }
        }
    }

    @Test fun unsafeActualResponsesNeverAllocateCandidateOrChangeSource() {
        val responses =
            listOf(
                response(status = 200),
                response(status = 416),
                response(range = "bytes 8191-16383/16384"),
                response(range = "bytes 8192-16382/16384"),
                response(range = "bytes 8192-32767/32768"),
                response(etag = "\"changed\""),
                response(etag = null),
                response(etag = "W/\"strong\""),
                response(length = "8191"),
                response(range = "bytes 8192-9223372036854775808/9223372036854775809"),
            )
        for (bytes in responses) {
            server({ bytes }) { url, _ ->
                Fixture().use { f ->
                    val original = hash(f.source)
                    try {
                        ResumeTransfer(
                            f.root,
                            material(f, url),
                            { _, _ -> fail("candidate before response gate") },
                            { fail("staged") },
                            {},
                        ).run()
                        fail()
                    } catch (
                        error: EngineProtocolException,
                    ) {
                        assertEquals("restartRequired", error.reason)
                    }
                    assertEquals(original, hash(f.source))
                    assertEquals(1, f.dir.list()!!.size)
                }
            }
        }
    }

    @Test fun badPrefixWeakLocalValidatorAndOldAlgorithmRejectBeforeHttp() {
        Fixture().use { f ->
            val source = material(f, "http://127.0.0.1:1/")
            val variants =
                listOf(
                    source.copy(forced = source.forced.copy(prefixDigest = "00".repeat(32))),
                    source.copy(forced = source.forced.copy(etag = "W/\"strong\"")),
                    source.copy(forced = source.forced.copy(algorithm = "facts-v1")),
                )
            for (bad in variants) {
                try {
                    ResumeTransfer(f.root, bad, { _, _ -> fail() }, { fail() }, { fail("HTTP authorization reached") }).run()
                    fail()
                } catch (
                    error: EngineProtocolException,
                ) {
                    assertEquals("restartRequired", error.reason)
                }
            }
            assertEquals(1, f.dir.list()!!.size)
        }
    }

    @Test fun copyInterruptionAndShortEofRetainOwnedCandidateAndOriginal() {
        for (copyStop in listOf(true, false)) {
            server({ response(body = ByteArray(5)) }) { url, _ ->
                Fixture().use { f ->
                    val original = hash(f.source)
                    var candidate: File? = null
                    var staged = false
                    val transfer = ResumeTransfer(f.root, material(f, url), { _, target -> candidate = target }, { staged = true }, {})
                    try {
                        transfer.run(onCopied = { if (copyStop) throw java.io.IOException("copy interrupted") })
                        fail()
                    } catch (
                        _: java.io.IOException,
                    ) {
                    }
                    assertFalse(staged)
                    assertNotNull(candidate)
                    assertTrue(candidate!!.exists())
                    assertEquals(original, hash(f.source))
                    assertEquals(24576L, f.source.length())
                }
            }
        }
    }

    @Test fun candidateRegistrationFailureAndSymlinkSourceNeverWriteOutputs() {
        server({ response() }) { url, _ -> Fixture().use { f ->
            val original = hash(f.source)
            try { ResumeTransfer(f.root, material(f, url), { _, _ -> throw java.io.IOException("journal failure") }, { fail() }, {}).run(); fail() }
            catch (error: HttpTransfer.StageFailure) { assertEquals("persistenceFailure", error.code) }
            assertEquals(original, hash(f.source)); assertEquals(1, f.dir.list()!!.size)
        } }
        Fixture().use { f ->
            val material = material(f, "http://127.0.0.1:1/")
            val external = Files.createTempFile("resume-sentinel", ".bin").toFile().canonicalFile
            external.writeBytes(f.source.readBytes())
            val original = hash(external)
            try {
                f.source.delete()
                Files.createSymbolicLink(f.source.toPath(), external.toPath())
                try { ResumeTransfer(f.root, material, { _, _ -> fail() }, { fail() }, { fail("source symlink reached HTTP") }).run(); fail() }
                catch (error: EngineProtocolException) { assertEquals("restartRequired", error.reason) }
                assertEquals(original, hash(external))
            } finally { external.delete() }
        }
    }

    @Test fun signed64BitRangeValidationDoesNotOverflow() {
        val offset = 4_294_967_296L
        assertEquals(100L, ResumeTransfer.responseRange(offset, null, "bytes $offset-${offset + 99}/${offset + 100}", "100").length)
        assertEquals(
            1L,
            ResumeTransfer
                .responseRange(
                    Long.MAX_VALUE - 1,
                    Long.MAX_VALUE,
                    "bytes ${Long.MAX_VALUE - 1}-${Long.MAX_VALUE - 1}/${Long.MAX_VALUE}",
                    "1",
                ).length,
        )
        try {
            ResumeTransfer.responseRange(Long.MAX_VALUE, null, "bytes ${Long.MAX_VALUE}-${Long.MAX_VALUE}/${Long.MAX_VALUE}", null)
            fail()
        } catch (
            error: EngineProtocolException,
        ) {
            assertEquals("restartRequired", error.reason)
        }
    }

    @Test fun disconnectFailureKeepsTypedPrimaryAndSuppressedNetworkCause() {
        server({ response() }) { url, _ -> Fixture().use { f ->
            val primary = java.io.IOException("journal registration")
            val cleanup = java.io.IOException("disconnect")
            val transfer = ResumeTransfer(f.root, material(f, url), { _, _ -> throw primary }, { fail() }, {},
                disconnect = { it.disconnect(); throw cleanup })
            try { transfer.run(); fail() }
            catch (error: HttpTransfer.StageFailure) {
                assertEquals("persistenceFailure", error.code)
                assertSame(primary, error.cause)
                val suppressed = error.suppressed.single() as HttpTransfer.StageFailure
                assertEquals("networkUnavailable", suppressed.code)
                assertSame(cleanup, suppressed.cause)
            }
            assertEquals(1, f.dir.list()!!.size)
        } }
    }

    @Test fun independentDigestVectorsCoverEmptyAndBlockBoundaries() {
        val vectors = mapOf(
            0 to "a50fde276c21e35188a92a2b5d6fca28935075760a0bc08166b7609abbc07404",
            1 to "cd1c676968fbbb1e5d93a9a9bfe9bb9bddd97ecabe5e40bf8023fc5edcb727ec",
            65535 to "3f25893231731a328dd1f76199b090591fc89fd403fc65183eaf7882a00ad36f",
            65536 to "fa4979f0cce7a198258aef29f6e0ea1e3b3f30d99976bdb54b17ba09066b6bda",
            65537 to "06829c673b34c5f086a44ca7e1c88342e0d320e300a3a6b27dac0d95d003efff",
            131072 to "9cb63ca4e696b0fa6fa26f5e52602bfe0803038186035c5346f79d07f3f4b713",
        ) // Independently calculated with Python hashlib.sha256 and struct.pack('>qI').
        vectors.forEach { (size, expected) ->
            val digest = NativePrefixDigest()
            val bytes = ByteArray(size) { (it % 251).toByte() }
            bytes.toList().chunked(317).forEach { chunk -> digest.update(chunk.toByteArray(), chunk.size) }
            assertEquals(expected, digest.snapshot())
            assertEquals(expected, digest.snapshot())
            assertEquals(size.toLong(), digest.length)
        }
    }

    @Test fun cancellationDuringInitialAuthenticationStopsBeforeRequestOrCandidate() {
        Fixture().use { f ->
            f.source.writeBytes(ByteArray(200000) { (it % 251).toByte() })
            val original = hash(f.source)
            val proof = material(f, "http://127.0.0.1:1/", 300000).let { it.copy(forced = it.forced.copy(offset = 131072, prefixDigest = NativePrefixDigest.read(f.source, 131072).snapshot())) }
            val stop = HttpTransfer.Stop()
            var verified = 0L
            val transfer = ResumeTransfer(f.root, proof, { _, _ -> fail("candidate after cancellation") }, { fail() }, { fail("GET after cancellation") })
            try { transfer.run(stop, onVerified = { verified = it; stop.request(HttpTransfer.Stop.Reason.CANCEL) }); fail() }
            catch (error: EngineProtocolException) { assertEquals("restartRequired", error.reason) }
            assertEquals(65536L, verified)
            assertEquals(original, hash(f.source))
            assertEquals(1, f.dir.list()!!.size)
        }
    }

    @Test fun candidateCloseFailureIsFileFailureAndCannotMarkStaged() {
        server({ response() }) { url, _ -> Fixture().use { f ->
            val original = hash(f.source)
            var owned: File? = null
            var staged = false
            val injected = java.io.IOException("candidate close failure")
            val transfer = ResumeTransfer(f.root, material(f, url), { _, file -> owned = file }, { staged = true }, {}, { it.close(); throw injected })
            try { transfer.run(); fail() }
            catch (error: HttpTransfer.StageFailure) { assertEquals("fileWriteFailure", error.code); assertSame(injected, error.cause) }
            assertFalse(staged)
            assertTrue(owned!!.exists())
            assertEquals(original, hash(f.source))
        } }
    }

    @Test fun digestIsChunkInvariantVersionedAndDoesNotUseClone() {
        val bytes = ByteArray(200000) { (it % 251).toByte() }
        val one = NativePrefixDigest().apply { update(bytes, bytes.size) }
        val chunked = NativePrefixDigest()
        bytes.toList().chunked(333).forEach { block ->
            val part = block.toByteArray()
            chunked.update(part, part.size)
        }
        assertEquals("b51a6b2b8c8d496b5a88882c6d46164a30b788968cfa357b9b93f0de2c149f6c", one.snapshot()) // independent SHA256/struct implementation vector
        assertEquals(one.snapshot(), chunked.snapshot())
        assertNotEquals(MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }, one.snapshot())
        val prior = chunked.snapshot()
        chunked.update(byteArrayOf(1), 1)
        assertNotEquals(prior, chunked.snapshot())
    }
}

package com.example.downloader.downloader

import java.io.File
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class HttpTransferTest {
    private val key = ExecutionKey("task", "engine", 0)
    private fun root(): File = Files.createTempDirectory("http-core-test").toFile().canonicalFile
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    // Raw loopback HTTP avoids Android's restricted java.base compilation surface.
    private class Headers : java.util.TreeMap<String, String>(String.CASE_INSENSITIVE_ORDER) {
        fun add(name: String, value: String) { put(name, value) }
        fun getFirst(name: String): String? = get(name)
    }
    private class Exchange(private val socket: java.net.Socket, val requestHeaders: Headers) {
        val responseHeaders = Headers()
        val responseBody: java.io.OutputStream get() = socket.getOutputStream()
        fun sendResponseHeaders(status: Int, length: Long) {
            val text = StringBuilder("HTTP/1.1 $status Result\r\nConnection: close\r\n")
            if (length > 0) text.append("Content-Length: $length\r\n")
            responseHeaders.forEach { (k, v) -> text.append("$k: $v\r\n") }
            responseBody.write(text.append("\r\n").toString().toByteArray())
            responseBody.flush()
        }
        fun close() = socket.close()
    }
    private class LocalServer : java.io.Closeable {
        private val socket = ServerSocket(0, 50, java.net.InetAddress.getByName("127.0.0.1"))
        val port get() = socket.localPort
        private val routes = java.util.concurrent.ConcurrentHashMap<String, (Exchange) -> Unit>()
        private val workers = Executors.newCachedThreadPool()
        private val failures = java.util.Collections.synchronizedList(mutableListOf<Throwable>())
        private val acceptor = Thread {
            try { while (!socket.isClosed) {
                val client = socket.accept()
                workers.submit {
                    try { client.use {
                        val reader = it.getInputStream().bufferedReader()
                        val path = reader.readLine().split(" ")[1]
                        val headers = Headers()
                        while (true) {
                            val line = reader.readLine() ?: break
                            if (line.isEmpty()) break
                            headers.add(line.substringBefore(":"), line.substringAfter(":").trim())
                        }
                        (routes[path] ?: error("missing route $path"))(Exchange(it, headers))
                    } } catch (e: Throwable) { failures.add(e) }
                }
            } } catch (_: java.net.SocketException) { }
        }.apply { start() }
        fun createContext(path: String, handler: (Exchange) -> Unit) { routes[path] = handler }
        override fun close() {
            socket.close(); acceptor.join(5000); workers.shutdown()
            check(workers.awaitTermination(10, TimeUnit.SECONDS))
            // Stream cancellation intentionally causes a server-side broken pipe.
            failures.firstOrNull { it !is java.io.IOException }?.let { throw AssertionError(it) }
        }
    }
    private fun server(block: (LocalServer, String) -> Unit) {
        LocalServer().use { block(it, "http://127.0.0.1:${it.port}") }
    }

    @Test fun realBytesAndExclusiveStaging() = server { server, base ->
        val bytes = ByteArray(180_123) { (it % 251).toByte() }
        server.createContext("/bytes") { exchange ->
            assertEquals("identity", exchange.requestHeaders.getFirst("Accept-Encoding"))
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        val root = root()
        try {
            val worker = HttpTransfer(root)
            val one = worker.run(key, "$base/bytes")
            val two = worker.run(key, "$base/bytes")
            assertNotEquals(one.file, two.file)
            assertArrayEquals(bytes, one.file.readBytes())
            assertArrayEquals(bytes, two.file.readBytes())
            assertEquals(bytes.size.toLong(), one.bytes)
            assertEquals(one.bytes, one.total)
            assertEquals(hash(bytes), one.sha256)
            assertEquals(File(root, "http_staging_v1"), one.file.parentFile)
            assertTrue(File(one.file.path.replace(".part", ".facts")).readText().contains("closed staged"))
            try { worker.resume(); fail() } catch (e: EngineProtocolException) { assertEquals("restartRequired", e.reason) }
            assertArrayEquals(bytes, one.file.readBytes())
        } finally { root.deleteRecursively() }
    }

    @Test fun unknownLengthGrowsBeforeEof() = server { server, base ->
        val firstWritten = CountDownLatch(1)
        val release = CountDownLatch(1)
        server.createContext("/chunked") { exchange ->
            exchange.sendResponseHeaders(200, 0)
            exchange.responseBody.use {
                it.write(ByteArray(4096) { 7 }); it.flush()
                firstWritten.countDown()
                release.await(5, TimeUnit.SECONDS)
                it.write(ByteArray(4096) { 9 })
            }
        }
        val root = root()
        val executor = Executors.newSingleThreadExecutor()
        val sample = CountDownLatch(1)
        val samples = java.util.Collections.synchronizedList(mutableListOf<HttpTransfer.Sample>())
        try {
            val task = executor.submit<HttpTransfer.Staged> {
                HttpTransfer(root).run(key, "$base/chunked") { samples.add(it); sample.countDown() }
            }
            assertTrue(firstWritten.await(5, TimeUnit.SECONDS))
            assertTrue(sample.await(5, TimeUnit.SECONDS))
            assertFalse(task.isDone)
            assertTrue(samples[0].bytes > 0)
            assertNull(samples[0].total)
            release.countDown()
            val result = task.get(5, TimeUnit.SECONDS)
            assertEquals(8192L, result.bytes)
            assertNull(result.total)
            assertTrue(samples.zipWithNext().all { (a, b) -> b.bytes > a.bytes && b.monotonicMs >= a.monotonicMs })
        } finally { release.countDown(); executor.shutdownNow(); root.deleteRecursively() }
    }

    @Test fun redirectsLoopLimitAndIllegalTargets() = server { server, base ->
        server.createContext("/ok") { it.sendResponseHeaders(200, 1); it.responseBody.use { out -> out.write(42) } }
        fun redirect(path: String, target: String) {
            server.createContext(path) { it.responseHeaders.add("Location", target); it.sendResponseHeaders(302, -1); it.close() }
        }
        redirect("/start", "/ok")
        redirect("/loop", "/loop")
        redirect("/auth", "http://user:secret@127.0.0.1/ok")
        redirect("/file", "file:///tmp/forbidden")
        for (i in 0..10) redirect("/r$i", if (i == 10) "/ok" else "/r${i + 1}")
        val root = root()
        try {
            val worker = HttpTransfer(root)
            assertEquals("$base/ok", worker.run(key, "$base/start").effectiveUrl)
            for ((path, reason) in listOf("loop" to "redirectLoop", "auth" to "invalidHttpUrl",
                "file" to "invalidHttpUrl", "r0" to "tooManyRedirects")) {
                try { worker.run(key, "$base/$path"); fail(path) } catch (e: HttpTransfer.Failure) {
                    assertEquals(reason, e.cause!!.message)
                    assertEquals(0L, e.material.length())
                }
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun shortEofRetainsActualBytesAndNeverStages() {
        val socket = ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1"))
        val thread = Thread {
            socket.accept().use { client ->
                val input = client.getInputStream().bufferedReader()
                while (!input.readLine().isNullOrEmpty()) { }
                client.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 4294967419\r\nConnection: close\r\n\r\nshort".toByteArray())
                client.getOutputStream().flush()
            }
        }
        thread.start()
        val root = root()
        try {
            var observedTotal: Long? = null
            try { HttpTransfer(root).run(key, "http://127.0.0.1:${socket.localPort}/") { observedTotal = it.total }; fail() }
            catch (e: HttpTransfer.Failure) {
                assertEquals(5L, e.bytes)
                assertEquals("short", e.material.readText())
                assertEquals(4294967419L, observedTotal)
                assertFalse(File(e.material.path.replace(".part", ".facts")).readText().contains("closed staged"))
            }
        } finally { socket.close(); thread.join(5000); root.deleteRecursively() }
    }

    @Test fun pauseAndCancelActuallyStopAndRetainPrivateData() = server { server, base ->
        server.createContext("/stream") { exchange ->
            try {
                exchange.sendResponseHeaders(200, 0)
                exchange.responseBody.use { out -> repeat(1000) { out.write(ByteArray(4096)); out.flush() } }
            } catch (_: java.io.IOException) { } finally { exchange.close() }
        }
        val root = root()
        try {
            for (reason in HttpTransfer.Stop.Reason.entries) {
                val stop = HttpTransfer.Stop()
                val result = HttpTransfer(root).run(key, "$base/stream", stop) { stop.request(reason) }
                assertEquals(reason, result.stop)
                assertTrue(result.bytes > 0)
                assertEquals(result.bytes, result.file.length())
                val before = result.file.readBytes()
                assertEquals(hash(before), result.sha256)
                assertArrayEquals(before, result.file.readBytes())
                assertTrue(File(result.file.path.replace(".part", ".facts")).readText().contains("closed ${reason.name}"))
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun existingFilesAndSymlinkStagingCannotBeOverwritten() {
        val root = root()
        val outside = root()
        val sentinel = File(outside, "keep").apply { writeText("untouched") }
        try {
            Files.createSymbolicLink(File(root, "http_staging_v1").toPath(), outside.toPath())
            try { HttpTransfer(root).run(key, "http://127.0.0.1:1/"); fail() }
            catch (_: IllegalArgumentException) { }
            assertEquals("untouched", sentinel.readText())
            assertEquals(listOf("keep"), outside.list()!!.toList())
            val alias = File(outside, "alias")
            Files.createSymbolicLink(alias.toPath(), root.toPath())
            try { HttpTransfer(alias).run(key, "http://127.0.0.1:1/"); fail() }
            catch (_: IllegalArgumentException) { }
        } finally { File(root, "http_staging_v1").delete(); File(outside, "alias").delete(); root.deleteRecursively(); outside.deleteRecursively() }
    }

    @Test fun httpAndConnectionFailuresPreserveMaterialAndCause() = server { server, base ->
        server.createContext("/denied") { it.sendResponseHeaders(403, -1); it.close() }
        val root = root()
        try {
            try { HttpTransfer(root).run(key, "$base/denied"); fail() } catch (e: HttpTransfer.Failure) {
                assertEquals("httpStatus:403", e.cause!!.message)
                assertTrue(e.material.exists())
            }
            val port = ServerSocket(0).use { it.localPort }
            try { HttpTransfer(root).run(key, "http://127.0.0.1:$port/"); fail() } catch (e: HttpTransfer.Failure) {
                assertTrue(e.cause is java.net.ConnectException)
                assertTrue(e.material.exists())
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun excessDecodedBodyCannotBeStaged() = server { server, base ->
        server.createContext("/excess") {
            it.responseHeaders.add("Transfer-Encoding", "chunked")
            it.sendResponseHeaders(200, 1)
            it.responseBody.use { out -> out.write("2\r\nab\r\n0\r\n\r\n".toByteArray()) }
        }
        val root = root()
        try {
            try { HttpTransfer(root).run(key, "$base/excess"); fail() }
            catch (error: HttpTransfer.Failure) {
                assertEquals("lengthExceeded", error.cause!!.message)
                assertEquals(0L, error.bytes)
                assertEquals(0L, error.material.length())
                assertFalse(File(error.material.path.replace(".part", ".facts")).readText().contains("closed"))
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun invalidResponseMetadataNeverStages() = server { server, base ->
        val cases = listOf(
            Triple("encoding", "Content-Encoding", "gzip"),
            Triple("negative", "Content-Length", "-1"),
            Triple("overflow", "Content-Length", "9223372036854775808"),
            Triple("malformed", "Content-Length", "abc")
        )
        for ((path, header, value) in cases) server.createContext("/$path") {
            it.responseHeaders.add(header, value)
            it.sendResponseHeaders(200, 0)
            it.responseBody.use { out -> out.write(byteArrayOf(1, 2)) }
        }
        val root = root()
        try {
            for ((path, _, _) in cases) {
                try { HttpTransfer(root).run(key, "$base/$path"); fail(path) }
                catch (error: HttpTransfer.Failure) {
                    assertEquals(if (path == "encoding") "unexpectedEncoding" else "invalidLength", error.cause!!.message)
                    assertEquals(0L, error.bytes)
                    assertFalse(File(error.material.path.replace(".part", ".facts")).readText().contains("closed"))
                }
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun callbackFailureCannotReportStagedOrPaused() = server { server, base ->
        server.createContext("/bytes") {
            it.sendResponseHeaders(200, 4); it.responseBody.use { out -> out.write(byteArrayOf(1, 2, 3, 4)) }
        }
        val root = root()
        try {
            val stop = HttpTransfer.Stop()
            try {
                HttpTransfer(root).run(key, "$base/bytes", stop) {
                    stop.request(HttpTransfer.Stop.Reason.PAUSE)
                    throw java.io.IOException("checkpointConsumerFailed")
                }
                fail()
            } catch (e: HttpTransfer.Failure) {
                assertEquals("checkpointConsumerFailed", e.cause!!.message)
                assertEquals(4L, e.material.length())
                assertFalse(File(e.material.path.replace(".part", ".facts")).readText().contains("closed"))
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun stopInterruptsBlockedReadAcrossThreads() = server { server, base ->
        val release = CountDownLatch(1)
        server.createContext("/blocked") { exchange ->
            exchange.sendResponseHeaders(200, 0)
            exchange.responseBody.write(byteArrayOf(42))
            exchange.responseBody.flush()
            check(release.await(8, TimeUnit.SECONDS))
        }
        val root = root()
        val executor = Executors.newFixedThreadPool(2)
        try {
            val stop = HttpTransfer.Stop()
            val sampled = CountDownLatch(1)
            val task = executor.submit<HttpTransfer.Staged> {
                HttpTransfer(root).run(key, "$base/blocked", stop) { sampled.countDown() }
            }
            assertTrue(sampled.await(3, TimeUnit.SECONDS))
            // The server withholds EOF and further bytes until after both stop barriers.
            try { task.get(150, TimeUnit.MILLISECONDS); fail("EOF must remain blocked") }
            catch (_: java.util.concurrent.TimeoutException) { }
            val request = executor.submit { stop.request(HttpTransfer.Stop.Reason.PAUSE) }
            request.get(3, TimeUnit.SECONDS)
            val result = task.get(3, TimeUnit.SECONDS)
            assertEquals(HttpTransfer.Stop.Reason.PAUSE, result.stop)
            assertEquals(1L, result.bytes)
            assertEquals(1L, result.file.length())
            assertTrue(File(result.file.path.replace(".part", ".facts")).readText().contains("closed PAUSE"))
        } finally {
            release.countDown()
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
            root.deleteRecursively()
        }
    }
}
package com.example.downloader.downloader

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.net.ServerSocket
import java.nio.file.Files
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Real socket/file transfers through the production coordinator; Journal below is a host fake. */
class TransferCoordinatorTest {
    private class Log(
        val root: File,
    ) : TransferCoordinator.Journal {
        val versions = mutableMapOf<ExecutionKey, Long>()
        val results = mutableMapOf<String, Map<String, Any?>?>()
        val payloads = mutableMapOf<String, Map<String, Any?>>()
        val receipts = mutableListOf<Map<String, Any?>>()
        var failWrites = false
        var allocationFailure = false
        var failTerminal = false
        var failTerminalKey: ExecutionKey? = null
        var ambiguousTerminal = false
        var finishAttempts = 0
        val terminalAttempted = CountDownLatch(1)
        private var durableTerminal: Map<String, Any?>? = null
        var allocationGate: CountDownLatch? = null
        val allocationEntered = CountDownLatch(1)

        override fun register(command: NativeCommand): Map<String, Any?>? {
            if (results.containsKey(command.commandId)) {
                if (payloads[command.commandId] != command.payload) conflict("commandPayloadChanged")
                return results[command.commandId] ?: conflict("commandOutcomeUnknown")
            }
            if ((versions[command.key] ?: 0L) != command.expectedReceiptVersion) conflict("staleReceipt")
            results[command.commandId] = null
            payloads[command.commandId] = command.payload
            return null
        }

        override fun accept(command: NativeCommand) =
            receipt(command, NativeCheckpoint("queued", 0)).also { results[command.commandId] = it }

        override fun transfer(command: NativeCommand) =
            HttpTransfer(root, EngineProtocol.string(EngineProtocol.map(command.payload["input"]), "url")) { _, _, _ ->
                allocationEntered.countDown()
                allocationGate?.await(5, TimeUnit.SECONDS)
                if (allocationFailure) throw IllegalStateException("allocation failure")
            }

        override fun stop(
            worker: NativeCommand,
            command: NativeCommand,
            checkpoint: NativeCheckpoint,
        ): Map<String, Any?> =
            if (command.method == "cancel") receipt(worker, checkpoint).also { results[command.commandId] = it } else emptyMap()

        override fun receipt(
            command: NativeCommand,
            checkpoint: NativeCheckpoint,
        ): Map<String, Any?> {
            if (failWrites) throw IllegalStateException("injected persistence failure")
            val version = (versions[command.key] ?: 0) + 1
            versions[command.key] = version
            return checkpoint.receipt(command.key, version).also { receipts.add(it) }
        }

        override fun finish(
            command: NativeCommand,
            checkpoint: NativeCheckpoint,
            pause: NativeCommand?,
        ): Map<String, Any?> {
            finishAttempts++
            terminalAttempted.countDown()
            if (failTerminal || failTerminalKey == command.key) throw java.io.IOException("terminal database fault")
            durableTerminal?.let { return it }
            return receipt(command, checkpoint).also {
                if (pause != null) results[pause.commandId] = it
                if (ambiguousTerminal) {
                    durableTerminal = it
                    ambiguousTerminal = false
                    throw java.io.IOException("commit returned uncertain")
                }
            }
        }
    }

    @Test fun refusedConnectionIsNetworkFailureAndRetainsMaterial() {
        val port = ServerSocket(0).use { it.localPort }
        Fixture().use { f ->
            f.start(command("refused", "http://127.0.0.1:$port/")).get(5, TimeUnit.SECONDS)
            assertTrue(f.idle.await(5, TimeUnit.SECONDS))
            val receipt = f.onQueue { f.log.receipts.last() }
            assertEquals("failed", receipt["state"])
            assertEquals("networkUnavailable", (receipt["error"] as Map<*, *>)["code"])
            assertTrue(f.root.walk().any { it.extension == "part" })
        }
    }

    @Test fun failedPauseReplayRemainsFailure() {
        Fixture().use { f ->
            val gate = CountDownLatch(1)
            f.log.allocationGate = gate
            f.log.allocationFailure = true
            val c = command("a", "http://127.0.0.1:1/")
            f.start(c).get(5, TimeUnit.SECONDS)
            assertTrue(f.log.allocationEntered.await(5, TimeUnit.SECONDS))
            val p = command("p", "", "pause", f.onQueue { f.log.versions[c.key]!! }, c.key)
            val paused = f.coordinator.command(p)
            f.onQueue { }
            gate.countDown()
            rejected(paused)
            assertEquals("failed", f.onQueue { f.log.results["p"]!!["state"] })
            rejected(f.coordinator.command(p))
        }
    }

    @Test fun throwingConsumerCannotPreventLaunchOrDurablePause() {
        Fixture().use { f ->
            f.throwEvents = true
            val c = command("a", "http://127.0.0.1:1/")
            val accepted = f.coordinator.command(c)
            f.onQueue { }
            assertEquals(1, f.tokens.size)
            val p = command("p", "", "pause", f.onQueue { f.log.versions[c.key]!! }, c.key)
            val paused = f.coordinator.command(p).get(5, TimeUnit.SECONDS)
            assertEquals("paused", paused["state"])
            assertTrue(f.onQueue { f.log.receipts.contains(paused) })
            assertFalse(f.onQueue { f.coordinator.serviceReady(f.tokens.single()) })
            // A pending service start that was stopped must not leave its caller hanging.
            assertTrue(accepted.isDone)
        }
    }

    private class Fixture : AutoCloseable {
        val root = Files.createTempDirectory("coordinator").toFile().canonicalFile
        val queue = Executors.newSingleThreadExecutor()
        val log = Log(root)
        val events = mutableListOf<Map<String, Any?>>()
        val published = java.util.concurrent.ConcurrentHashMap<ExecutionKey, CountDownLatch>()
        val tokens = mutableListOf<String>()
        val idle = CountDownLatch(1)
        var throwEvents = false
        val coordinator =
            TransferCoordinator("s", queue, log, { tokens.add(it) }, { idle.countDown() }, {
                assertTrue("events follow durable receipts", log.receipts.contains(it["receipt"]))
                if (throwEvents) throw IllegalStateException("consumer unavailable")
                events.add(it)
                val receipt = it["receipt"] as Map<*, *>
                if (receipt["state"] == "publishing") {
                    published.entries.firstOrNull { entry -> entry.key.json() == receipt["key"] }?.value?.countDown()
                }
            })

        fun <T> onQueue(action: () -> T): T = queue.submit<T> { action() }.get(5, TimeUnit.SECONDS)

        fun start(command: NativeCommand): CompletableFuture<Map<String, Any?>> {
            val result = coordinator.command(command)
            onQueue { } // enqueue has run
            onQueue { coordinator.serviceReady(tokens.last()) }
            return result
        }

        override fun close() {
            onQueue { coordinator.restrict() }
            if (onQueue { coordinator.hasWork() }) idle.await(5, TimeUnit.SECONDS)
            queue.shutdownNow()
            root.deleteRecursively()
        }
    }

    private fun command(
        id: String,
        url: String,
        method: String = "enqueue",
        version: Long = 0,
        key: ExecutionKey = ExecutionKey(id, id, 0),
    ): NativeCommand =
        EngineProtocol.command(
            method,
            buildMap {
                put("protocolVersion", 1)
                put("commandId", id)
                putAll(
                    mapOf(
                        "taskId" to key.taskId,
                        "engineId" to key.engineId,
                        "generation" to key.generation,
                    ),
                )
                put("ownerSessionId", "s")
                put("expectedReceiptVersion", version)
                if (method ==
                    "enqueue"
                ) {
                    put(
                        "input",
                        mapOf(
                            "protocolVersion" to 1,
                            "key" to key.json(),
                            "url" to url,
                            "stagingLocation" to "private",
                            "directory" to
                                mapOf("version" to 1, "platform" to "android", "kind" to "systemDownloads", "displayName" to "Downloads"),
                        ),
                    )
                }
            },
        )

    private fun rejected(result: CompletableFuture<*>) {
        try {
            result.get(5, TimeUnit.SECONDS)
            fail("must reject")
        } catch (_: java.util.concurrent.ExecutionException) {
        }
    }

    @Test fun realHttpPersistsBeforeEventsAndReplayNeverRetransmits() {
        ServerSocket(0).use { server ->
            val requests = AtomicInteger()
            val responder =
                Thread {
                    server.accept().use { socket ->
                        requests.incrementAndGet()
                        socket.getInputStream().bufferedReader().let { while (!it.readLine().isNullOrEmpty()) { } }
                        socket.getOutputStream().write("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nhello".toByteArray())
                    }
                }.also { it.start() }
            Fixture().use { f ->
                val c = command("a", "http://127.0.0.1:${server.localPort}/")
                f.start(c).get(5, TimeUnit.SECONDS)
                assertTrue(f.idle.await(5, TimeUnit.SECONDS))
                val final = f.onQueue { f.log.receipts.last() }
                assertEquals("publishing", final["state"])
                assertEquals(5L, final["downloadedBytes"])
                assertNull(final["totalBytes"])
                f.coordinator.command(c).get(5, TimeUnit.SECONDS)
                assertEquals(1, requests.get())
                assertFalse(f.onQueue { f.coordinator.serviceReady(f.tokens.first()) })
                assertFalse(f.onQueue { f.coordinator.serviceReady(null) })
                assertTrue(f.events.zipWithNext().all { (a, b) -> (a["sequence"] as Long) < (b["sequence"] as Long) })
            }
            responder.join(5000)
        }
    }

    @Test fun pauseWaitsForActualWorkerExitAndCancelWinsLateCompletion() {
        Fixture().use { f ->
            val gate = CountDownLatch(1)
            f.log.allocationGate = gate
            val c = command("a", "http://127.0.0.1:1/")
            f.start(c).get(5, TimeUnit.SECONDS)
            assertTrue(f.log.allocationEntered.await(5, TimeUnit.SECONDS))
            val version = f.onQueue { f.log.versions[c.key]!! }
            val pause = f.coordinator.command(command("p", "", "pause", version, c.key))
            f.onQueue { }
            assertFalse("pause cannot resolve while worker is inside run", pause.isDone)
            val cancel = f.coordinator.command(command("x", "", "cancel", version, c.key))
            rejected(cancel)
            assertEquals("cancelling", f.onQueue { f.log.receipts.last()["state"] })
            gate.countDown()
            assertTrue(f.idle.await(5, TimeUnit.SECONDS))
            rejected(pause)
            assertEquals("cancelling", f.onQueue { f.log.receipts.last()["state"] })
            assertTrue(f.root.walk().any { it.extension == "part" })
        }
    }

    @Test fun twoWorkersMaximumAndQueuedPauseHasNoRequest() {
        ServerSocket(0).use { server ->
            val accepted = CountDownLatch(2)
            val release = CountDownLatch(1)
            val requests = AtomicInteger()
            val sockets = mutableListOf<java.net.Socket>()
            val responder =
                Thread {
                    repeat(2) {
                        val socket = server.accept()
                        sockets.add(socket)
                        requests.incrementAndGet()
                        accepted.countDown()
                    }
                    release.await(5, TimeUnit.SECONDS)
                    sockets.forEach { socket ->
                        socket.use { it.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".toByteArray()) }
                    }
                }.also { it.start() }
            Fixture().use { f ->
                val url = "http://127.0.0.1:${server.localPort}/"
                f.start(command("a", url))
                f.start(command("b", url))
                val third = command("c", url)
                f.start(third)
                assertTrue(accepted.await(5, TimeUnit.SECONDS))
                assertEquals(2, requests.get())
                val version = f.onQueue { f.log.versions[third.key]!! }
                val paused = f.coordinator.command(command("p", "", "pause", version, third.key)).get(5, TimeUnit.SECONDS)
                assertEquals("paused", paused["state"])
                release.countDown()
                assertTrue(f.idle.await(5, TimeUnit.SECONDS))
                assertEquals(2, requests.get())
            }
            responder.join(5000)
        }
    }

    @Test fun pauseCompletesOnlyAfterClosedRunAndPersistentReceipt() {
        Fixture().use { f ->
            val gate = CountDownLatch(1)
            f.log.allocationGate = gate
            val c = command("a", "http://127.0.0.1:1/")
            f.start(c).get(5, TimeUnit.SECONDS)
            assertTrue(f.log.allocationEntered.await(5, TimeUnit.SECONDS))
            val version = f.onQueue { f.log.versions[c.key]!! }
            val paused = f.coordinator.command(command("p", "", "pause", version, c.key))
            f.onQueue { }
            assertFalse(paused.isDone)
            gate.countDown()
            val receipt = paused.get(5, TimeUnit.SECONDS)
            assertEquals("paused", receipt["state"])
            assertTrue(f.root.walk().filter { it.extension == "facts" }.single().readText().contains("closed PAUSE"))
            assertTrue(f.log.receipts.contains(receipt))
            // A fresh process coordinator sharing retained facts consumes no old Intent.
            f.onQueue {
                val reopened = TransferCoordinator("new-session", f.queue, f.log, { fail("unexpected launch") }, {}, {})
                assertFalse(reopened.serviceReady("old-token"))
                assertFalse(reopened.serviceReady(null))
                assertFalse(reopened.hasWork())
            }
        }
    }

    @Test fun terminalPersistenceFailureRetainsStoppedWorkAndExplicitRetryOnlySavesLocally() {
        ServerSocket(0).use { server ->
            val requests = AtomicInteger()
            val responder = Thread {
                server.accept().use { socket ->
                    requests.incrementAndGet()
                    socket.getInputStream().bufferedReader().let { while (!it.readLine().isNullOrEmpty()) { } }
                    socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc".toByteArray())
                }
            }.also { it.start() }
            Fixture().use { f ->
                f.log.failTerminal = true
                val c = command("retained", "http://127.0.0.1:${server.localPort}/")
                f.start(c).get(5, TimeUnit.SECONDS)
                assertTrue(f.idle.await(5, TimeUnit.SECONDS))
                assertEquals(1, f.onQueue { f.coordinator.pendingSaveCount() })
                assertTrue(f.onQueue { f.coordinator.hasWork() })
                val version = f.onQueue { f.log.versions[c.key]!! }
                val eventCount = f.events.size
                try { f.onQueue { f.coordinator.assertInspectable() }; fail() } catch (_: java.util.concurrent.ExecutionException) { }
                rejected(f.coordinator.command(c))
                assertEquals(version, f.onQueue { f.log.versions[c.key] })
                assertEquals(eventCount, f.events.size)
                f.onQueue { f.log.failTerminal = false; f.log.ambiguousTerminal = true }
                rejected(f.coordinator.command(c)) // commit happened but the result was lost
                val committedVersion = f.onQueue { f.log.versions[c.key]!! }
                val receipt = f.coordinator.command(c).get(5, TimeUnit.SECONDS)
                assertEquals("publishing", receipt["state"])
                assertEquals(committedVersion, receipt["receiptVersion"])
                assertEquals(0, f.onQueue { f.coordinator.pendingSaveCount() })
                assertEquals(1, requests.get())
                f.coordinator.command(c).get(5, TimeUnit.SECONDS)
                assertEquals(1, requests.get())
                assertTrue(f.root.walk().any { it.extension == "part" && it.length() == 3L })
            }
            responder.join(5000)
        }
    }

    @Test fun cancelReplayKeepsCommittedCleanupFailureWhileTerminalSaveIsPending() {
        Fixture().use { f ->
            val c = command("a", "http://127.0.0.1:1/")
            val accepted = f.coordinator.command(c)
            f.onQueue { f.log.failTerminal = true }
            val cancel = command("cancel", "", "cancel", f.onQueue { f.log.versions[c.key]!! }, c.key)
            fun assertCancelFailure() {
                try { f.coordinator.command(cancel).get(5, TimeUnit.SECONDS); fail("must reject cleanup") }
                catch (error: java.util.concurrent.ExecutionException) {
                    assertEquals("cleanupFailure", (error.cause as EngineProtocolException).code)
                }
            }
            assertCancelFailure()
            f.onQueue { }
            assertEquals(1, f.onQueue { f.coordinator.pendingSaveCount() })
            val attempts = f.onQueue { f.log.finishAttempts }
            val committed = f.onQueue { f.log.results[cancel.commandId] }
            assertCancelFailure()
            assertEquals(attempts, f.onQueue { f.log.finishAttempts })
            assertEquals(committed, f.onQueue { f.log.results[cancel.commandId] })
            f.onQueue { f.log.failTerminal = false }
            assertEquals("cancelling", f.coordinator.command(c).get(5, TimeUnit.SECONDS)["state"])
            assertCancelFailure()
            assertEquals(1, f.tokens.size)
            assertTrue(f.root.list()!!.isEmpty())
            assertTrue(accepted.isDone)
        }
    }

    @Test fun stoppedPauseRetrySavesSameCheckpointWithoutAnotherWorker() {
        Fixture().use { f ->
            val gate = CountDownLatch(1)
            f.log.allocationGate = gate
            val c = command("a", "http://127.0.0.1:1/")
            f.start(c).get(5, TimeUnit.SECONDS)
            assertTrue(f.log.allocationEntered.await(5, TimeUnit.SECONDS))
            val version = f.onQueue { f.log.versions[c.key]!! }
            val pause = command("pause", "", "pause", version, c.key)
            f.onQueue { f.log.failTerminal = true }
            val result = f.coordinator.command(pause)
            f.onQueue { }
            gate.countDown()
            rejected(result)
            assertEquals(1, f.onQueue { f.coordinator.pendingSaveCount() })
            val tokenCount = f.tokens.size
            val attempts = f.onQueue { f.log.finishAttempts }
            rejected(f.coordinator.command(command("pause", "", "pause", version + 1, c.key)))
            rejected(f.coordinator.command(c.copy(payload = c.payload + ("altered" to true))))
            rejected(f.coordinator.command(pause.copy(payload = pause.payload + ("ownerSessionId" to "old"))))
            assertEquals(attempts, f.onQueue { f.log.finishAttempts })
            f.onQueue { f.log.failTerminal = false }
            val retry1 = f.coordinator.command(pause)
            val retry2 = f.coordinator.command(pause)
            val receipt = retry1.get(5, TimeUnit.SECONDS)
            assertEquals("paused", receipt["state"])
            assertEquals(receipt, retry2.get(5, TimeUnit.SECONDS))
            assertEquals(receipt, f.coordinator.command(pause).get(5, TimeUnit.SECONDS))
            assertEquals(tokenCount, f.tokens.size)
        }
    }

    @Test fun timeoutSignalsBeforeBlockedCoordinatorAndOldDestroyCannotStopNewWork() {
        Fixture().use { f ->
            val c = command("a", "http://127.0.0.1:1/")
            val accepted = f.coordinator.command(c)
            f.onQueue { }
            val token = f.tokens.single()
            assertTrue(f.coordinator.lifecycle.foreground(token, "old") {})
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            f.queue.execute { entered.countDown(); release.await(5, TimeUnit.SECONDS) }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val owned = f.coordinator.lifecycle.destroy("old")
            assertFalse(f.coordinator.lifecycle.ready(token, "old"))
            f.queue.execute { f.coordinator.restrict(owned = owned) }
            release.countDown()
            rejected(accepted)
            val next = f.coordinator.command(command("b", "http://127.0.0.1:1/"))
            f.onQueue { }
            val newToken = f.tokens.last()
            assertTrue(f.coordinator.lifecycle.foreground(newToken, "new") {})
            val stale = f.coordinator.lifecycle.destroy("old")
            assertTrue(stale.isEmpty())
            f.onQueue { f.coordinator.restrict(owned = stale); f.coordinator.serviceReady(newToken, "new") }
            next.get(5, TimeUnit.SECONDS)
        }
    }

    @Test fun retainedTerminalSaveDoesNotStarveOtherRealHttpWorkers() {
        ServerSocket(0).use { server ->
            val requests = AtomicInteger()
            val responder = Thread {
                repeat(2) {
                    server.accept().use { socket ->
                        requests.incrementAndGet()
                        socket.getInputStream().bufferedReader().let { while (!it.readLine().isNullOrEmpty()) { } }
                        socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx".toByteArray())
                    }
                }
            }.also { it.start() }
            Fixture().use { f ->
                val first = command("a", "http://127.0.0.1:${server.localPort}/")
                f.log.failTerminalKey = first.key
                f.start(first).get(5, TimeUnit.SECONDS)
                assertTrue(f.idle.await(5, TimeUnit.SECONDS))
                assertEquals(1, f.onQueue { f.coordinator.pendingSaveCount() })
                val second = command("b", "http://127.0.0.1:${server.localPort}/")
                val finished = CountDownLatch(1)
                f.published[second.key] = finished
                f.start(second).get(5, TimeUnit.SECONDS)
                assertTrue(finished.await(5, TimeUnit.SECONDS))
                responder.join(5000)
                assertEquals(1, f.onQueue { f.coordinator.pendingSaveCount() })
                assertEquals(2, requests.get())
            }
        }
    }

    @Test fun cancelledPostedForegroundNeverRunsAndAcceptedFutureTerminates() {
        Fixture().use { f ->
            val c = command("a", "http://127.0.0.1:1/")
            val accepted = f.coordinator.command(c)
            f.onQueue { }
            val token = f.tokens.single()
            var delayed: (() -> Unit)? = null
            f.coordinator.lifecycle.pending(token) { delayed = { f.coordinator.lifecycle.foreground(token, "service") { fail("cancelled foreground") }; Unit } }
            val version = f.onQueue { f.log.versions[c.key]!! }
            rejected(f.coordinator.command(command("x", "", "cancel", version, c.key)))
            accepted.get(5, TimeUnit.SECONDS)
            delayed!!()
            assertFalse(f.onQueue { f.coordinator.serviceReady(token, "service") })
            assertTrue(f.root.list()!!.isEmpty())
            assertEquals("cancelling", f.onQueue { f.log.receipts.last()["state"] })
        }
    }

    @Test fun unknownResultOldSessionAndRestartHaveZeroLaunches() {
        Fixture().use { f ->
            val c = command("a", "http://127.0.0.1:1/")
            f.onQueue { f.log.register(c) }
            rejected(f.coordinator.command(c))
            rejected(f.coordinator.command(c.copy(ownerSessionId = "old", payload = c.payload + ("ownerSessionId" to "old"))))
            assertTrue(f.tokens.isEmpty())
            assertFalse(f.onQueue { f.coordinator.serviceReady("old-intent") })
        }
    }

    @Test fun persistenceFailureDoesNotEmitOrLaunch() {
        Fixture().use { f ->
            f.log.failWrites = true
            rejected(f.coordinator.command(command("a", "http://127.0.0.1:1/")))
            assertTrue(f.events.isEmpty())
            assertTrue(f.tokens.isEmpty())
        }
    }
}

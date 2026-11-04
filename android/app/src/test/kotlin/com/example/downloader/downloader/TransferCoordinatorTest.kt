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
        var terminalAttempted = CountDownLatch(1)
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

        val proofs = java.util.concurrent.ConcurrentHashMap<ExecutionKey, NativeResumeMaterial>()
        val frozen = mutableMapOf<String, NativeResumeMaterial>()
        val candidates = java.util.concurrent.CopyOnWriteArrayList<File>()
        var session = "s"
        var recoveryOverride: ((NativeCommand) -> ResumeTransfer)? = null
        val stopIntents = mutableMapOf<String, String>()

        override fun acceptResume(command: NativeCommand): Pair<Map<String, Any?>, Boolean> {
            if (results.containsKey(command.commandId)) return register(command)!! to true
            if (command.ownerSessionId != session) conflict("staleSession")
            if (receipts.lastOrNull { it["key"] == command.key.json() }?.get("state") in listOf("publishing", "cancelling")) conflict("restartRequired")
            val proof = proofs[command.key] ?: conflict("restartRequired")
            register(command)
            frozen[command.commandId] = proof
            return receipt(command, NativeCheckpoint("queued", proof.forced.offset, proof.forced.total)).also { results[command.commandId] = it } to false
        }

        override fun recovery(command: NativeCommand) = recoveryOverride?.invoke(command) ?: ResumeTransfer(root, frozen[command.commandId]!!,
            { _, file -> candidates.add(file) }, {}, {}, onCheckpoint = { id, forced ->
                proofs[command.key] = NativeResumeMaterial(id, command.commandId, versions[command.key]!!, forced)
            })

        override fun transfer(command: NativeCommand) =
            HttpTransfer(root, EngineProtocol.string(EngineProtocol.map(command.payload["input"]), "url"), onCheckpoint = { forced ->
                proofs[command.key] = NativeResumeMaterial("initial", command.commandId, versions[command.key]!!, forced)
            }) { _, _, _ ->
                allocationEntered.countDown()
                allocationGate?.await(5, TimeUnit.SECONDS)
                if (allocationFailure) throw IllegalStateException("allocation failure")
            }

        override fun stop(
            worker: NativeCommand,
            command: NativeCommand,
            checkpoint: NativeCheckpoint,
        ): Map<String, Any?> {
            stopIntents[worker.commandId] = command.method
            return if (command.method == "cancel") receipt(worker, checkpoint).also { results[command.commandId] = it } else emptyMap()
        }

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
        val progress = java.util.concurrent.ConcurrentHashMap<Long, CountDownLatch>()
        val coordinator =
            TransferCoordinator("s", queue, log, { tokens.add(it) }, { idle.countDown() }, {
                assertTrue("events follow durable receipts", log.receipts.contains(it["receipt"]))
                if (throwEvents) throw IllegalStateException("consumer unavailable")
                events.add(it)
                progress[(it["downloadedBytes"] as Number).toLong()]?.countDown()
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

    private fun seedProof(f: Fixture, key: ExecutionKey, url: String): NativeResumeMaterial {
        val directory = File(f.root, "http_staging_v1").apply { mkdirs() }
        val source = File(directory, "${java.util.UUID.randomUUID()}.part").apply { writeBytes(ByteArray(24576) { 7 }) }
        val proof = NativeResumeMaterial("host-durable-proof", "old", 1, ForcedMaterial(key, source, 8192, 16384, url, "\"strong\"", NativePrefixDigest.read(source, 8192).snapshot()))
        f.log.proofs[key] = proof; f.log.versions[key] = 1
        return proof
    }

    @Test fun publicPrefixAndCopyStopsPreserveSourceWithoutPromotingPartialCandidate() {
        for (copying in listOf(false, true)) for (method in listOf("pause", "cancel")) publicRecoveryStop(copying, method, false)
    }

    @Test fun publicCopyPauseCannotHideCloseFailure() = publicRecoveryStop(true, "pause", true)

    @Test fun publicPauseProofFailureAndPersistedCancelNeverPromoteCandidate() {
        for (method in listOf("pause", "cancel")) ServerSocket(0).use { server ->
            val requests = AtomicInteger()
            val responder = Thread { server.accept().use { socket ->
                requests.incrementAndGet()
                socket.getInputStream().bufferedReader().let { while (!it.readLine().isNullOrEmpty()) { } }
                socket.getOutputStream().write("HTTP/1.1 206 Partial Content\r\nETag: \"strong\"\r\nContent-Range: bytes 8192-16383/16384\r\nContent-Length: 8192\r\nConnection: close\r\n\r\n".toByteArray() + ByteArray(8192) { 8 })
            } }.apply { isDaemon = true; start() }
            Fixture().use { f ->
                val key = ExecutionKey("proof-race", "proof-race", 0)
                val source = seedProof(f, key, "http://127.0.0.1:${server.localPort}/")
                val original = source.forced.source.readBytes()
                val entered = CountDownLatch(1); val release = CountDownLatch(1)
                f.log.recoveryOverride = { c -> ResumeTransfer(f.root, f.log.frozen[c.commandId]!!,
                    { _, file -> f.log.candidates.add(file) }, { fail("stopped staged") }, {},
                    onCheckpoint = { _, _ ->
                        entered.countDown(); check(release.await(5, TimeUnit.SECONDS))
                        // Host callback models the native serialized persistent-stop check; not SQLite evidence.
                        assertEquals(method, f.onQueue { f.log.stopIntents[c.commandId] })
                        if (method == "cancel") conflict("stateConflict") else throw java.io.IOException("proof commit failed")
                    }) }
                val c = command("proof-race-resume", "", "resume", 1, key)
                f.start(c).get(5, TimeUnit.SECONDS); assertTrue(entered.await(5, TimeUnit.SECONDS))
                val stopCommand = command("proof-stop", "", method, f.onQueue { f.log.versions[key]!! }, key)
                val stopped = f.coordinator.command(stopCommand)
                f.onQueue { }; release.countDown(); rejected(stopped)
                assertTrue(f.idle.await(5, TimeUnit.SECONDS))
                val terminal = f.onQueue { f.log.receipts.last() }
                assertEquals(if (method == "cancel") "cancelling" else "failed", terminal["state"])
                assertEquals(if (method == "cancel") "cleanupFailure" else "persistenceFailure", (terminal["error"] as Map<*, *>) ["code"])
                assertEquals(source, f.log.proofs[key]); assertArrayEquals(original, source.forced.source.readBytes())
                assertEquals(1, requests.get()); assertEquals(1, f.log.candidates.size)
                if (method == "cancel") try { f.coordinator.command(stopCommand).get(5, TimeUnit.SECONDS); fail() }
                catch (error: java.util.concurrent.ExecutionException) { assertEquals("cleanupFailure", (error.cause as EngineProtocolException).code) }
                f.coordinator.command(c).get(5, TimeUnit.SECONDS); assertEquals(1, requests.get())
            }
            responder.join(1000)
        }
    }

    private fun publicRecoveryStop(copying: Boolean, method: String, failClose: Boolean) {
        ServerSocket(0).use { server ->
            val requests = AtomicInteger()
            val responder = if (copying) Thread { server.accept().use { socket ->
                requests.incrementAndGet()
                socket.getInputStream().bufferedReader().let { while (!it.readLine().isNullOrEmpty()) { } }
                socket.getOutputStream().write("HTTP/1.1 206 Partial Content\r\nETag: \"strong\"\r\nContent-Range: bytes 8192-16383/16384\r\nContent-Length: 8192\r\nConnection: close\r\n\r\n".toByteArray() + ByteArray(8192) { 8 })
            } }.apply { isDaemon = true; start() } else null
            Fixture().use { f ->
                val key = ExecutionKey("combination", "combination", 0)
                val source = seedProof(f, key, "http://127.0.0.1:${server.localPort}/")
                val original = source.forced.source.readBytes()
                val entered = CountDownLatch(1)
                val release = CountDownLatch(1)
                var closes = 0
                val barrier: (Long) -> Unit = { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
                f.log.recoveryOverride = { c -> ResumeTransfer(f.root, f.log.frozen[c.commandId]!!,
                    { _, file -> f.log.candidates.add(file) }, { fail("stopped staged") }, {},
                    closeCandidate = { it.close(); if (++closes == 1 && failClose) throw java.io.IOException("copy close failed") },
                    onCheckpoint = { _, _ -> fail("partial prefix advanced proof") },
                    verifiedPrefix = if (copying) ({}) else barrier,
                    copiedPrefix = if (copying) barrier else ({}) ) }
                val resume = command("combination-resume", "", "resume", 1, key)
                f.start(resume).get(5, TimeUnit.SECONDS)
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                val stop = f.coordinator.command(command("combination-stop", "", method, f.onQueue { f.log.versions[key]!! }, key))
                f.onQueue { } // stop intent commits before releasing the actual prefix/copy worker
                release.countDown()
                if (method == "cancel" || failClose) rejected(stop) else assertEquals("paused", stop.get(5, TimeUnit.SECONDS)["state"])
                assertTrue(f.idle.await(5, TimeUnit.SECONDS))
                val terminal = f.onQueue { f.log.receipts.last() }
                assertEquals(if (method == "cancel") "cancelling" else if (failClose) "failed" else "paused", terminal["state"])
                if (failClose) assertEquals("fileWriteFailure", (terminal["error"] as Map<*, *>) ["code"])
                assertEquals(source, f.log.proofs[key]); assertArrayEquals(original, source.forced.source.readBytes())
                assertEquals(if (copying) 1 else 0, requests.get()); assertEquals(if (copying) 1 else 0, f.log.candidates.size)
                f.coordinator.command(resume).get(5, TimeUnit.SECONDS)
                assertEquals(if (copying) 1 else 0, requests.get())
            }
            responder?.join(1000)
        }
    }

    @Test fun publicUnsafeRangeResponsesKeepOriginalAndNeverCreateCandidate() {
        for (response in listOf(
            "HTTP/1.1 200 OK\r\nETag: \"strong\"\r\n",
            "HTTP/1.1 416 Range Not Satisfiable\r\nETag: \"strong\"\r\n",
            "HTTP/1.1 206 Partial Content\r\nETag: \"changed\"\r\nContent-Range: bytes 8192-16383/16384\r\n",
            "HTTP/1.1 206 Partial Content\r\nETag: \"strong\"\r\nContent-Range: bytes 8191-16383/16384\r\n",
        )) ServerSocket(0).use { server ->
            val requests = AtomicInteger()
            val responder = Thread { server.accept().use { socket ->
                requests.incrementAndGet()
                val reader = socket.getInputStream().bufferedReader()
                val headers = buildList { while (true) { val line = reader.readLine(); if (line.isNullOrEmpty()) break; add(line) } }
                assertTrue(headers.any { it.equals("Range: bytes=8192-", true) })
                socket.getOutputStream().write((response + "Content-Length: 8192\r\nConnection: close\r\n\r\n").toByteArray() + ByteArray(8192))
            } }.apply { isDaemon = true; start() }
            Fixture().use { f ->
                val key = ExecutionKey("unsafe", "unsafe", 0)
                val source = seedProof(f, key, "http://127.0.0.1:${server.localPort}/").forced.source
                val original = source.readBytes()
                val c = command("unsafe-resume", "", "resume", 1, key)
                f.start(c).get(5, TimeUnit.SECONDS)
                assertTrue(f.idle.await(5, TimeUnit.SECONDS))
                val terminal = f.onQueue { f.log.receipts.last() }
                assertEquals("failed", terminal["state"])
                assertEquals("stateConflict", (terminal["error"] as Map<*, *>)["code"])
                assertEquals(0, f.log.candidates.size); assertArrayEquals(original, source.readBytes())
                f.coordinator.command(c).get(5, TimeUnit.SECONDS)
                rejected(f.coordinator.command(command("stale", "", "resume", 1, key)))
                val unknown = command("null", "", "resume", f.onQueue { f.log.versions[key]!! }, key)
                f.log.results[unknown.commandId] = null; f.log.payloads[unknown.commandId] = unknown.payload
                rejected(f.coordinator.command(unknown))
                rejected(f.coordinator.command(EngineProtocol.command("resume", c.payload + ("ownerSessionId" to "old"))))
                assertEquals(1, requests.get()); assertEquals(1, f.tokens.size)
            }
            responder.join(1000)
        }
    }

    @Test fun publicCorruptPrefixFailsBeforeAnyGetAndPreservesTail() {
        ServerSocket(0).use { server -> Fixture().use { f ->
            val key = ExecutionKey("corrupt", "corrupt", 0)
            val proof = seedProof(f, key, "http://127.0.0.1:${server.localPort}/")
            java.io.RandomAccessFile(proof.forced.source, "rw").use { it.write(42) }
            val original = proof.forced.source.readBytes()
            f.start(command("corrupt-resume", "", "resume", 1, key)).get(5, TimeUnit.SECONDS)
            assertTrue(f.idle.await(5, TimeUnit.SECONDS))
            val terminal = f.onQueue { f.log.receipts.last() }
            assertEquals("stateConflict", (terminal["error"] as Map<*, *>)["code"])
            assertEquals("restartRequired", ((terminal["error"] as Map<*, *>)["details"] as Map<*, *>)["reason"])
            assertArrayEquals(original, proof.forced.source.readBytes()); assertEquals(0, f.log.candidates.size)
            server.soTimeout = 100
            try { server.accept().use { fail("corrupt prefix initiated HTTP") } } catch (_: java.net.SocketTimeoutException) { }
        } }
    }

    @Test fun newRuntimeIsIdleUntilExplicitCurrentSessionResume() {
        ServerSocket(0).use { server ->
            val requests = AtomicInteger()
            val responder = Thread { server.accept().use { socket ->
                requests.incrementAndGet()
                socket.getInputStream().bufferedReader().let { while (!it.readLine().isNullOrEmpty()) { } }
                socket.getOutputStream().write("HTTP/1.1 206 Partial Content\r\nETag: \"strong\"\r\nContent-Range: bytes 8192-16383/16384\r\nContent-Length: 8192\r\nConnection: close\r\n\r\n".toByteArray() + ByteArray(8192) { 8 })
            } }.apply { isDaemon = true; start() }
            Fixture().use { f ->
                val key = ExecutionKey("reopen", "reopen", 0)
                seedProof(f, key, "http://127.0.0.1:${server.localPort}/")
                f.log.session = "new"
                val tokens = mutableListOf<String>()
                val terminal = CountDownLatch(1)
                val reopened = TransferCoordinator("new", f.queue, f.log, { tokens.add(it) }, {}, { event ->
                    assertTrue(f.log.receipts.contains(event["receipt"]))
                    if ((event["receipt"] as Map<*, *>)["state"] == "publishing") terminal.countDown()
                })
                f.onQueue { reopened.assertInspectable(); assertFalse(reopened.hasWork()) }
                assertEquals(0, requests.get()); assertTrue(tokens.isEmpty())
                val old = command("reopen-user", "", "resume", 1, key)
                rejected(reopened.command(old))
                assertEquals(0, requests.get())
                val current = EngineProtocol.command("resume", old.payload + ("ownerSessionId" to "new"))
                val accepted = reopened.command(current)
                f.onQueue { reopened.serviceReady(tokens.single()) }
                accepted.get(5, TimeUnit.SECONDS)
                assertTrue(terminal.await(5, TimeUnit.SECONDS))
                reopened.command(current).get(5, TimeUnit.SECONDS)
                assertEquals(1, requests.get()); assertEquals(1, tokens.size)
            }
            responder.join(1000)
        }
    }

    @Test fun resumeWorkersShareGlobalTwoWorkerPool() {
        ServerSocket(0).use { server ->
            val firstTwo = CountDownLatch(2)
            val release = CountDownLatch(1)
            val requests = AtomicInteger()
            val responder = Thread { repeat(3) {
                val socket = server.accept()
                Thread { socket.use {
                    requests.incrementAndGet(); firstTwo.countDown()
                    socket.getInputStream().bufferedReader().let { while (!it.readLine().isNullOrEmpty()) { } }
                    release.await(5, TimeUnit.SECONDS)
                    socket.getOutputStream().write("HTTP/1.1 206 Partial Content\r\nETag: \"strong\"\r\nContent-Range: bytes 8192-16383/16384\r\nContent-Length: 8192\r\nConnection: close\r\n\r\n".toByteArray() + ByteArray(8192) { 8 })
                } }.apply { isDaemon = true; start() }
            } }.apply { isDaemon = true; start() }
            Fixture().use { f ->
                val commands = (0..2).map { index ->
                    val key = ExecutionKey("cap$index", "cap$index", 0)
                    seedProof(f, key, "http://127.0.0.1:${server.localPort}/")
                    f.published[key] = CountDownLatch(1)
                    command("resume$index", "", "resume", 1, key)
                }
                commands.forEach { f.start(it).get(5, TimeUnit.SECONDS) }
                assertTrue(firstTwo.await(5, TimeUnit.SECONDS))
                f.onQueue { }
                assertEquals(2, requests.get())
                f.coordinator.command(commands.first()).get(5, TimeUnit.SECONDS)
                assertEquals(3, f.tokens.size)
                release.countDown()
                commands.forEach { assertTrue(f.published[it.key]!!.await(5, TimeUnit.SECONDS)) }
                assertEquals(3, requests.get())
            }
            responder.join(1000)
        }
    }

    @Test fun publicResumeQueuedPauseAndCancelNeverAcquireWorkerOrNetwork() {
        for (method in listOf("pause", "cancel")) Fixture().use { f ->
            val key = ExecutionKey("queued", "queued", 0)
            val source = seedProof(f, key, "http://127.0.0.1:1/").forced.source
            val original = source.readBytes()
            val c = command("queued-resume", "", "resume", 1, key)
            val accepted = f.coordinator.command(c)
            f.onQueue { }
            val stop = f.coordinator.command(command("stop", "", method, f.onQueue { f.log.versions[key]!! }, key))
            if (method == "pause") assertEquals("paused", stop.get(5, TimeUnit.SECONDS)["state"]) else rejected(stop)
            f.onQueue { } // cancel reports its cleanup failure before the rest of this queue action finishes
            assertTrue(accepted.isDone)
            assertFalse(f.onQueue { f.coordinator.serviceReady(f.tokens.single()) })
            assertEquals(0, f.log.candidates.size); assertArrayEquals(original, source.readBytes())
        }
    }

    @Test fun publicResumeRunsRealRangeAndContinuesNewCandidate() = publicResumeCycle(false)

    @Test fun publicResumeTerminalRetryOnlySavesWithoutNewGetOrCandidate() = publicResumeCycle(true)

    private fun publicResumeCycle(saveFailure: Boolean) {
        ServerSocket(0).use { server ->
            val requests = java.util.concurrent.CopyOnWriteArrayList<List<String>>()
            val responseRelease = listOf(CountDownLatch(1), CountDownLatch(1))
            val responder = Thread {
                repeat(3) { index -> server.accept().use { socket ->
                    val reader = socket.getInputStream().bufferedReader()
                    requests.add(buildList { while (true) { val line = reader.readLine(); if (line.isNullOrEmpty()) break; add(line) } })
                    val response = when (index) {
                        0 -> "HTTP/1.1 200 OK\r\nETag: \"strong\"\r\nConnection: close\r\n\r\n"
                        1 -> "HTTP/1.1 206 Partial Content\r\nETag: \"strong\"\r\nContent-Range: bytes 8192-32767/32768\r\nContent-Length: 24576\r\nConnection: close\r\n\r\n"
                        else -> "HTTP/1.1 206 Partial Content\r\nETag: \"strong\"\r\nContent-Range: bytes 16384-32767/32768\r\nContent-Length: 16384\r\nConnection: close\r\n\r\n"
                    }
                    socket.getOutputStream().write(response.toByteArray() + ByteArray(if (index == 2) 16384 else 8192) { (7 + index * 2).toByte() })
                    socket.getOutputStream().flush()
                    if (index < 2) responseRelease[index].await(5, TimeUnit.SECONDS)
                } }
            }.apply { isDaemon = true; start() }
            Fixture().use { f ->
                val enqueue = command("public", "http://127.0.0.1:${server.localPort}/")
                f.progress[8192L] = CountDownLatch(1)
                f.start(enqueue).get(5, TimeUnit.SECONDS)
                assertTrue(f.progress[8192L]!!.await(5, TimeUnit.SECONDS))
                fun control(id: String, method: String) = command(id, "", method, f.onQueue { f.log.versions[enqueue.key]!! }, enqueue.key)
                val firstStop = f.coordinator.command(control("p-first", "pause"))
                f.onQueue { }; responseRelease[0].countDown()
                assertEquals("paused", firstStop.get(5, TimeUnit.SECONDS)["state"])
                val initial = f.log.proofs[enqueue.key]!!
                assertNull(initial.forced.total); assertEquals(8192L, initial.forced.offset)
                initial.forced.source.appendBytes(ByteArray(16384) { 99 }) // uncommitted tail, never promoted
                val originalBytes = initial.forced.source.readBytes()
                val resume = control("r-first", "resume")
                f.progress[16384L] = CountDownLatch(1)
                f.start(resume).get(5, TimeUnit.SECONDS)
                assertTrue(f.progress[16384L]!!.await(5, TimeUnit.SECONDS))
                f.coordinator.command(resume).get(5, TimeUnit.SECONDS)
                assertEquals(2, requests.size)
                val secondStop = f.coordinator.command(control("p-second", "pause"))
                f.onQueue { }; responseRelease[1].countDown()
                assertEquals("paused", secondStop.get(5, TimeUnit.SECONDS)["state"])
                val branch = f.log.proofs[enqueue.key]!!
                assertEquals(16384L, branch.forced.offset); assertEquals(32768L, branch.forced.total)
                assertNotEquals(initial.forced.source, branch.forced.source)
                val branchBytes = branch.forced.source.readBytes()
                val next = control("r-second", "resume")
                val published = CountDownLatch(1)
                f.published[enqueue.key] = published
                if (saveFailure) { f.log.failTerminal = true; f.log.terminalAttempted = CountDownLatch(1) }
                f.start(next).get(5, TimeUnit.SECONDS)
                if (saveFailure) {
                    assertTrue(f.log.terminalAttempted.await(5, TimeUnit.SECONDS))
                    assertEquals(1, f.onQueue { f.coordinator.pendingSaveCount() })
                    try { f.onQueue { f.coordinator.assertInspectable() }; fail() } catch (_: java.util.concurrent.ExecutionException) { }
                    assertEquals(2, f.log.candidates.size)
                    f.log.failTerminal = false
                    assertEquals("publishing", f.coordinator.command(next).get(5, TimeUnit.SECONDS)["state"])
                }
                assertTrue(published.await(5, TimeUnit.SECONDS))
                val terminal = f.onQueue { f.log.receipts.last() }
                val output = File(terminal["stagingLocation"] as String)
                val expected = ByteArray(8192) { 7 } + ByteArray(8192) { 9 } + ByteArray(16384) { 11 }
                assertArrayEquals(expected, output.readBytes())
                assertEquals(java.security.MessageDigest.getInstance("SHA-256").digest(expected).toList(), java.security.MessageDigest.getInstance("SHA-256").digest(output.readBytes()).toList())
                assertArrayEquals(originalBytes, initial.forced.source.readBytes()); assertArrayEquals(branchBytes, branch.forced.source.readBytes())
                f.coordinator.command(next).get(5, TimeUnit.SECONDS)
                assertEquals(3, requests.size); assertEquals(2, f.log.candidates.size)
                assertTrue(requests[1].any { it.equals("Range: bytes=8192-", true) })
                assertTrue(requests[2].any { it.equals("Range: bytes=16384-", true) })
            }
            responder.join(1000)
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

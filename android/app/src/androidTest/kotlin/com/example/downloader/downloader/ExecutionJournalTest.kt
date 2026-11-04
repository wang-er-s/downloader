package com.example.downloader.downloader

import android.app.Instrumentation
import android.app.Activity
import android.os.Bundle
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.Executors

/** Real Android SQLite tests, using a dependency-free instrumentation runner. */
class ExecutionJournalTest : Instrumentation() {
    private lateinit var journal: ExecutionJournal
    private lateinit var name: String
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }
    override fun onStart() {
        val output = Bundle()
        try {
            for (test in listOf(::testHandshakePersistenceReplayAndAck, ::testIdentityPayloadAndRollback, ::testConcurrentAllocationGateAcrossConnections)) {
                name = "journal-test-${UUID.randomUUID()}.db"
                journal = ExecutionJournal(targetContext, name)
                try { test() } finally { journal.close() }
            }
            output.putString("stream", "PASS 3 real Android SQLite tests")
            finish(Activity.RESULT_OK, output)
        } catch (error: Throwable) {
            output.putString("stream", error.stackTraceToString())
            finish(Activity.RESULT_CANCELED, output)
        }
    }
    private fun assertEquals(expected: Any?, actual: Any?) { check(expected == actual) { "$expected != $actual" } }
    private fun assertTrue(value: Boolean) { check(value) }
    private fun assertNull(value: Any?) { check(value == null) }
    private fun fail(message: String): Nothing = throw AssertionError(message)

    private fun command(
        id: String = "c",
        version: Long = 0,
        generation: Long = 0,
        method: String = "enqueue",
        session: String = "s",
    ): NativeCommand {
        val key = ExecutionKey("t", "e", generation)
        val payload =
            mapOf<String, Any?>(
                "protocolVersion" to 1,
                "taskId" to "t",
                "engineId" to "e",
                "generation" to generation,
                "commandId" to id,
                "ownerSessionId" to session,
                "expectedReceiptVersion" to version,
            )
        return NativeCommand(method, id, key, session, version, payload)
    }

    private fun rejects(
        reason: String,
        action: () -> Unit,
    ) {
        try {
            action()
            fail("accepted conflict")
        } catch (error: EngineProtocolException) {
            assertEquals(reason, error.reason)
        }
    }

    fun testHandshakePersistenceReplayAndAck() {
        assertTrue(journal.inspect().isEmpty())
        val c = command()
        assertNull(journal.register(c, "s"))
        rejects("commandOutcomeUnknown") { journal.register(c, "s") }
        val receipt = journal.complete(c, "s", NativeCheckpoint("paused", 5_000_000_000, resumeRef = "owned-ref"))
        assertEquals(receipt, journal.register(c, "s"))
        assertEquals(journal.inspect(), journal.inspect())
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        assertEquals(receipt, journal.inspect().single())
        val next = command("next", 1, method = "pause")
        journal.register(next, "s")
        journal.complete(next, "s", NativeCheckpoint("paused", 5_000_000_001, resumeRef = "new-ref"))
        assertEquals(2, journal.inspect().size)
        journal.acknowledge(NativeAck(c.key, 1, emptyList()))
        assertEquals(1, journal.inspect().size)
        assertEquals("new-ref", journal.inspect().single()["resumeRef"])
        rejects("materialReleaseUnavailable") { journal.acknowledge(NativeAck(c.key, 1, listOf("new-ref"))) }
        rejects("staleReceipt") { journal.acknowledge(NativeAck(c.key, 3, emptyList())) }
        journal.acknowledge(NativeAck(c.key, 2, emptyList()))
        journal.acknowledge(NativeAck(c.key, 1, emptyList()))
        assertEquals(2L, journal.inspect().single()["receiptVersion"])
    }

    fun testIdentityPayloadAndRollback() {
        val c = command()
        rejects("staleSession") { journal.register(c, "new-process") }
        assertTrue(journal.inspect().isEmpty())
        journal.register(c, "s")
        rejects("commandPayloadChanged") { journal.register(c.copy(payload = c.payload + ("extra" to true)), "s") }
        // Abort after receipt INSERT but before execution/result UPDATE: all must roll back.
        journal.writableDatabase.execSQL("CREATE TRIGGER fail_update BEFORE UPDATE ON executions BEGIN SELECT RAISE(ABORT,'injected'); END")
        try {
            journal.complete(c, "s", NativeCheckpoint("paused", 9))
            fail("injection ignored")
        } catch (
            _: android.database.sqlite.SQLiteException,
        ) {
        }
        assertTrue(journal.inspect().isEmpty())
        rejects("commandOutcomeUnknown") { journal.register(c, "s") }
        journal.writableDatabase.execSQL("DROP TRIGGER fail_update")
        assertEquals(1L, journal.complete(c, "s", NativeCheckpoint("paused", 9))["receiptVersion"])
        rejects("staleReceipt") { journal.register(command("old", 0, method = "pause"), "s") }
        val newer = command("new", 0, 1)
        journal.register(newer, "s")
        rejects("staleExecution") { journal.register(command("late", 1, method = "pause"), "s") }
        rejects("staleExecution") { journal.acknowledge(NativeAck(ExecutionKey("foreign", "e", 0), 1, emptyList())) }
        assertEquals(9L, journal.inspect().single()["downloadedBytes"])
    }

    fun testConcurrentAllocationGateAcrossConnections() {
        val first = command()
        journal.register(first, "s")
        journal.complete(first, "s", NativeCheckpoint("paused", 0))
        val pool = Executors.newFixedThreadPool(4)
        try {
            val results =
                pool
                    .invokeAll(
                        (1..8).map { n ->
                            Callable {
                                ExecutionJournal(targetContext, name).use { other ->
                                    val c = command("race-$n", 1, method = "pause")
                                    try {
                                        other.register(c, "s")
                                        other.complete(c, "s", NativeCheckpoint("paused", n.toLong()))
                                        true
                                    } catch (_: EngineProtocolException) {
                                        false
                                    }
                                }
                            }
                        },
                    ).map { it.get() }
            assertEquals(1, results.count { it })
            assertEquals(listOf(1L, 2L), journal.inspect().map { it["receiptVersion"] })
        } finally {
            pool.shutdownNow()
        }
    }
}

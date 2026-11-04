package com.example.downloader.downloader

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.Executors

/** Real Android SQLite tests, using a dependency-free instrumentation runner. */
class ExecutionJournalTest : Instrumentation() {
    private lateinit var journal: ExecutionJournal
    private lateinit var name: String
    private val responders = mutableListOf<Thread>()
    private var responderFailures = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()

    private fun responder(action: () -> Unit): Thread {
        // Capture the owning case: a timed-out responder must not blame a later case.
        val failures = responderFailures
        return Thread(action).apply {
            isDaemon = true
            uncaughtExceptionHandler = Thread.UncaughtExceptionHandler { _, error -> failures.add(error) }
            responders.add(this)
            start()
        }
    }

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val tests =
            listOf(
                ::testHandshakePersistenceReplayAndAck,
                ::testIdentityPayloadAndRollback,
                ::testConcurrentAllocationGateAcrossConnections,
                ::testMaterialRegistrationAndClosedCheckpoint,
                ::testMaterialInsertFailureCreatesNothing,
                ::testV1MigrationAndFailurePreserveHistory,
                ::testWorkerLifecycleAndStopAuthorization,
                ::testV2MigrationPreservesUnknownCommands,
                ::testWorkerCommandBindingAndCancelCannotBeRevoked,
                ::testUnknownVersionPreservesHistory,
                ::testTerminalSaveRollbackAndIdempotentRetry,
                ::testProductionForcedCheckpointAndV3Migration,
                ::testV3MigrationFailurePreservesHistory,
                ::testCancelledWorkerCannotPromoteOrRecoverProof,
                ::testV4CandidateProofMigrationRetainsHistory,
                ::testPublicResumeAtomicVersionAndRetirement,
                ::testV5MigrationRollback,
                ::testPublicPersistedCancelBlocksProofAndLateStaging,
                ::testCancelCleanupReopenOwnershipAndRollback,
                ::testV6CleanupMigrationRollback,
            )
        var failures = 0
        for ((index, test) in tests.withIndex()) {
            fun status() =
                Bundle().apply {
                    putString("id", "ExecutionJournalTest")
                    putString("class", ExecutionJournalTest::class.java.name)
                    putString("test", test.name)
                    putInt("numtests", tests.size)
                    putInt("current", index + 1)
                }
            sendStatus(1, status())
            responderFailures = java.util.concurrent.ConcurrentLinkedQueue()
            var failure: Throwable? = null
            var opened: ExecutionJournal? = null
            try {
                name = "journal-test-${UUID.randomUUID()}.db"
                journal = ExecutionJournal(targetContext, name)
                opened = journal
                test()
            } catch (error: Throwable) {
                failure = error
            } finally {
                try {
                    if (opened != null) journal.close()
                } catch (error: Throwable) {
                    if (failure == null) failure = error else failure.addSuppressed(error)
                }
            }
            for (responder in responders) {
                try {
                    responder.join(5000)
                } catch (error: InterruptedException) {
                    responderFailures.add(error)
                }
                if (responder.isAlive) responderFailures.add(AssertionError("loopback responder did not stop in ${test.name}"))
            }
            responders.clear()
            while (true) {
                val error = responderFailures.poll() ?: break
                if (failure == null) failure = error else failure.addSuppressed(error)
            }
            val result = status()
            if (failure == null) {
                result.putString("stream", ".")
                sendStatus(0, result)
            } else {
                failures++
                result.putString("stack", failure.stackTraceToString())
                result.putString("stream", "\n${test.name}:\n${failure.stackTraceToString()}\n")
                sendStatus(-2, result)
            }
        }
        val output =
            Bundle().apply {
                putInt("numtests", tests.size)
                putInt("failures", failures)
                putString(
                    "stream",
                    if (failures == 0) {
                        "\nOK (${tests.size} tests)\n"
                    } else {
                        "\nFAILURES!!! Tests run: ${tests.size}, Failures: $failures\n"
                    },
                )
            }
        // Standard instrumentation completion; per-test statuses determine test success.
        finish(Activity.RESULT_OK, output)
    }

    private fun assertEquals(
        expected: Any?,
        actual: Any?,
    ) {
        check(expected == actual) { "$expected != $actual" }
    }

    private fun assertTrue(value: Boolean) {
        check(value)
    }

    private fun assertNull(value: Any?) {
        check(value == null)
    }

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
                "input" to
                    mapOf(
                        "protocolVersion" to 1,
                        "key" to key.json(),
                        "url" to "http://127.0.0.1:1/",
                        "stagingLocation" to "private",
                        "directory" to
                            mapOf(
                                "version" to 1,
                                "platform" to "android",
                                "kind" to "systemDownloads",
                                "displayName" to "Downloads",
                            ),
                    ),
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

    fun testCancelCleanupReopenOwnershipAndRollback() {
        val c = command()
        journal.register(c, "s")
        journal.acceptWorker(c, "s")
        val directory = java.io.File(targetContext.filesDir.canonicalFile, "http_staging_v1").apply { mkdirs() }
        val id = UUID.randomUUID().toString()
        val part = java.io.File(directory, "$id.part")
        val facts = java.io.File(directory, "$id.facts")
        journal.registerMaterials(c, "s", part, facts)
        part.writeText("prefix-tail")
        facts.writeText("facts")
        val proof = ForcedMaterial(c.key, part, 4, 20, "http://127.0.0.1:1/", "\"strong\"", NativePrefixDigest.read(part, 4).snapshot())
        journal.saveResumeCheckpoint(c, "s", proof)
        val ref = journal.inspectResume(c.key)!!.ref
        val recovery = command("registered-candidate", 1, method = "resume")
        journal.register(recovery, "s")
        val candidateId = UUID.randomUUID().toString()
        val candidate = java.io.File(directory, "$candidateId.part").apply { writeText("partial") }
        val candidateFacts = java.io.File(directory, "$candidateId.facts").apply { writeText("facts") }
        journal.writableDatabase.execSQL(
            "INSERT INTO recovery_operations(id,resume_command,source_ref,candidate,phase) VALUES(?,?,?,?,?)",
            arrayOf(candidateId, recovery.commandId, ref, candidate.path, "copying"),
        )
        journal.writableDatabase.execSQL(
            "INSERT INTO recovery_candidate_files(operation_id,facts_path) VALUES(?,?)",
            arrayOf(candidateId, candidateFacts.path),
        )
        val cancel = command("cancel-v7", 1, method = "cancel")
        // Foreign command -> this root must reject, rather than silently omit its candidate.
        val originalRecovery = ExecutionJournal.encode(mapOf("method" to recovery.method, "arguments" to recovery.payload))
        val foreignRecovery =
            ExecutionJournal.encode(
                mapOf(
                    "method" to recovery.method,
                    "arguments" to (recovery.payload + ("taskId" to "foreign") + ("engineId" to "foreign")),
                ),
            )
        journal.writableDatabase.execSQL("UPDATE commands SET payload=? WHERE id=?", arrayOf(foreignRecovery, recovery.commandId))
        rejects("materialOwnership") { journal.beginCancel(cancel, "s", c, NativeCheckpoint("cancelling", 11)) }
        assertTrue(part.exists())
        assertTrue(candidate.exists())
        assertEquals(1, journal.inspect().size)
        journal.writableDatabase.execSQL("UPDATE commands SET payload=? WHERE id=?", arrayOf(originalRecovery, recovery.commandId))
        // Both proof and operation have valid FKs; an inconsistent facts edge is still forbidden.
        journal.writableDatabase.execSQL(
            "INSERT INTO candidate_checkpoints(operation_id,resume_command,source_ref,source_version,receipt_version,offset,total,url,etag,digest,algorithm,facts_path) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            arrayOf<Any>(
                candidateId,
                recovery.commandId,
                ref,
                1,
                1,
                4,
                20,
                proof.effectiveUrl,
                proof.etag,
                proof.prefixDigest,
                proof.algorithm,
                facts.path,
            ),
        )
        rejects("materialOwnership") { journal.beginCancel(cancel, "s", c, NativeCheckpoint("cancelling", 11)) }
        assertTrue(part.exists())
        assertTrue(candidate.exists())
        assertEquals(1, journal.inspect().size)
        journal.writableDatabase.execSQL("DELETE FROM candidate_checkpoints WHERE operation_id=?", arrayOf(candidateId))
        journal.writableDatabase.execSQL(
            "CREATE TRIGGER fail_cleanup BEFORE INSERT ON cancel_cleanup_members BEGIN SELECT RAISE(ABORT,'injected'); END",
        )
        try {
            journal.beginCancel(cancel, "s", c, NativeCheckpoint("cancelling", 11))
            fail("intent must roll back")
        } catch (
            _: android.database.sqlite.SQLiteException,
        ) {
        }
        assertTrue(part.exists())
        assertEquals(1, journal.inspect().size)
        journal.writableDatabase.execSQL("DROP TRIGGER fail_cleanup")
        val accepted = journal.beginCancel(cancel, "s", c, NativeCheckpoint("cancelling", 11))
        rejects("transferUnavailable") { journal.finishCancel(cancel, "s") }
        journal.finishWorker(c, "s", NativeCheckpoint("cancelling", 11, error = mapOf("code" to "cleanupFailure")), null)
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        journal.inspect()
        assertTrue(part.exists()) // open/read does not clean
        journal.writableDatabase.execSQL("UPDATE commands SET payload=? WHERE id=?", arrayOf(foreignRecovery, recovery.commandId))
        rejects("materialOwnership") { journal.finishCancel(cancel, "s") }
        assertTrue(part.exists())
        assertTrue(candidate.exists())
        journal.writableDatabase.execSQL("UPDATE commands SET payload=? WHERE id=?", arrayOf(originalRecovery, recovery.commandId))
        val outside = java.io.File(targetContext.cacheDir, "cleanup-sentinel-${UUID.randomUUID()}").apply { writeText("sentinel") }
        facts.delete()
        java.nio.file.Files
            .createSymbolicLink(facts.toPath(), outside.toPath())
        try {
            journal.finishCancel(cancel, "s")
            fail("symlink must reject whole collection")
        } catch (
            error: EngineProtocolException,
        ) {
            assertEquals("cleanupFailure", error.code)
        }
        assertTrue(part.exists())
        assertEquals("sentinel", outside.readText())
        java.nio.file.Files
            .delete(facts.toPath())
        facts.writeText("facts")
        journal.writableDatabase.execSQL(
            "CREATE TRIGGER fail_cleanup_receipt BEFORE INSERT ON receipts BEGIN SELECT RAISE(ABORT,'injected final save'); END",
        )
        try {
            journal.finishCancel(cancel, "s")
            fail("final save must fail")
        } catch (_: android.database.sqlite.SQLiteException) {
        }
        assertTrue(!part.exists() && !candidate.exists()) // registered missing files can finish locally
        journal.writableDatabase.rawQuery("SELECT result,phase FROM cancel_cleanups WHERE command_id=?", arrayOf(cancel.commandId)).use {
            it.moveToFirst()
            assertTrue(it.isNull(0))
            assertEquals("pending", it.getString(1))
        }
        journal.writableDatabase.execSQL("DROP TRIGGER fail_cleanup_receipt")
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        val done = journal.finishCancel(cancel, "s")
        assertTrue(!part.exists() && !facts.exists() && !candidate.exists() && !candidateFacts.exists())
        assertNull(done["error"])
        assertEquals(accepted, journal.register(cancel, "s"))
        assertEquals(done, journal.finishCancel(cancel, "s"))
        rejects("materialReleaseUnavailable") { journal.acknowledge(NativeAck(c.key, done["receiptVersion"] as Long, listOf("unknown"))) }
        outside.delete()
    }

    fun testV6CleanupMigrationRollback() {
        val c = command()
        journal.register(c, "s")
        val receipt = journal.complete(c, "s", NativeCheckpoint("paused", 0))
        val db = journal.writableDatabase
        db.execSQL("DROP TABLE cancel_cleanup_members")
        db.execSQL("DROP TABLE cancel_cleanups")
        db.version = 6
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        assertEquals(7, journal.writableDatabase.version)
        assertEquals(receipt, journal.inspect().single())
        journal.writableDatabase.execSQL("DROP TABLE cancel_cleanups") // second DDL conflicts
        journal.writableDatabase.version = 6
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        try {
            journal.inspect()
            fail("migration must fail")
        } catch (_: android.database.sqlite.SQLiteException) {
        }
        journal.close()
        android.database.sqlite.SQLiteDatabase.openDatabase(targetContext.getDatabasePath(name).path, null, 0).use { old ->
            assertEquals(6, old.version)
            old.rawQuery("SELECT COUNT(*) FROM sqlite_master WHERE name='cancel_cleanups'", null).use {
                it.moveToFirst()
                assertEquals(0, it.getInt(0))
            }
            old.execSQL("DROP TABLE cancel_cleanup_members")
        }
        journal = ExecutionJournal(targetContext, name)
        assertEquals(receipt, journal.inspect().single())
        assertEquals(7, journal.writableDatabase.version)
    }

    fun testCancelledWorkerCannotPromoteOrRecoverProof() {
        val c = command()
        journal.register(c, "s")
        journal.acceptWorker(c, "s")
        val directory = java.io.File(targetContext.filesDir.canonicalFile, "http_staging_v1").apply { mkdirs() }
        val id = UUID.randomUUID().toString()
        val source = java.io.File(directory, "$id.part")
        val facts = java.io.File(directory, "$id.facts")
        journal.registerMaterials(c, "s", source, facts)
        java.io.FileOutputStream(source).use {
            it.write(ByteArray(8) { 7 })
            it.channel.force(true)
        }
        facts.writeText("test diagnostic")
        val proof = ForcedMaterial(c.key, source, 4, 16, "http://127.0.0.1:1/", "\"strong\"", NativePrefixDigest.read(source, 4).snapshot())
        journal.saveResumeCheckpoint(c, "s", proof)
        val saved = journal.inspectResume(c.key)!!
        val cancel = command("cancel", 1, method = "cancel")
        journal.register(cancel, "s")
        journal.stopWorker(c, cancel, "s", NativeCheckpoint("cancelling", 8))
        journal.saveResumeCheckpoint(c, "s", proof.copy(offset = 8, prefixDigest = NativePrefixDigest.read(source, 8).snapshot()))
        assertEquals(saved, journal.inspectResume(c.key))
        val terminal = journal.finishWorker(c, "s", NativeCheckpoint("cancelling", 8), null)
        val resume = command("resume", terminal["receiptVersion"] as Long, method = "resume")
        journal.register(resume, "s")
        rejects("restartRequired") { journal.newRecovery(resume, "s", saved.ref) }
        rejects("staleReceipt") { journal.saveResumeCheckpoint(c, "s", proof) }
    }

    fun testWorkerCommandBindingAndCancelCannotBeRevoked() {
        val c = command()
        journal.register(c, "s")
        val accepted = journal.acceptWorker(c, "s")
        val changed = c.copy(payload = c.payload + ("extra" to "changed"))
        rejects("commandPayloadChanged") { journal.workerReceipt(changed, "s", NativeCheckpoint("running", 0)) }
        assertEquals(listOf(accepted), journal.inspect())
        val cancel = command("cancel", 1, method = "cancel")
        journal.register(cancel, "s")
        val cancelling = journal.stopWorker(c, cancel, "s", NativeCheckpoint("cancelling", 0))
        rejects("stateConflict") { journal.workerReceipt(c, "s", NativeCheckpoint("publishing", 0)) }
        val pause = command("pause", 2, method = "pause")
        journal.register(pause, "s")
        rejects("commandOutcomeUnknown") { journal.stopWorker(c, pause, "s", NativeCheckpoint("running", 0)) }
        val terminal = journal.finishWorker(c, "s", NativeCheckpoint("cancelling", 0), null)
        assertEquals("cancelling", terminal["state"])
        assertEquals(cancelling, journal.register(cancel, "s"))
        assertEquals(accepted, journal.register(c, "s"))
    }

    fun testTerminalSaveRollbackAndIdempotentRetry() {
        val c = command()
        journal.register(c, "s")
        journal.acceptWorker(c, "s")
        val pause = command("p", 1, method = "pause")
        journal.register(pause, "s")
        journal.stopWorker(c, pause, "s", NativeCheckpoint("running", 0))
        val checkpoint = NativeCheckpoint("paused", 7)
        journal.writableDatabase.execSQL(
            "CREATE TRIGGER fail_terminal BEFORE INSERT ON receipts BEGIN SELECT RAISE(ABORT,'terminal injection'); END",
        )
        try {
            journal.finishWorker(c, "s", checkpoint, pause)
            fail("write must fail")
        } catch (
            _: android.database.sqlite.SQLiteException,
        ) {
        }
        assertEquals(1L, journal.inspect().single()["receiptVersion"])
        rejects("commandOutcomeUnknown") { journal.register(pause, "s") }
        journal.writableDatabase.execSQL("DROP TRIGGER fail_terminal")
        val receipt = journal.finishWorker(c, "s", checkpoint, pause)
        assertEquals(receipt, journal.finishWorker(c, "s", checkpoint, pause))
        assertEquals(receipt, journal.register(pause, "s"))
        rejects("receiptPayload") { journal.finishWorker(c, "s", NativeCheckpoint("paused", 8), pause) }
        assertEquals(2, journal.inspect().size)
    }

    fun testProductionForcedCheckpointAndV3Migration() {
        // First prove v3->v4 retains unknown results, with no automatic worker creation.
        val c0 = command("unknown", generation = 0)
        journal.register(c0, "s")
        dropResumeTables(journal.writableDatabase)
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanup_members")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanups")
        journal.writableDatabase.version = 3
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        assertEquals(7, journal.writableDatabase.version)
        rejects("commandOutcomeUnknown") { journal.register(c0, "s") }
        java.net.ServerSocket(0).use { server ->
            val responder =
                responder {
                    repeat(2) { index ->
                        server.accept().use { socket ->
                            val reader = socket.getInputStream().bufferedReader()
                            val request =
                                buildList {
                                    while (true) {
                                        val line = reader.readLine() ?: break
                                        if (line.isEmpty()) break
                                        add(line)
                                    }
                                }
                            if (index == 1) {
                                assertTrue(request.any { it.equals("Range: bytes=8192-", true) })
                                socket.getOutputStream().write(
                                    ("HTTP/1.1 206 Partial Content\r\nETag: \"strong\"\r\nContent-Range: bytes 8192-16383/16384\r\nContent-Length: 8192\r\nConnection: close\r\n\r\n").toByteArray() +
                                        ByteArray(8192) { 9 },
                                )
                            } else {
                                socket.getOutputStream().write(
                                    ("HTTP/1.1 200 OK\r\nETag: \"strong\"\r\nConnection: close\r\n\r\n").toByteArray() +
                                        ByteArray(8192) { 7 },
                                )
                            }
                        }
                    }
                }
            val original = command("new", generation = 1)
            val input = EngineProtocol.map(original.payload["input"]) + ("url" to "http://127.0.0.1:${server.localPort}/")
            val c = EngineProtocol.command("enqueue", original.payload + ("input" to input))
            journal.register(c, "s")
            journal.acceptWorker(c, "s")
            val stop = HttpTransfer.Stop()
            val result =
                journal.newTransfer(c, "s").run(c.key, input["url"] as String, stop) {
                    assertNull(journal.inspectResume(c.key)) // sample precedes force
                    if (it.bytes >= 8192) stop.request(HttpTransfer.Stop.Reason.PAUSE)
                }
            val saved = journal.inspectResume(c.key)!!
            assertEquals(8192L, saved.forced.offset)
            assertNull(saved.forced.total) // original total unknown; safe 206 may establish it
            assertEquals(NativePrefixDigest.read(result.file, saved.forced.offset).snapshot(), saved.forced.prefixDigest)
            assertEquals("\"strong\"", saved.forced.etag)
            rejects("restartRequired") { journal.saveResumeCheckpoint(c, "s", saved.forced.copy(prefixDigest = "00".repeat(32))) }
            rejects("restartRequired") { journal.saveResumeCheckpoint(c, "s", saved.forced.copy(total = 20000)) }
            val pause = command("p", 1, generation = 1, method = "pause")
            journal.register(pause, "s")
            journal.stopWorker(c, pause, "s", NativeCheckpoint("running", result.bytes))
            val receipt = journal.finishWorker(c, "s", NativeCheckpoint("paused", result.bytes), pause)
            assertEquals(receipt["receiptVersion"], journal.inspectResume(c.key)!!.receiptVersion)
            journal.close()
            journal = ExecutionJournal(targetContext, name)
            assertEquals(saved.forced, journal.inspectResume(c.key)!!.forced)
            val resume = command("resume", receipt["receiptVersion"] as Long, generation = 1, method = "resume")
            journal.register(resume, "s")
            rejects("restartRequired") { journal.newRecovery(resume, "s", "unknown-ref") }
            rejects("staleSession") { journal.newRecovery(resume.copy(ownerSessionId = "old"), "s", saved.ref) }
            val recovery = journal.newRecovery(resume, "s", saved.ref)
            // Factory construction alone never requests HTTP or creates a candidate.
            journal.readableDatabase.rawQuery("SELECT COUNT(*) FROM recovery_attempts", null).use {
                it.moveToFirst()
                assertEquals(0, it.getInt(0))
            }
            journal.writableDatabase.execSQL("UPDATE resume_checkpoints SET receipt_version=1 WHERE ref=?", arrayOf(saved.ref))
            rejects("restartRequired") { recovery.run() } // authorization is checked again at run, before GET
            journal.writableDatabase.execSQL(
                "UPDATE resume_checkpoints SET receipt_version=? WHERE ref=?",
                arrayOf(receipt["receiptVersion"], saved.ref),
            )
            val originalBytes = result.file.readBytes().toList()
            val candidate = journal.newRecovery(resume, "s", saved.ref).run()
            assertEquals(16384L, candidate.file.length())
            assertEquals(originalBytes, result.file.readBytes().toList())
            assertEquals("staged", journal.inspectRecoveries(c.key).single()["phase"])
            val branch = journal.inspectCandidate(c.key, resume.commandId)!!
            assertEquals(candidate.file, branch.forced.source)
            assertEquals(candidate.bytes, branch.forced.offset)
            assertEquals(16384L, branch.forced.total)
            assertEquals(saved.ref, branch.sourceRef)
            assertEquals(receipt["receiptVersion"], branch.sourceReceiptVersion)
            assertEquals(NativePrefixDigest.read(candidate.file, candidate.bytes).snapshot(), branch.forced.prefixDigest)
            assertNull(journal.inspectCandidate(c.key, "another-command"))
            assertEquals(saved.forced.source, journal.inspectResume(c.key)!!.forced.source) // candidate is not an implicit active branch
            journal.close()
            journal = ExecutionJournal(targetContext, name)
            assertEquals(branch, journal.inspectCandidate(c.key, resume.commandId))
            rejects("commandOutcomeUnknown") { journal.newRecovery(resume, "s", saved.ref) }
            rejects("staleExecution") { journal.inspectCandidate(c.key.copy(taskId = "other-task"), resume.commandId) }
            val otherGeneration = command("other-generation", generation = 2)
            journal.register(otherGeneration, "s")
            assertNull(journal.inspectCandidate(otherGeneration.key, resume.commandId))
            responder.join(5000)
        }
    }

    fun testV4CandidateProofMigrationRetainsHistory() {
        val c = command()
        journal.register(c, "s")
        val receipt = journal.complete(c, "s", NativeCheckpoint("paused", 9))
        journal.writableDatabase.execSQL("DROP TABLE candidate_checkpoints")
        journal.writableDatabase.execSQL("DROP TABLE recovery_candidate_files")
        dropPublicResumeTables(journal.writableDatabase)
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanup_members")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanups")
        journal.writableDatabase.version = 4
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        assertEquals(7, journal.writableDatabase.version)
        assertEquals(receipt, journal.inspect().single())
        assertNull(journal.inspectCandidate(c.key, "none"))
        // Version-4 failure must retain its old receipt and version; no rebuild.
        journal.writableDatabase.execSQL("DROP TABLE recovery_candidate_files")
        dropPublicResumeTables(journal.writableDatabase)
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanup_members")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanups")
        journal.writableDatabase.version = 4 // second DDL conflicts, first new table must roll back
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        try {
            journal.inspect()
            fail("migration must not overwrite")
        } catch (_: android.database.sqlite.SQLiteException) {
        }
        journal.close()
        android.database.sqlite.SQLiteDatabase.openDatabase(targetContext.getDatabasePath(name).path, null, 0).use { db ->
            assertEquals(4, db.version)
            db.rawQuery("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='recovery_candidate_files'", null).use {
                it.moveToFirst()
                assertEquals(0, it.getInt(0))
            }
            db.rawQuery("SELECT payload FROM receipts", null).use {
                it.moveToFirst()
                assertEquals(ExecutionJournal.encode(receipt), it.getString(0))
            }
            db.execSQL("DROP TABLE candidate_checkpoints")
        }
        journal = ExecutionJournal(targetContext, name)
        assertEquals(receipt, journal.inspect().single())
    }

    fun testV3MigrationFailurePreservesHistory() {
        val c = command()
        journal.register(c, "s")
        val receipt = journal.complete(c, "s", NativeCheckpoint("paused", 3))
        dropResumeTables(journal.writableDatabase)
        journal.writableDatabase.execSQL("CREATE TABLE recovery_attempts (sentinel TEXT)")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanup_members")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanups")
        journal.writableDatabase.version = 3
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        try {
            journal.inspect()
            fail("v4 migration should fail")
        } catch (_: android.database.sqlite.SQLiteException) {
        }
        journal.close()
        android.database.sqlite.SQLiteDatabase.openDatabase(targetContext.getDatabasePath(name).path, null, 0).use { db ->
            assertEquals(3, db.version)
            db.rawQuery("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='resume_checkpoints'", null).use {
                it.moveToFirst()
                assertEquals(0, it.getInt(0))
            }
            db.rawQuery("SELECT payload FROM receipts", null).use {
                it.moveToFirst()
                assertEquals(ExecutionJournal.encode(receipt), it.getString(0))
            }
            db.execSQL("DROP TABLE recovery_attempts")
        }
        journal = ExecutionJournal(targetContext, name)
        assertEquals(receipt, journal.inspect().single())
        assertEquals(7, journal.writableDatabase.version)
    }

    fun testUnknownVersionPreservesHistory() {
        val c = command()
        journal.register(c, "s")
        val receipt = journal.complete(c, "s", NativeCheckpoint("paused", 5))
        journal.writableDatabase.version = 99
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        try {
            journal.inspect()
            fail("unknown version must fail")
        } catch (_: android.database.sqlite.SQLiteException) {
        }
        journal.close()
        android.database.sqlite.SQLiteDatabase.openDatabase(targetContext.getDatabasePath(name).path, null, 0).use { db ->
            assertEquals(99, db.version)
            db.rawQuery("SELECT payload FROM receipts", null).use {
                assertTrue(it.moveToFirst())
                assertEquals(ExecutionJournal.encode(receipt), it.getString(0))
            }
        }
    }

    fun testMaterialRegistrationAndClosedCheckpoint() {
        val original = command()
        val mutableInput = EngineProtocol.map(original.payload["input"]).toMutableMap()
        val c = original.copy(payload = original.payload.toMutableMap().apply { put("input", mutableInput) })
        journal.register(c, "s")
        val worker = journal.newTransfer(c, "s")
        rejects("commandPayloadChanged") { worker.run(c.key, "http://127.0.0.1:2/") }
        assertTrue(journal.inspectMaterials(c.key).isEmpty())
        val stop = HttpTransfer.Stop().apply { request(HttpTransfer.Stop.Reason.PAUSE) }
        mutableInput["url"] = "http://127.0.0.1:2/"
        val staged = worker.run(c.key, "http://127.0.0.1:1/", stop)
        mutableInput["url"] = "http://127.0.0.1:1/"
        assertEquals(HttpTransfer.Stop.Reason.PAUSE, staged.stop)
        assertEquals(0L, staged.bytes)
        assertEquals(staged.file.path, journal.inspectMaterials(c.key).single().first)
        assertTrue(staged.file.exists())
        try {
            worker.run(c.key, "http://127.0.0.1:1/", stop)
            fail("reused allocation callback")
        } catch (error: HttpTransfer.Failure) {
            assertEquals("materialAllocationUnknown", (error.cause as EngineProtocolException).reason)
            assertTrue(!error.material.exists())
        }
        val directory = staged.file.parentFile!!
        val otherId = UUID.randomUUID().toString()
        val candidate = java.io.File(directory, "$otherId.part")
        val candidateFacts = java.io.File(directory, "$otherId.facts")
        rejects("materialAllocationUnknown") { journal.registerMaterials(c, "s", candidate, candidateFacts) }
        rejects("staleSession") { journal.registerMaterials(c, "foreign-session", candidate, candidateFacts) }
        rejects("materialOwnership") {
            journal.registerMaterials(c, "s", java.io.File(targetContext.cacheDir, "$otherId.part"), candidateFacts)
        }
        assertTrue(!candidate.exists() && !candidateFacts.exists())
        val receipt =
            journal.complete(
                c,
                "s",
                NativeCheckpoint(
                    "paused",
                    staged.bytes,
                    resumeSupport = "unsupported",
                    resumeRef = staged.file.name,
                    stagingLocation = staged.file.path,
                ),
            )
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        assertEquals(receipt, journal.inspect().single())
        assertEquals(staged.file.path, journal.inspectMaterials(c.key).single().first)
        try {
            journal.newTransfer(c, "s").run(c.key, "http://127.0.0.1:1/", stop)
            fail("completed command allocated again")
        } catch (error: HttpTransfer.Failure) {
            // Without worker authorization, the completed command has an obsolete head.
            assertEquals("staleReceipt", (error.cause as EngineProtocolException).reason)
            assertTrue(!error.material.exists())
            assertEquals(receipt, journal.inspect().single())
            assertEquals(staged.file.path, journal.inspectMaterials(c.key).single().first)
        }
    }

    fun testMaterialInsertFailureCreatesNothing() {
        val c = command()
        journal.register(c, "s")
        journal.writableDatabase.execSQL(
            "CREATE TRIGGER fail_material BEFORE INSERT ON materials BEGIN SELECT RAISE(ABORT,'material injection'); END",
        )
        try {
            journal.newTransfer(c, "s").run(c.key, "http://127.0.0.1:1/")
            fail("injection ignored")
        } catch (error: HttpTransfer.Failure) {
            assertTrue(error.cause is android.database.sqlite.SQLiteException)
            assertTrue(!error.material.exists())
            assertTrue(!java.io.File(error.material.path.replace(".part", ".facts")).exists())
        }
        assertTrue(journal.inspectMaterials(c.key).isEmpty())
        rejects("commandOutcomeUnknown") { journal.register(c, "s") }
    }

    fun testV1MigrationAndFailurePreserveHistory() {
        val c = command()
        journal.register(c, "s")
        val receipt = journal.complete(c, "s", NativeCheckpoint("paused", 23))
        // Reconstruct exactly the three v1 tables with their committed history.
        dropResumeTables(journal.writableDatabase)
        journal.writableDatabase.execSQL("DROP TABLE worker_authorizations")
        journal.writableDatabase.execSQL("DROP TABLE materials")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanup_members")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanups")
        journal.writableDatabase.version = 1
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        assertEquals(receipt, journal.inspect().single())
        assertEquals(7, journal.writableDatabase.version)
        assertTrue(journal.inspectMaterials(c.key).isEmpty())
        assertEquals(receipt, journal.register(c, "s"))
        // Fail the SECOND DDL so rollback must undo the newly created materials table.
        dropResumeTables(journal.writableDatabase)
        journal.writableDatabase.execSQL("DROP TABLE materials")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanup_members")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanups")
        journal.writableDatabase.version = 1
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        try {
            journal.inspect()
            fail("migration must fail")
        } catch (_: android.database.sqlite.SQLiteException) {
        }
        journal.close()
        android.database.sqlite.SQLiteDatabase.openDatabase(targetContext.getDatabasePath(name).path, null, 0).use { db ->
            assertEquals(1, db.version)
            db.rawQuery("SELECT COUNT(*) FROM receipts", null).use {
                it.moveToFirst()
                assertEquals(1, it.getInt(0))
            }
            db.rawQuery("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='materials'", null).use {
                it.moveToFirst()
                assertEquals(0, it.getInt(0))
            }
            db.execSQL("DROP TABLE worker_authorizations")
        }
        journal = ExecutionJournal(targetContext, name)
        assertEquals(receipt, journal.inspect().single())
    }

    fun testWorkerLifecycleAndStopAuthorization() {
        val c = command()
        journal.register(c, "s")
        val accepted = journal.acceptWorker(c, "s")
        assertEquals("queued", accepted["state"])
        journal.workerReceipt(c, "s", NativeCheckpoint("running", 0))
        val directory = java.io.File(targetContext.filesDir.canonicalFile, "http_staging_v1").apply { mkdirs() }
        val id = UUID.randomUUID().toString()
        val part = java.io.File(directory, "$id.part")
        val facts = java.io.File(directory, "$id.facts")
        journal.registerMaterials(c, "s", part, facts)
        rejects("materialAllocationUnknown") { journal.registerMaterials(c, "s", part, facts) }
        val version = journal.inspect().last()["receiptVersion"] as Long
        val pause = command("p", version, method = "pause")
        journal.register(pause, "s")
        journal.stopWorker(c, pause, "s", NativeCheckpoint("running", 0))
        val receipt = journal.finishWorker(c, "s", NativeCheckpoint("paused", 0), pause)
        assertEquals(receipt, journal.register(pause, "s"))
        assertEquals(accepted, journal.register(c, "s"))
        assertEquals(1, journal.inspectMaterials(c.key).size)
        rejects("staleReceipt") { journal.workerReceipt(c, "s", NativeCheckpoint("running", 0)) }
    }

    fun testPublicPersistedCancelBlocksProofAndLateStaging() {
        for ((generation, boundary) in listOf(3, 4).withIndex()) {
            java.net.ServerSocket(0).use { server ->
                val responder =
                    responder {
                        server.accept().use { socket ->
                            socket.getInputStream().bufferedReader().let { while (!it.readLine().isNullOrEmpty()) { } }
                            socket.getOutputStream().write(
                                "HTTP/1.1 206 Partial Content\r\nETag: \"strong\"\r\nContent-Range: bytes 8192-16383/16384\r\nContent-Length: 8192\r\nConnection: close\r\n\r\n".toByteArray() +
                                    ByteArray(8192) { 8 },
                            )
                        }
                    }
                val c = command("source-$generation", generation = generation.toLong())
                journal.register(c, "s")
                journal.acceptWorker(c, "s")
                val dir = java.io.File(targetContext.filesDir.canonicalFile, "http_staging_v1").apply { mkdirs() }
                val id = UUID.randomUUID().toString()
                val source = java.io.File(dir, "$id.part")
                val facts = java.io.File(dir, "$id.facts")
                journal.registerMaterials(c, "s", source, facts)
                java.io.FileOutputStream(source).use {
                    it.write(ByteArray(24576) { 7 })
                    it.channel.force(true)
                }
                java.io.FileOutputStream(facts).use {
                    it.write(byteArrayOf(1))
                    it.channel.force(true)
                }
                val original = source.readBytes().toList()
                journal.saveResumeCheckpoint(
                    c,
                    "s",
                    ForcedMaterial(
                        c.key,
                        source,
                        8192,
                        16384,
                        "http://127.0.0.1:${server.localPort}/",
                        "\"strong\"",
                        NativePrefixDigest.read(source, 8192).snapshot(),
                    ),
                )
                val pause = command("initial-pause-$generation", 1, generation.toLong(), "pause")
                journal.register(pause, "s")
                journal.stopWorker(c, pause, "s", NativeCheckpoint("running", 8192))
                journal.finishWorker(c, "s", NativeCheckpoint("paused", 8192), pause)
                val resume = command("resume-$generation", 2, generation.toLong(), "resume")
                journal.acceptResume(resume, "s")
                journal.workerReceipt(resume, "s", NativeCheckpoint("running", 8192))
                var actions = 0
                val cancel = command("cancel-$generation", 4, generation.toLong(), "cancel")
                val core =
                    journal.newResumeTransfer(resume, "s") { action ->
                        if (++actions == boundary) {
                            journal.register(cancel, "s")
                            journal.stopWorker(resume, cancel, "s", NativeCheckpoint("cancelling", 8192))
                        }
                        action()
                    }
                if (boundary == 3) {
                    rejects("stateConflict") { core.run() }
                } else {
                    try {
                        core.run()
                        fail("cancelled candidate became staged")
                    } catch (
                        stopped: ResumeTransfer.Stopped,
                    ) {
                        assertEquals(HttpTransfer.Stop.Reason.CANCEL, stopped.reason)
                    }
                }
                assertEquals("copying", journal.inspectRecoveries(c.key).single()["phase"])
                if (boundary == 3) assertNull(journal.inspectCandidate(c.key, resume.commandId))
                assertEquals(original, source.readBytes().toList())
                // Match Coordinator's explicit non-recoverable cancellation checkpoint.
                // Journal preserves cancelling fields; it must not derive support from a branch.
                val terminal = journal.finishWorker(resume, "s", NativeCheckpoint("cancelling", 8192, resumeSupport = "unsupported"), null)
                assertEquals("unsupported", terminal["resumeSupport"])
                assertNull(terminal["resumeRef"])
                responder.join(5000)
            }
        }
    }

    fun testPublicResumeAtomicVersionAndRetirement() {
        java.net.ServerSocket(0).use { server ->
            val responder =
                responder {
                    repeat(3) { index ->
                        server.accept().use { socket ->
                            socket.getInputStream().bufferedReader().let { while (!it.readLine().isNullOrEmpty()) { } }
                            val headers =
                                when (index) {
                                    0 -> "HTTP/1.1 200 OK\r\nETag: \"strong\"\r\nConnection: close\r\n\r\n"
                                    1 -> "HTTP/1.1 206 Partial Content\r\nETag: \"strong\"\r\nContent-Range: bytes 8192-32767/32768\r\nContent-Length: 24576\r\nConnection: close\r\n\r\n"
                                    else -> "HTTP/1.1 206 Partial Content\r\nETag: \"strong\"\r\nContent-Range: bytes 16384-32767/32768\r\nContent-Length: 16384\r\nConnection: close\r\n\r\n"
                                }
                            socket.getOutputStream().write(
                                headers.toByteArray() + ByteArray(if (index == 2) 16384 else 8192) { (7 + index).toByte() },
                            )
                        }
                    }
                }
            val base = command()
            val input = EngineProtocol.map(base.payload["input"]) + ("url" to "http://127.0.0.1:${server.localPort}/")
            val c = EngineProtocol.command("enqueue", base.payload + ("input" to input))
            journal.register(c, "s")
            journal.acceptWorker(c, "s")
            journal.workerReceipt(c, "s", NativeCheckpoint("running", 0))
            val stop = HttpTransfer.Stop()
            val first =
                journal.newTransfer(c, "s").run(c.key, input["url"] as String, stop) {
                    if (it.bytes >=
                        8192
                    ) {
                        stop.request(HttpTransfer.Stop.Reason.PAUSE)
                    }
                }
            val source = journal.inspectResume(c.key)!!
            // Simulate process loss before terminal commit. The new explicit native session retires, never finishes, the old worker.
            val resume = command("public", 2, method = "resume", session = "new")
            journal.writableDatabase.execSQL(
                "CREATE TRIGGER fail_resume BEFORE INSERT ON resume_sources BEGIN SELECT RAISE(ABORT,'resume transaction'); END",
            )
            try {
                journal.acceptResume(resume, "new")
                fail("accept must roll back")
            } catch (
                _: android.database.sqlite.SQLiteException,
            ) {
            }
            assertEquals(2L, journal.inspect().last()["receiptVersion"])
            for (table in listOf(
                "resume_sources",
                "retired_workers",
            )) {
                journal.readableDatabase.rawQuery("SELECT COUNT(*) FROM $table", null).use {
                    it.moveToFirst()
                    assertEquals(0, it.getInt(0))
                }
            }
            journal.readableDatabase.rawQuery("SELECT COUNT(*) FROM commands WHERE id='public'", null).use {
                it.moveToFirst()
                assertEquals(0, it.getInt(0))
            }
            journal.writableDatabase.execSQL("DROP TRIGGER fail_resume")
            rejects("staleSession") { journal.acceptResume(resume, "s") }
            val accepted = journal.acceptResume(resume, "new")
            assertTrue(!accepted.second)
            assertEquals(3L, accepted.first["receiptVersion"])
            assertEquals(source, journal.inspectResume(c.key))
            journal.readableDatabase.rawQuery("SELECT finished FROM worker_authorizations WHERE command_id=?", arrayOf(c.commandId)).use {
                it.moveToFirst()
                assertEquals(0, it.getInt(0))
            }
            journal.readableDatabase.rawQuery("SELECT reason FROM retired_workers WHERE command_id=?", arrayOf(c.commandId)).use {
                it.moveToFirst()
                assertEquals("waitingRecovery", it.getString(0))
            }
            journal.workerReceipt(resume, "new", NativeCheckpoint("running", 8192))
            val recovery = journal.newResumeTransfer(resume, "new") { it() }
            val pause = command("public-pause", 4, method = "pause", session = "new")
            val stopping = HttpTransfer.Stop()
            val result =
                recovery.run(stopping, onSample = {
                    if (it.bytes >= 16384) {
                        journal.register(pause, "new")
                        journal.stopWorker(resume, pause, "new", NativeCheckpoint("running", it.bytes, it.total))
                        stopping.request(HttpTransfer.Stop.Reason.PAUSE)
                    }
                })
            assertEquals(16384L, result.bytes)
            assertEquals(first.file.readBytes().toList(), result.file.readBytes().take(8192))
            val terminal = NativeCheckpoint("paused", result.bytes, result.total)
            val receipt = journal.finishWorker(resume, "new", terminal, pause)
            assertEquals(receipt, journal.finishWorker(resume, "new", terminal, pause))
            assertEquals(5L, receipt["receiptVersion"])
            assertEquals("supported", receipt["resumeSupport"])
            assertEquals(accepted.first, journal.acceptResume(resume, "new").first)
            rejects("staleReceipt") { journal.newResumeTransfer(resume, "new") { it() } }
            val unknown = command("unknown", 5, method = "resume", session = "new")
            journal.register(unknown, "new")
            rejects("commandOutcomeUnknown") { journal.acceptResume(unknown, "new") }
            val next = command("next-resume", 5, method = "resume", session = "new")
            assertEquals(6L, journal.acceptResume(next, "new").first["receiptVersion"])
            journal.workerReceipt(next, "new", NativeCheckpoint("running", result.bytes, result.total))
            val oldCandidate = result.file.readBytes()
            val complete = journal.newResumeTransfer(next, "new") { it() }.run()
            assertEquals(32768L, complete.bytes)
            assertEquals(oldCandidate.toList(), result.file.readBytes().toList())
            assertEquals(
                8L,
                journal.finishWorker(
                    next,
                    "new",
                    NativeCheckpoint("publishing", complete.bytes, complete.total, stagingLocation = complete.file.path),
                    null,
                )["receiptVersion"],
            )
            // A later current branch must not rewrite an already committed terminal replay.
            assertEquals(receipt, journal.finishWorker(resume, "new", terminal, pause))
            rejects(
                "receiptPayload",
            ) { journal.finishWorker(resume, "new", terminal.copy(downloadedBytes = terminal.downloadedBytes + 1), pause) }
            assertEquals(8L, journal.inspect().last()["receiptVersion"])
            responder.join(5000)
        }
    }

    fun testV5MigrationRollback() {
        val c = command()
        journal.register(c, "s")
        val receipt = journal.complete(c, "s", NativeCheckpoint("paused", 0))
        dropPublicResumeTables(journal.writableDatabase)
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanup_members")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanups")
        journal.writableDatabase.version = 5
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        assertEquals(7, journal.writableDatabase.version)
        assertEquals(receipt, journal.inspect().single())
        journal.writableDatabase.execSQL("DROP TABLE resume_sources")
        journal.writableDatabase.execSQL("DROP TABLE retired_workers")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanup_members")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanups")
        journal.writableDatabase.version = 5 // second DDL active_branches conflicts
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        try {
            journal.inspect()
            fail("migration should fail")
        } catch (_: android.database.sqlite.SQLiteException) {
        }
        journal.close()
        android.database.sqlite.SQLiteDatabase.openDatabase(targetContext.getDatabasePath(name).path, null, 0).use { db ->
            assertEquals(5, db.version)
            db.rawQuery("SELECT COUNT(*) FROM sqlite_master WHERE name='resume_sources'", null).use {
                it.moveToFirst()
                assertEquals(0, it.getInt(0))
            }
            db.execSQL("DROP TABLE active_branches")
        }
        journal = ExecutionJournal(targetContext, name)
        assertEquals(receipt, journal.inspect().single())
    }

    private fun dropPublicResumeTables(db: android.database.sqlite.SQLiteDatabase) {
        db.execSQL("DROP TABLE resume_sources")
        db.execSQL("DROP TABLE active_branches")
        db.execSQL("DROP TABLE retired_workers")
    }

    private fun dropResumeTables(db: android.database.sqlite.SQLiteDatabase) {
        dropPublicResumeTables(db)
        db.execSQL("DROP TABLE candidate_checkpoints")
        db.execSQL("DROP TABLE recovery_candidate_files")
        db.execSQL("DROP TABLE recovery_operations")
        db.execSQL("DROP TABLE recovery_attempts")
        db.execSQL("DROP TABLE resume_checkpoints")
    }

    fun testV2MigrationPreservesUnknownCommands() {
        val c = command()
        journal.register(c, "s")
        dropResumeTables(journal.writableDatabase)
        journal.writableDatabase.execSQL("DROP TABLE worker_authorizations")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanup_members")
        journal.writableDatabase.execSQL("DROP TABLE IF EXISTS cancel_cleanups")
        journal.writableDatabase.version = 2
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        assertEquals(7, journal.writableDatabase.version)
        rejects("commandOutcomeUnknown") { journal.register(c, "s") }
        assertTrue(journal.inspect().isEmpty())
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

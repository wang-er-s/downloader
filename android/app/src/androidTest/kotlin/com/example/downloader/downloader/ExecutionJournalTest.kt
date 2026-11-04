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
            for (test in listOf(::testHandshakePersistenceReplayAndAck, ::testIdentityPayloadAndRollback, ::testConcurrentAllocationGateAcrossConnections, ::testMaterialRegistrationAndClosedCheckpoint, ::testMaterialInsertFailureCreatesNothing, ::testV1MigrationAndFailurePreserveHistory, ::testWorkerLifecycleAndStopAuthorization, ::testV2MigrationPreservesUnknownCommands, ::testWorkerCommandBindingAndCancelCannotBeRevoked, ::testUnknownVersionPreservesHistory, ::testTerminalSaveRollbackAndIdempotentRetry, ::testProductionForcedCheckpointAndV3Migration, ::testV3MigrationFailurePreservesHistory, ::testCancelledWorkerCannotPromoteOrRecoverProof, ::testV4CandidateProofMigrationRetainsHistory)) {
                name = "journal-test-${UUID.randomUUID()}.db"
                journal = ExecutionJournal(targetContext, name)
                try { test() } finally { journal.close() }
            }
            output.putString("stream", "PASS 15 real Android SQLite tests")
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
                "input" to mapOf(
                    "protocolVersion" to 1,
                    "key" to key.json(),
                    "url" to "http://127.0.0.1:1/",
                    "stagingLocation" to "private",
                    "directory" to mapOf("version" to 1, "platform" to "android", "kind" to "systemDownloads", "displayName" to "Downloads"),
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

    fun testCancelledWorkerCannotPromoteOrRecoverProof() {
        val c = command()
        journal.register(c, "s"); journal.acceptWorker(c, "s")
        val directory = java.io.File(targetContext.filesDir.canonicalFile, "http_staging_v1").apply { mkdirs() }
        val id = UUID.randomUUID().toString()
        val source = java.io.File(directory, "$id.part")
        val facts = java.io.File(directory, "$id.facts")
        journal.registerMaterials(c, "s", source, facts)
        java.io.FileOutputStream(source).use { it.write(ByteArray(8) { 7 }); it.channel.force(true) }
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
        journal.writableDatabase.execSQL("CREATE TRIGGER fail_terminal BEFORE INSERT ON receipts BEGIN SELECT RAISE(ABORT,'terminal injection'); END")
        try { journal.finishWorker(c, "s", checkpoint, pause); fail("write must fail") }
        catch (_: android.database.sqlite.SQLiteException) { }
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
        journal.writableDatabase.version = 3
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        assertEquals(5, journal.writableDatabase.version)
        rejects("commandOutcomeUnknown") { journal.register(c0, "s") }
        java.net.ServerSocket(0).use { server ->
            val responder = Thread {
                repeat(2) { index -> server.accept().use { socket ->
                    val reader = socket.getInputStream().bufferedReader()
                    val request = buildList { while (true) { val line = reader.readLine() ?: break; if (line.isEmpty()) break; add(line) } }
                    if (index == 1) {
                        assertTrue(request.any { it.equals("Range: bytes=8192-", true) })
                        socket.getOutputStream().write(("HTTP/1.1 206 Partial Content\r\nETag: \"strong\"\r\nContent-Range: bytes 8192-16383/16384\r\nContent-Length: 8192\r\nConnection: close\r\n\r\n").toByteArray() + ByteArray(8192) { 9 })
                    } else socket.getOutputStream().write(("HTTP/1.1 200 OK\r\nETag: \"strong\"\r\nConnection: close\r\n\r\n").toByteArray() + ByteArray(8192) { 7 })
                } }
            }.apply { start() }
            val original = command("new", generation = 1)
            val input = EngineProtocol.map(original.payload["input"]) + ("url" to "http://127.0.0.1:${server.localPort}/")
            val c = EngineProtocol.command("enqueue", original.payload + ("input" to input))
            journal.register(c, "s")
            journal.acceptWorker(c, "s")
            val stop = HttpTransfer.Stop()
            val result = journal.newTransfer(c, "s").run(c.key, input["url"] as String, stop) {
                assertNull(journal.inspectResume(c.key)) // sample precedes force
                stop.request(HttpTransfer.Stop.Reason.PAUSE)
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
            journal.close(); journal = ExecutionJournal(targetContext, name)
            assertEquals(saved.forced, journal.inspectResume(c.key)!!.forced)
            val resume = command("resume", receipt["receiptVersion"] as Long, generation = 1, method = "resume")
            journal.register(resume, "s")
            rejects("restartRequired") { journal.newRecovery(resume, "s", "unknown-ref") }
            rejects("staleSession") { journal.newRecovery(resume.copy(ownerSessionId = "old"), "s", saved.ref) }
            val recovery = journal.newRecovery(resume, "s", saved.ref)
            // Factory construction alone never requests HTTP or creates a candidate.
            journal.readableDatabase.rawQuery("SELECT COUNT(*) FROM recovery_attempts", null).use { it.moveToFirst(); assertEquals(0, it.getInt(0)) }
            journal.writableDatabase.execSQL("UPDATE resume_checkpoints SET receipt_version=1 WHERE ref=?", arrayOf(saved.ref))
            rejects("restartRequired") { recovery.run() } // authorization is checked again at run, before GET
            journal.writableDatabase.execSQL("UPDATE resume_checkpoints SET receipt_version=? WHERE ref=?", arrayOf(receipt["receiptVersion"], saved.ref))
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
            journal.close(); journal = ExecutionJournal(targetContext, name)
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
        journal.writableDatabase.version = 4
        journal.close(); journal = ExecutionJournal(targetContext, name)
        assertEquals(5, journal.writableDatabase.version)
        assertEquals(receipt, journal.inspect().single())
        assertNull(journal.inspectCandidate(c.key, "none"))
        // Version-4 failure must retain its old receipt and version; no rebuild.
        journal.writableDatabase.execSQL("DROP TABLE recovery_candidate_files")
        journal.writableDatabase.version = 4 // second DDL conflicts, first new table must roll back
        journal.close(); journal = ExecutionJournal(targetContext, name)
        try { journal.inspect(); fail("migration must not overwrite") } catch (_: android.database.sqlite.SQLiteException) { }
        journal.close()
        android.database.sqlite.SQLiteDatabase.openDatabase(targetContext.getDatabasePath(name).path, null, 0).use { db ->
            assertEquals(4, db.version)
            db.rawQuery("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='recovery_candidate_files'", null).use { it.moveToFirst(); assertEquals(0, it.getInt(0)) }
            db.rawQuery("SELECT payload FROM receipts", null).use { it.moveToFirst(); assertEquals(ExecutionJournal.encode(receipt), it.getString(0)) }
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
        journal.writableDatabase.version = 3
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        try { journal.inspect(); fail("v4 migration should fail") } catch (_: android.database.sqlite.SQLiteException) { }
        journal.close()
        android.database.sqlite.SQLiteDatabase.openDatabase(targetContext.getDatabasePath(name).path, null, 0).use { db ->
            assertEquals(3, db.version)
            db.rawQuery("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='resume_checkpoints'", null).use { it.moveToFirst(); assertEquals(0, it.getInt(0)) }
            db.rawQuery("SELECT payload FROM receipts", null).use { it.moveToFirst(); assertEquals(ExecutionJournal.encode(receipt), it.getString(0)) }
            db.execSQL("DROP TABLE recovery_attempts")
        }
        journal = ExecutionJournal(targetContext, name)
        assertEquals(receipt, journal.inspect().single())
        assertEquals(5, journal.writableDatabase.version)
    }

    fun testUnknownVersionPreservesHistory() {
        val c = command()
        journal.register(c, "s")
        val receipt = journal.complete(c, "s", NativeCheckpoint("paused", 5))
        journal.writableDatabase.version = 99
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        try { journal.inspect(); fail("unknown version must fail") }
        catch (_: android.database.sqlite.SQLiteException) { }
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
        val receipt = journal.complete(c, "s", NativeCheckpoint("paused", staged.bytes, resumeSupport = "unsupported", resumeRef = staged.file.name, stagingLocation = staged.file.path))
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        assertEquals(receipt, journal.inspect().single())
        assertEquals(staged.file.path, journal.inspectMaterials(c.key).single().first)
        try {
            journal.newTransfer(c, "s").run(c.key, "http://127.0.0.1:1/", stop)
            fail("completed command allocated again")
        } catch (error: HttpTransfer.Failure) {
            assertEquals("commandAlreadyCompleted", (error.cause as EngineProtocolException).reason)
            assertTrue(!error.material.exists())
        }
    }

    fun testMaterialInsertFailureCreatesNothing() {
        val c = command()
        journal.register(c, "s")
        journal.writableDatabase.execSQL("CREATE TRIGGER fail_material BEFORE INSERT ON materials BEGIN SELECT RAISE(ABORT,'material injection'); END")
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
        journal.writableDatabase.version = 1
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        assertEquals(receipt, journal.inspect().single())
        assertEquals(5, journal.writableDatabase.version)
        assertTrue(journal.inspectMaterials(c.key).isEmpty())
        assertEquals(receipt, journal.register(c, "s"))
        // Fail the SECOND DDL so rollback must undo the newly created materials table.
        dropResumeTables(journal.writableDatabase)
        journal.writableDatabase.execSQL("DROP TABLE materials")
        journal.writableDatabase.version = 1
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        try { journal.inspect(); fail("migration must fail") }
        catch (_: android.database.sqlite.SQLiteException) { }
        journal.close()
        android.database.sqlite.SQLiteDatabase.openDatabase(targetContext.getDatabasePath(name).path, null, 0).use { db ->
            assertEquals(1, db.version)
            db.rawQuery("SELECT COUNT(*) FROM receipts", null).use { it.moveToFirst(); assertEquals(1, it.getInt(0)) }
            db.rawQuery("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='materials'", null).use {
                it.moveToFirst(); assertEquals(0, it.getInt(0))
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

    private fun dropResumeTables(db: android.database.sqlite.SQLiteDatabase) {
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
        journal.writableDatabase.version = 2
        journal.close()
        journal = ExecutionJournal(targetContext, name)
        assertEquals(5, journal.writableDatabase.version)
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

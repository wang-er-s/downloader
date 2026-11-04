package com.example.downloader.downloader

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import org.json.JSONArray
import org.json.JSONObject

/** Independent native execution facts. Never opens AppStore or starts a transfer. */
internal class ExecutionJournal(
    context: Context,
    name: String = "android_execution_v1.db",
) : SQLiteOpenHelper(context.applicationContext, name, null, 5) {
    private val privateRoot = context.applicationContext.filesDir.canonicalFile

    override fun onConfigure(db: SQLiteDatabase) {
        db.execSQL("PRAGMA foreign_keys=ON")
        db.execSQL("PRAGMA synchronous=FULL")
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE executions (task TEXT NOT NULL, engine TEXT NOT NULL, generation INTEGER NOT NULL CHECK(generation>=0), version INTEGER NOT NULL DEFAULT 0, ack INTEGER NOT NULL DEFAULT 0, input TEXT NOT NULL, PRIMARY KEY(engine,generation), UNIQUE(task,generation))",
        )
        db.execSQL("CREATE TABLE commands (id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL, result TEXT)")
        db.execSQL(
            "CREATE TABLE receipts (engine TEXT NOT NULL, generation INTEGER NOT NULL, version INTEGER NOT NULL CHECK(version>0), payload TEXT NOT NULL, PRIMARY KEY(engine,generation,version), FOREIGN KEY(engine,generation) REFERENCES executions(engine,generation))",
        )
        createMaterials(db)
        createWorkers(db)
        createResume(db)
        createCandidateProofs(db)
    }

    override fun onUpgrade(
        db: SQLiteDatabase,
        oldVersion: Int,
        newVersion: Int,
    ) {
        // SQLiteOpenHelper wraps this migration and user_version update in one transaction.
        // Never rewrite the v1 tables or discard an old database on failure.
        if (oldVersion !in 1..4 || newVersion != 5) {
            throw EngineProtocolException("protocolMismatch", "journalVersion")
        }
        if (oldVersion == 1) createMaterials(db)
        if (oldVersion <= 2) createWorkers(db)
        if (oldVersion <= 3) createResume(db)
        createCandidateProofs(db)
    }

    private fun createCandidateProofs(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE recovery_candidate_files (operation_id TEXT PRIMARY KEY NOT NULL REFERENCES recovery_operations(id), facts_path TEXT NOT NULL UNIQUE)",
        )
        db.execSQL(
            "CREATE TABLE candidate_checkpoints (operation_id TEXT PRIMARY KEY NOT NULL REFERENCES recovery_operations(id), resume_command TEXT NOT NULL UNIQUE REFERENCES commands(id), source_ref TEXT NOT NULL REFERENCES resume_checkpoints(ref), source_version INTEGER NOT NULL, receipt_version INTEGER NOT NULL, offset INTEGER NOT NULL CHECK(offset>0), total INTEGER NOT NULL, url TEXT NOT NULL, etag TEXT NOT NULL, digest TEXT NOT NULL, algorithm TEXT NOT NULL, facts_path TEXT NOT NULL UNIQUE)",
        )
    }

    private fun createResume(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE resume_checkpoints (ref TEXT PRIMARY KEY NOT NULL, command_id TEXT NOT NULL UNIQUE REFERENCES materials(command_id), receipt_version INTEGER NOT NULL, offset INTEGER NOT NULL CHECK(offset>0), total INTEGER, url TEXT NOT NULL, etag TEXT NOT NULL, digest TEXT NOT NULL, algorithm TEXT NOT NULL)",
        )
        db.execSQL(
            "CREATE TABLE recovery_attempts (command_id TEXT PRIMARY KEY NOT NULL REFERENCES commands(id), source_ref TEXT NOT NULL REFERENCES resume_checkpoints(ref), phase TEXT NOT NULL)",
        )
        db.execSQL(
            "CREATE TABLE recovery_operations (id TEXT PRIMARY KEY NOT NULL, resume_command TEXT NOT NULL UNIQUE REFERENCES commands(id), source_ref TEXT NOT NULL REFERENCES resume_checkpoints(ref), candidate TEXT NOT NULL UNIQUE, phase TEXT NOT NULL)",
        )
    }

    private fun createWorkers(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE worker_authorizations (command_id TEXT PRIMARY KEY NOT NULL REFERENCES commands(id), session TEXT NOT NULL, engine TEXT NOT NULL, generation INTEGER NOT NULL, version INTEGER NOT NULL, allocated INTEGER NOT NULL DEFAULT 0, stop TEXT, finished INTEGER NOT NULL DEFAULT 0, FOREIGN KEY(engine,generation) REFERENCES executions(engine,generation))",
        )
    }

    private fun createMaterials(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE materials (command_id TEXT PRIMARY KEY NOT NULL REFERENCES commands(id), task TEXT NOT NULL, engine TEXT NOT NULL, generation INTEGER NOT NULL, payload_path TEXT NOT NULL UNIQUE, facts_path TEXT NOT NULL UNIQUE, FOREIGN KEY(engine,generation) REFERENCES executions(engine,generation))",
        )
    }

    /** Internal worker path only. Caller must register the command once before running.
     * This does not schedule work or complete a command; the Service coordinator is still gated.
     */
    fun newTransfer(
        command: NativeCommand,
        session: String,
        allocation: (() -> Unit) -> Unit = { it() },
    ): HttpTransfer {
        // Copy nested input now: a caller retaining mutable codec maps cannot reauthorize run.
        val captured = EngineProtocol.command(command.method, decode(encode(command.payload)))
        if (captured.commandId != command.commandId || captured.key != command.key ||
            captured.ownerSessionId != command.ownerSessionId ||
            captured.expectedReceiptVersion != command.expectedReceiptVersion
        ) {
            conflict("commandPayloadChanged")
        }
        if (captured.method != "enqueue") conflict("materialAllocationUnavailable")
        val url = EngineProtocol.string(EngineProtocol.map(captured.payload["input"]), "url")
        return HttpTransfer(privateRoot, url, onCheckpoint = { forced ->
            allocation { saveResumeCheckpoint(captured, session, forced) }
        }) { key, payload, facts ->
            if (key != captured.key) conflict("staleExecution")
            allocation { registerMaterials(captured, session, payload, facts) }
        }
    }

    /** Allocation intent only: does NOT authorize resume, deletion, or a durable byte checkpoint.
     * Called before CREATE_NEW for either material. Unknown intents are retained indefinitely.
     */
    fun registerMaterials(
        command: NativeCommand,
        session: String,
        payload: java.io.File,
        facts: java.io.File,
    ) = transaction { db ->
        if (command.ownerSessionId != session) conflict("staleSession")
        if (command.method != "enqueue") conflict("materialAllocationUnavailable")
        val current = execution(db, command.key) ?: conflict("staleExecution")
        var worker = false
        db
            .rawQuery(
                "SELECT session,version,allocated,stop,finished FROM worker_authorizations WHERE command_id=?",
                arrayOf(command.commandId),
            ).use {
                if (it.moveToFirst()) {
                    worker = true
                    if (it.getString(0) != session) conflict("staleSession")
                    if (it.getLong(1) != current.first) conflict("staleReceipt")
                    if (it.getInt(2) != 0 || !it.isNull(3) || it.getInt(4) != 0) conflict("materialAllocationUnknown")
                }
            }
        if (!worker && current.first != command.expectedReceiptVersion) conflict("staleReceipt")
        db.rawQuery("SELECT MAX(generation) FROM executions WHERE task=?", arrayOf(command.key.taskId)).use {
            it.moveToFirst()
            if (it.getLong(0) != command.key.generation) conflict("staleExecution")
        }
        val encoded = encode(mapOf("method" to command.method, "arguments" to command.payload))
        db.rawQuery("SELECT payload,result FROM commands WHERE id=?", arrayOf(command.commandId)).use {
            if (!it.moveToFirst() || it.getString(0) != encoded) conflict("commandPayloadChanged")
            if (!worker && !it.isNull(1)) conflict("commandAlreadyCompleted")
        }
        val directory = java.io.File(privateRoot, "http_staging_v1")
        val id = payload.name.removeSuffix(".part")
        if (payload.name != "$id.part" || facts.name != "$id.facts" ||
            !id.matches(Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")) ||
            directory != directory.canonicalFile ||
            java.nio.file.Files
                .isSymbolicLink(directory.toPath()) ||
            payload.absoluteFile.parentFile != directory || facts.absoluteFile.parentFile != directory ||
            payload.exists() || facts.exists() ||
            java.nio.file.Files
                .isSymbolicLink(payload.toPath()) ||
            java.nio.file.Files
                .isSymbolicLink(facts.toPath())
        ) {
            conflict("materialOwnership")
        }
        if (worker) db.execSQL("UPDATE worker_authorizations SET allocated=1 WHERE command_id=?", arrayOf(command.commandId))
        // One allocation per command; even a prior attempt with no file must be inspected,
        // never used as permission to allocate another file and restart a transfer.
        db.rawQuery("SELECT command_id FROM materials WHERE command_id=?", arrayOf(command.commandId)).use {
            if (it.moveToFirst()) conflict("materialAllocationUnknown")
        }
        db.execSQL(
            "INSERT INTO materials(command_id,task,engine,generation,payload_path,facts_path) VALUES(?,?,?,?,?,?)",
            arrayOf<Any>(command.commandId, command.key.taskId, command.key.engineId, command.key.generation, payload.path, facts.path),
        )
    }

    /** Worker callback after force; progress samples are never accepted as recovery offsets. */
    fun saveResumeCheckpoint(
        command: NativeCommand,
        session: String,
        forced: ForcedMaterial,
    ) = transaction { db ->
        if (workerStop(db, command, session) == "cancel") return@transaction
        if (forced.key != command.key || forced.offset <= 0 || forced.total?.let { forced.offset > it } == true ||
            !NativeMaterialPaths.strongEtag(forced.etag) || forced.algorithm != NativePrefixDigest.ALGORITHM ||
            !forced.prefixDigest.matches(Regex("[0-9a-f]{64}"))
        ) {
            conflict("restartRequired")
        }
        NativeMaterialPaths.validate(privateRoot, forced.source)
        if (forced.source.length() < forced.offset) conflict("restartRequired")
        db
            .rawQuery(
                "SELECT payload_path FROM materials WHERE command_id=? AND task=? AND engine=? AND generation=?",
                arrayOf(command.commandId, command.key.taskId, command.key.engineId, command.key.generation.toString()),
            ).use {
                if (!it.moveToFirst() || it.getString(0) != forced.source.path) conflict("materialOwnership")
            }
        val url = java.net.URI(forced.effectiveUrl)
        if (url.scheme !in listOf("http", "https") || url.host.isNullOrBlank() || url.rawUserInfo != null || url.fragment != null ||
            url.port !in -1..65535
        ) {
            conflict("restartRequired")
        }
        val version = execution(db, command.key)!!.first
        var ref: String? = null
        db
            .rawQuery(
                "SELECT ref,offset,total,url,etag,digest,algorithm FROM resume_checkpoints WHERE command_id=?",
                arrayOf(command.commandId),
            ).use {
                if (it.moveToFirst()) {
                    ref = it.getString(0)
                    val priorTotal = if (it.isNull(2)) null else it.getLong(2)
                    if (forced.offset < it.getLong(1) || priorTotal != forced.total || it.getString(3) != forced.effectiveUrl ||
                        it.getString(4) != forced.etag ||
                        it.getString(6) != forced.algorithm ||
                        (forced.offset == it.getLong(1) && it.getString(5) != forced.prefixDigest)
                    ) {
                        conflict("restartRequired")
                    }
                }
            }
        if (ref == null) {
            ref =
                java.util.UUID
                    .randomUUID()
                    .toString()
            db.execSQL(
                "INSERT INTO resume_checkpoints(ref,command_id,receipt_version,offset,total,url,etag,digest,algorithm) VALUES(?,?,?,?,?,?,?,?,?)",
                arrayOf<Any?>(
                    ref,
                    command.commandId,
                    version,
                    forced.offset,
                    forced.total,
                    forced.effectiveUrl,
                    forced.etag,
                    forced.prefixDigest,
                    forced.algorithm,
                ),
            )
        } else {
            db.execSQL(
                "UPDATE resume_checkpoints SET receipt_version=?,offset=?,digest=? WHERE ref=?",
                arrayOf<Any?>(version, forced.offset, forced.prefixDigest, ref),
            )
        }
    }

    /** Private facts only; never a scheduling source or channel path authorization. */
    fun inspectResume(key: ExecutionKey): NativeResumeMaterial? =
        transaction { db ->
            execution(db, key) ?: conflict("staleExecution")
            db
                .rawQuery(
                    "SELECT r.ref,r.command_id,r.receipt_version,m.payload_path,r.offset,r.total,r.url,r.etag,r.digest,r.algorithm FROM resume_checkpoints r JOIN materials m ON m.command_id=r.command_id WHERE m.task=? AND m.engine=? AND m.generation=?",
                    arrayOf(key.taskId, key.engineId, key.generation.toString()),
                ).use {
                    if (!it.moveToFirst()) {
                        null
                    } else {
                        NativeResumeMaterial(
                            it.getString(0),
                            it.getString(1),
                            it.getLong(2),
                            ForcedMaterial(
                                key,
                                java.io.File(it.getString(3)),
                                it.getLong(4),
                                if (it.isNull(5)) null else it.getLong(5),
                                it.getString(6),
                                it.getString(7),
                                it.getString(8),
                                it.getString(9),
                            ),
                        )
                    }
                }
        }

    /** Internal only. Public resume remains gated in Coordinator, no startup caller invokes this. */
    fun newRecovery(
        command: NativeCommand,
        session: String,
        ref: String,
    ): ResumeTransfer {
        val captured = EngineProtocol.command(command.method, decode(encode(command.payload)))
        if (captured.key != command.key || captured.commandId != command.commandId || command.method != "resume" ||
            captured.ownerSessionId != command.ownerSessionId ||
            captured.ownerSessionId != session ||
            captured.expectedReceiptVersion != command.expectedReceiptVersion
        ) {
            conflict("staleSession")
        }
        val material = inspectResume(command.key) ?: conflict("restartRequired")
        if (material.ref != ref) conflict("restartRequired")

        fun validate(db: SQLiteDatabase) {
            val current = execution(db, captured.key) ?: conflict("staleExecution")
            if (current.first != captured.expectedReceiptVersion) conflict("staleReceipt")
            db.rawQuery("SELECT MAX(generation) FROM executions WHERE task=?", arrayOf(captured.key.taskId)).use {
                it.moveToFirst()
                if (it.getLong(0) !=
                    captured.key.generation
                ) {
                    conflict("staleExecution")
                }
            }
            db.rawQuery("SELECT payload,result FROM commands WHERE id=?", arrayOf(captured.commandId)).use {
                val encoded = encode(mapOf("method" to captured.method, "arguments" to captured.payload))
                if (!it.moveToFirst() || it.getString(0) != encoded) conflict("commandPayloadChanged")
                if (!it.isNull(1)) conflict("commandAlreadyCompleted")
            }
            db
                .rawQuery(
                    "SELECT finished,stop,engine,generation,version FROM worker_authorizations WHERE command_id=?",
                    arrayOf(material.commandId),
                ).use {
                    if (!it.moveToFirst() || it.getInt(0) != 1 || (!it.isNull(1) && it.getString(1) == "cancel") ||
                        it.getString(2) != captured.key.engineId || it.getLong(3) != captured.key.generation ||
                        it.getLong(4) != material.receiptVersion || material.receiptVersion != current.first
                    ) {
                        conflict("restartRequired")
                    }
                }
            if (inspectResume(captured.key) != material) conflict("restartRequired")
        }
        transaction { db ->
            validate(db)
            db.rawQuery("SELECT command_id FROM recovery_attempts WHERE command_id=?", arrayOf(captured.commandId)).use {
                if (it.moveToFirst()) conflict("commandOutcomeUnknown")
            }
        }
        return ResumeTransfer(privateRoot, material, { id, candidate ->
            transaction { db ->
                validate(db)
                NativeMaterialPaths.validate(privateRoot, candidate, false)
                if (candidate.name != "$id.part") conflict("materialOwnership")
                db
                    .rawQuery(
                        "SELECT phase FROM recovery_attempts WHERE command_id=? AND source_ref=?",
                        arrayOf(captured.commandId, ref),
                    ).use {
                        if (!it.moveToFirst() || it.getString(0) != "requested") conflict("commandOutcomeUnknown")
                    }
                db.execSQL(
                    "INSERT INTO recovery_operations(id,resume_command,source_ref,candidate,phase) VALUES(?,?,?,?,?)",
                    arrayOf(id, captured.commandId, ref, candidate.path, "copying"),
                )
                db.execSQL(
                    "INSERT INTO recovery_candidate_files(operation_id,facts_path) VALUES(?,?)",
                    arrayOf(
                        id,
                        candidate.path.removeSuffix(".part") + ".facts",
                    ),
                )
                db.execSQL("UPDATE recovery_attempts SET phase='candidate' WHERE command_id=?", arrayOf(captured.commandId))
            }
        }, { id ->
            transaction { db ->
                validate(db)
                db
                    .rawQuery(
                        "SELECT phase FROM recovery_operations WHERE id=? AND resume_command=? AND source_ref=?",
                        arrayOf(id, captured.commandId, ref),
                    ).use {
                        if (!it.moveToFirst() || it.getString(0) != "copying") conflict("commandOutcomeUnknown")
                    }
                db.execSQL("UPDATE recovery_operations SET phase='staged' WHERE id=?", arrayOf(id))
            }
        }, {
            transaction { db ->
                validate(db)
                db.execSQL(
                    "INSERT INTO recovery_attempts(command_id,source_ref,phase) VALUES(?,?,'requested')",
                    arrayOf(captured.commandId, ref),
                )
            }
        }, onCheckpoint = { id, forced ->
            transaction { db ->
                validate(db)
                if (forced.key != captured.key || forced.offset < material.forced.offset || forced.total == null ||
                    forced.offset > forced.total ||
                    forced.total.let { material.forced.total != null && it != material.forced.total } ||
                    forced.etag != material.forced.etag || forced.effectiveUrl != material.forced.effectiveUrl ||
                    forced.algorithm != material.forced.algorithm ||
                    !forced.prefixDigest.matches(Regex("[0-9a-f]{64}"))
                ) {
                    conflict("restartRequired")
                }
                NativeMaterialPaths.validate(privateRoot, forced.source)
                val facts = java.io.File(forced.source.path.removeSuffix(".part") + ".facts")
                if (facts != facts.canonicalFile ||
                    java.nio.file.Files
                        .isSymbolicLink(facts.toPath()) || !facts.isFile ||
                    forced.source.length() < forced.offset
                ) {
                    conflict("materialOwnership")
                }
                db
                    .rawQuery(
                        "SELECT candidate,phase FROM recovery_operations WHERE id=? AND resume_command=? AND source_ref=?",
                        arrayOf(id, captured.commandId, ref),
                    ).use {
                        if (!it.moveToFirst() || it.getString(0) != forced.source.path ||
                            it.getString(1) != "copying"
                        ) {
                            conflict("materialOwnership")
                        }
                    }
                db.rawQuery("SELECT facts_path FROM recovery_candidate_files WHERE operation_id=?", arrayOf(id)).use {
                    if (!it.moveToFirst() || it.getString(0) != facts.path) conflict("materialOwnership")
                }
                var exists = false
                db.rawQuery("SELECT offset,total,digest,algorithm FROM candidate_checkpoints WHERE operation_id=?", arrayOf(id)).use {
                    if (it.moveToFirst()) {
                        exists = true
                        if (it.getLong(0) > forced.offset || it.getLong(1) != forced.total || it.getString(3) != forced.algorithm ||
                            (it.getLong(0) == forced.offset && it.getString(2) != forced.prefixDigest)
                        ) {
                            conflict("restartRequired")
                        }
                    }
                }
                if (!exists) {
                    db.execSQL(
                        "INSERT INTO candidate_checkpoints(operation_id,resume_command,source_ref,source_version,receipt_version,offset,total,url,etag,digest,algorithm,facts_path) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                        arrayOf<Any>(
                            id,
                            captured.commandId,
                            ref,
                            material.receiptVersion,
                            captured.expectedReceiptVersion,
                            forced.offset,
                            forced.total,
                            forced.effectiveUrl,
                            forced.etag,
                            forced.prefixDigest,
                            forced.algorithm,
                            facts.path,
                        ),
                    )
                } else {
                    db.execSQL(
                        "UPDATE candidate_checkpoints SET offset=?,digest=? WHERE operation_id=?",
                        arrayOf<Any>(forced.offset, forced.prefixDigest, id),
                    )
                }
            }
        })
    }

    /** Exact branch lookup only; never selected as the source of a scheduled worker. */
    fun inspectCandidate(
        key: ExecutionKey,
        resumeCommandId: String,
    ): CandidateCheckpoint? =
        transaction { db ->
            execution(db, key) ?: conflict("staleExecution")
            db
                .rawQuery(
                    "SELECT c.operation_id,c.source_ref,c.source_version,c.receipt_version,o.candidate,c.offset,c.total,c.url,c.etag,c.digest,c.algorithm FROM candidate_checkpoints c JOIN recovery_operations o ON o.id=c.operation_id JOIN resume_checkpoints r ON r.ref=c.source_ref JOIN materials m ON m.command_id=r.command_id WHERE c.resume_command=? AND m.task=? AND m.engine=? AND m.generation=?",
                    arrayOf(resumeCommandId, key.taskId, key.engineId, key.generation.toString()),
                ).use {
                    if (!it.moveToFirst()) {
                        null
                    } else {
                        CandidateCheckpoint(
                            it.getString(0),
                            resumeCommandId,
                            it.getString(1),
                            it.getLong(2),
                            it.getLong(3),
                            ForcedMaterial(
                                key,
                                java.io.File(it.getString(4)),
                                it.getLong(5),
                                it.getLong(6),
                                it.getString(7),
                                it.getString(8),
                                it.getString(9),
                                it.getString(10),
                            ),
                        )
                    }
                }
        }

    /** Native diagnostic ownership, never creates/resumes/deletes a candidate. */
    fun inspectRecoveries(key: ExecutionKey): List<Map<String, Any?>> =
        transaction { db ->
            execution(db, key) ?: conflict("staleExecution")
            db
                .rawQuery(
                    "SELECT o.id,o.resume_command,o.source_ref,o.candidate,o.phase FROM recovery_operations o JOIN resume_checkpoints r ON r.ref=o.source_ref JOIN materials m ON m.command_id=r.command_id WHERE m.task=? AND m.engine=? AND m.generation=? ORDER BY o.id",
                    arrayOf(key.taskId, key.engineId, key.generation.toString()),
                ).use { rows ->
                    buildList {
                        while (rows.moveToNext()) {
                            add(
                                mapOf(
                                    "operationId" to rows.getString(0),
                                    "commandId" to rows.getString(1),
                                    "sourceRef" to rows.getString(2),
                                    "candidate" to rows.getString(3),
                                    "phase" to rows.getString(4),
                                ),
                            )
                        }
                    }
                }
        }

    /** Diagnostic ownership intents; non-destructive and never an enqueue/recovery source. */
    fun inspectMaterials(key: ExecutionKey): List<Pair<String, String>> =
        transaction { db ->
            execution(db, key) ?: conflict("staleExecution")
            db
                .rawQuery(
                    "SELECT payload_path,facts_path FROM materials WHERE task=? AND engine=? AND generation=? ORDER BY command_id",
                    arrayOf(key.taskId, key.engineId, key.generation.toString()),
                ).use { rows -> buildList { while (rows.moveToNext()) add(rows.getString(0) to rows.getString(1)) } }
        }

    // SQLite's write transaction is also the allocation gate across helper instances.
    // Rollback errors are suppressed onto the original failure, never replacing it.
    private fun <T> transaction(action: (SQLiteDatabase) -> T): T {
        val db = writableDatabase
        db.beginTransaction()
        var failure: Throwable? = null
        try {
            val result = action(db)
            db.setTransactionSuccessful()
            return result
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            try {
                db.endTransaction()
            } catch (error: Throwable) {
                if (failure != null) failure.addSuppressed(error) else throw error
            }
        }
    }

    /** Register intent before a worker side effect. null means newly registered, not success.
     * An existing NULL outcome must be inspected, never automatically executed again.
     */
    fun register(
        command: NativeCommand,
        session: String,
    ): Map<String, Any?>? =
        transaction { db ->
            if (command.ownerSessionId != session) conflict("staleSession")
            val payload = encode(mapOf("method" to command.method, "arguments" to command.payload))
            db.rawQuery("SELECT payload,result FROM commands WHERE id=?", arrayOf(command.commandId)).use { row ->
                if (row.moveToFirst()) {
                    if (row.getString(0) != payload) conflict("commandPayloadChanged")
                    if (row.isNull(1)) conflict("commandOutcomeUnknown")
                    return@transaction decode(row.getString(1))
                }
            }
            val key = command.key
            val existing = execution(db, key)
            val latest =
                db
                    .rawQuery(
                        "SELECT task,engine,generation FROM executions WHERE task=? OR engine=? ORDER BY generation DESC LIMIT 1",
                        arrayOf(key.taskId, key.engineId),
                    ).use {
                        if (it.moveToFirst()) ExecutionKey(it.getString(0), it.getString(1), it.getLong(2)) else null
                    }
            if (latest != null &&
                (latest.taskId != key.taskId || latest.engineId != key.engineId || latest.generation > key.generation)
            ) {
                conflict("staleExecution")
            }
            if (existing == null) {
                if (command.method != "enqueue") conflict("staleExecution")
                if (command.expectedReceiptVersion != 0L) conflict("staleReceipt")
                db.execSQL(
                    "INSERT INTO executions(task,engine,generation,input) VALUES(?,?,?,?)",
                    arrayOf<Any>(key.taskId, key.engineId, key.generation, payload),
                )
            } else {
                if (command.method == "enqueue") conflict("staleExecution")
                if (existing.first != command.expectedReceiptVersion) conflict("staleReceipt")
            }
            db.execSQL("INSERT INTO commands(id,payload) VALUES(?,?)", arrayOf(command.commandId, payload))
            null
        }

    /** Commit the real worker checkpoint and command result together, allocating one immutable version. */
    fun complete(
        command: NativeCommand,
        session: String,
        checkpoint: NativeCheckpoint,
    ): Map<String, Any?> =
        transaction { db ->
            if (command.ownerSessionId != session) conflict("staleSession")
            val encodedCommand = encode(mapOf("method" to command.method, "arguments" to command.payload))
            db.rawQuery("SELECT payload,result FROM commands WHERE id=?", arrayOf(command.commandId)).use {
                if (!it.moveToFirst() || it.getString(0) != encodedCommand) conflict("commandPayloadChanged")
                if (!it.isNull(1)) return@transaction decode(it.getString(1))
            }
            val key = command.key
            val current = execution(db, key) ?: conflict("staleExecution")
            db.rawQuery("SELECT MAX(generation) FROM executions WHERE task=?", arrayOf(key.taskId)).use {
                it.moveToFirst()
                if (it.getLong(0) != key.generation) conflict("staleExecution")
            }
            if (current.first != command.expectedReceiptVersion) conflict("staleReceipt")
            if (current.first == Long.MAX_VALUE) conflict("receiptVersionExhausted")
            val version = current.first + 1
            val receipt = checkpoint.receipt(key, version)
            val payload = encode(receipt)
            db.execSQL(
                "INSERT INTO receipts(engine,generation,version,payload) VALUES(?,?,?,?)",
                arrayOf<Any>(key.engineId, key.generation, version, payload),
            )
            db.execSQL(
                "UPDATE executions SET version=? WHERE engine=? AND generation=?",
                arrayOf<Any>(version, key.engineId, key.generation),
            )
            db.execSQL("UPDATE commands SET result=? WHERE id=?", arrayOf(payload, command.commandId))
            receipt
        }

    /** Called only by the process coordinator after register returned a new pending command. */
    fun acceptWorker(
        command: NativeCommand,
        session: String,
    ): Map<String, Any?> =
        transaction { db ->
            if (command.ownerSessionId != session || command.method != "enqueue") conflict("staleSession")
            val receipt = complete(command, session, NativeCheckpoint("queued", 0, null))
            db.execSQL(
                "INSERT INTO worker_authorizations(command_id,session,engine,generation,version) VALUES(?,?,?,?,?)",
                arrayOf<Any>(command.commandId, session, command.key.engineId, command.key.generation, receipt["receiptVersion"] as Long),
            )
            receipt
        }

    /** Revalidate the immutable command and its live authorization inside the caller transaction. */
    private fun workerStop(
        db: SQLiteDatabase,
        command: NativeCommand,
        session: String,
    ): String? {
        if (command.method != "enqueue" || command.ownerSessionId != session) conflict("staleSession")
        val current = execution(db, command.key) ?: conflict("staleExecution")
        val payload = encode(mapOf("method" to command.method, "arguments" to command.payload))
        db.rawQuery("SELECT payload,result FROM commands WHERE id=?", arrayOf(command.commandId)).use {
            if (!it.moveToFirst() || it.getString(0) != payload) conflict("commandPayloadChanged")
            if (it.isNull(1)) conflict("commandOutcomeUnknown")
        }
        db.rawQuery("SELECT MAX(generation) FROM executions WHERE task=?", arrayOf(command.key.taskId)).use {
            it.moveToFirst()
            if (it.getLong(0) != command.key.generation) conflict("staleExecution")
        }
        return db
            .rawQuery(
                "SELECT session,engine,generation,version,finished,stop FROM worker_authorizations WHERE command_id=?",
                arrayOf(command.commandId),
            ).use {
                if (!it.moveToFirst() || it.getString(0) != session) conflict("staleSession")
                if (it.getString(1) != command.key.engineId || it.getLong(2) != command.key.generation) conflict("staleExecution")
                if (it.getLong(3) != current.first || it.getInt(4) != 0) conflict("staleReceipt")
                if (it.isNull(5)) null else it.getString(5)
            }
    }

    fun stopWorker(
        worker: NativeCommand,
        command: NativeCommand,
        session: String,
        checkpoint: NativeCheckpoint,
    ): Map<String, Any?> =
        transaction { db ->
            val priorStop = workerStop(db, worker, session)
            if (command.key != worker.key || command.method !in setOf("pause", "cancel")) conflict("staleExecution")
            if (priorStop == "cancel") conflict("commandOutcomeUnknown")
            val encoded = encode(mapOf("method" to command.method, "arguments" to command.payload))
            db.rawQuery("SELECT payload,result FROM commands WHERE id=?", arrayOf(command.commandId)).use {
                if (!it.moveToFirst() || it.getString(0) != encoded) conflict("commandPayloadChanged")
                if (!it.isNull(1)) conflict("commandAlreadyCompleted")
            }
            if (checkpoint.state != (if (command.method == "cancel") "cancelling" else "running")) conflict("invalidPayload")
            val receipt =
                if (command.method == "cancel") {
                    complete(command, session, checkpoint)
                } else {
                    val current = execution(db, command.key) ?: conflict("staleExecution")
                    if (command.ownerSessionId != session) conflict("staleSession")
                    if (current.first != command.expectedReceiptVersion) conflict("staleReceipt")
                    mapOf("receiptVersion" to current.first)
                }
            db.execSQL(
                "UPDATE worker_authorizations SET stop=?,version=? WHERE command_id=? AND session=? AND finished=0",
                arrayOf<Any>(command.method, receipt["receiptVersion"] as Long, worker.commandId, session),
            )
            receipt
        }

    /** Appends a worker fact without changing the immutable enqueue result. */
    fun workerReceipt(
        command: NativeCommand,
        session: String,
        checkpoint: NativeCheckpoint,
        finished: Boolean = false,
    ): Map<String, Any?> =
        transaction { db ->
            val current = execution(db, command.key) ?: conflict("staleExecution")
            val stop = workerStop(db, command, session)
            if (stop == "cancel" && checkpoint.state != "cancelling") conflict("stateConflict")
            if (stop == "pause" && checkpoint.state !in setOf("paused", "failed")) conflict("stateConflict")
            if (current.first == Long.MAX_VALUE) conflict("receiptVersionExhausted")
            val version = current.first + 1
            val receipt = checkpoint.receipt(command.key, version)
            db.execSQL(
                "INSERT INTO receipts(engine,generation,version,payload) VALUES(?,?,?,?)",
                arrayOf<Any>(command.key.engineId, command.key.generation, version, encode(receipt)),
            )
            db.execSQL(
                "UPDATE executions SET version=? WHERE engine=? AND generation=?",
                arrayOf<Any>(version, command.key.engineId, command.key.generation),
            )
            db.execSQL(
                "UPDATE worker_authorizations SET version=?,finished=? WHERE command_id=?",
                arrayOf<Any>(version, if (finished) 1 else 0, command.commandId),
            )
            // Associate the existing force-certified prefix with this receipt without
            // promoting its offset to the (possibly unforced) progress byte count.
            db.execSQL(
                "UPDATE resume_checkpoints SET receipt_version=? WHERE command_id=? AND offset<=?",
                arrayOf<Any>(version, command.commandId, checkpoint.downloadedBytes),
            )
            receipt
        }

    fun finishWorker(
        command: NativeCommand,
        session: String,
        checkpoint: NativeCheckpoint,
        pause: NativeCommand?,
    ): Map<String, Any?> =
        transaction { db ->
            // A commit can succeed while its caller loses the result. Retry only the exact
            // stopped checkpoint, never grant another worker or allocate another version.
            val encodedCommand = encode(mapOf("method" to command.method, "arguments" to command.payload))
            if (command.ownerSessionId != session || command.method != "enqueue") conflict("staleSession")
            db.rawQuery("SELECT payload,result FROM commands WHERE id=?", arrayOf(command.commandId)).use {
                if (!it.moveToFirst() || it.getString(0) != encodedCommand) conflict("commandPayloadChanged")
                if (it.isNull(1)) conflict("commandOutcomeUnknown")
            }
            var finishedVersion: Long? = null
            db
                .rawQuery(
                    "SELECT session,engine,generation,version,finished FROM worker_authorizations WHERE command_id=?",
                    arrayOf(command.commandId),
                ).use {
                    if (!it.moveToFirst() || it.getString(0) != session) conflict("staleSession")
                    if (it.getString(1) != command.key.engineId || it.getLong(2) != command.key.generation) conflict("staleExecution")
                    if (it.getInt(4) != 0) finishedVersion = it.getLong(3)
                }
            if (finishedVersion != null) {
                execution(db, command.key) ?: conflict("staleExecution")
                val expected = checkpoint.receipt(command.key, finishedVersion!!)
                db
                    .rawQuery(
                        "SELECT payload FROM receipts WHERE engine=? AND generation=? AND version=?",
                        arrayOf(command.key.engineId, command.key.generation.toString(), finishedVersion.toString()),
                    ).use {
                        if (!it.moveToFirst() || it.getString(0) != encode(expected)) conflict("receiptPayload")
                    }
                if (pause != null) {
                    if (pause.method != "pause" || pause.key != command.key || pause.ownerSessionId != session) conflict("staleExecution")
                    val encoded = encode(mapOf("method" to pause.method, "arguments" to pause.payload))
                    db.rawQuery("SELECT payload,result FROM commands WHERE id=?", arrayOf(pause.commandId)).use {
                        if (!it.moveToFirst() || it.getString(0) != encoded || it.isNull(1) ||
                            it.getString(1) != encode(expected)
                        ) {
                            conflict("commandPayloadChanged")
                        }
                    }
                }
                return@transaction expected
            }
            val receipt = workerReceipt(command, session, checkpoint, true)
            if (pause != null) {
                if (pause.method != "pause" || pause.key != command.key || pause.ownerSessionId != session) conflict("staleExecution")
                val encoded = encode(mapOf("method" to pause.method, "arguments" to pause.payload))
                db.rawQuery("SELECT payload,result FROM commands WHERE id=?", arrayOf(pause.commandId)).use {
                    if (!it.moveToFirst() || it.getString(0) != encoded) conflict("commandPayloadChanged")
                    if (!it.isNull(1)) conflict("commandAlreadyCompleted")
                }
                db.execSQL("UPDATE commands SET result=? WHERE id=? AND result IS NULL", arrayOf(encode(receipt), pause.commandId))
            }
            receipt
        }

    /** Retains latest snapshot even when acknowledged; read never consumes history. */
    fun inspect(): List<Map<String, Any?>> =
        transaction { db ->
            db
                .rawQuery(
                    "SELECT r.payload FROM receipts r JOIN executions e ON r.engine=e.engine AND r.generation=e.generation WHERE r.version>e.ack OR r.version=e.version ORDER BY r.engine,r.generation,r.version",
                    null,
                ).use {
                    buildList { while (it.moveToNext()) add(decode(it.getString(0))) }
                }
        }

    fun acknowledge(ack: NativeAck) =
        transaction { db ->
            val current = execution(db, ack.key) ?: conflict("staleExecution")
            if (ack.receiptVersion > current.first) conflict("staleReceipt")
            // No material deletion path exists in this checkpoint. Refuse explicit release,
            // including old-generation release, without advancing its acknowledgement.
            if (ack.releaseResumeRefs.isNotEmpty()) conflict("materialReleaseUnavailable")
            db.execSQL(
                "UPDATE executions SET ack=MAX(ack,?) WHERE engine=? AND generation=?",
                arrayOf<Any>(ack.receiptVersion, ack.key.engineId, ack.key.generation),
            )
        }

    private fun execution(
        db: SQLiteDatabase,
        key: ExecutionKey,
    ): Pair<Long, Long>? =
        db
            .rawQuery(
                "SELECT task,version,ack FROM executions WHERE engine=? AND generation=?",
                arrayOf(key.engineId, key.generation.toString()),
            ).use {
                if (!it.moveToFirst()) {
                    null
                } else {
                    if (it.getString(0) != key.taskId) conflict("staleExecution")
                    it.getLong(1) to it.getLong(2)
                }
            }

    companion object {
        // Canonical encoding compares maps independent of codec insertion order and Int/Long width.
        internal fun encode(value: Any?): String =
            when (value) {
                null -> {
                    "null"
                }

                is Map<*, *> -> {
                    value.keys.map { it as String }.sorted().joinToString(",", "{", "}") {
                        JSONObject.quote(it) + ":" +
                            encode(value[it])
                    }
                }

                is List<*> -> {
                    value.joinToString(",", "[", "]") { encode(it) }
                }

                is String -> {
                    JSONObject.quote(value)
                }

                is Int, is Long, is Boolean -> {
                    value.toString()
                }

                else -> {
                    mismatch()
                }
            }

        private fun unwrap(value: Any?): Any? =
            when (value) {
                JSONObject.NULL -> null
                is JSONObject -> value.keys().asSequence().associateWith { unwrap(value.get(it)) }
                is JSONArray -> (0 until value.length()).map { unwrap(value.get(it)) }
                is Int -> value.toLong()
                else -> value
            }

        private fun decode(text: String) = EngineProtocol.map(unwrap(JSONObject(text)))
    }
}

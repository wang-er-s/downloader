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
) : SQLiteOpenHelper(context.applicationContext, name, null, 3) {
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
    }

    override fun onUpgrade(
        db: SQLiteDatabase,
        oldVersion: Int,
        newVersion: Int,
    ) {
        // SQLiteOpenHelper wraps this migration and user_version update in one transaction.
        // Never rewrite the v1 tables or discard an old database on failure.
        if (oldVersion !in 1..2 || newVersion != 3) {
            throw EngineProtocolException("protocolMismatch", "journalVersion")
        }
        if (oldVersion == 1) createMaterials(db)
        createWorkers(db)
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
        return HttpTransfer(privateRoot, url) { key, payload, facts ->
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

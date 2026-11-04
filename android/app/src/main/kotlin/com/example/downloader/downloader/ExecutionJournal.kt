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
) : SQLiteOpenHelper(context.applicationContext, name, null, 1) {
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
    }

    override fun onUpgrade(
        db: SQLiteDatabase,
        oldVersion: Int,
        newVersion: Int,
    ): Unit = throw EngineProtocolException("protocolMismatch", "journalVersion")

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
            db.execSQL("UPDATE executions SET version=? WHERE engine=? AND generation=?", arrayOf<Any>(version, key.engineId, key.generation))
            db.execSQL("UPDATE commands SET result=? WHERE id=?", arrayOf(payload, command.commandId))
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

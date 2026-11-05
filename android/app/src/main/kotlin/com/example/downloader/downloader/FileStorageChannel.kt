package com.example.downloader.downloader

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.FileInputStream

/** Execution-owned publication; no AppStore writes, network or rescheduling. */
class FileStorageChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, "downloader/file_storage")
    private var picker: MethodChannel.Result? = null
    private val resolver get() = activity.contentResolver
    private val log get() = AndroidEngineRuntime.journal(activity)
    private val publications =
        object : SQLiteOpenHelper(activity.applicationContext, "android_publications_v1.db", null, 1) {
            override fun onConfigure(db: SQLiteDatabase) {
                db.execSQL("PRAGMA synchronous=FULL")
            }

            override fun onCreate(db: SQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE publications(id TEXT PRIMARY KEY NOT NULL, execution TEXT NOT NULL UNIQUE, request TEXT NOT NULL, record TEXT NOT NULL)",
                )
            }

            override fun onUpgrade(
                db: SQLiteDatabase,
                oldVersion: Int,
                newVersion: Int,
            ): Unit = throw EngineProtocolException("protocolMismatch", "publicationVersion")

            override fun onDowngrade(
                db: SQLiteDatabase,
                oldVersion: Int,
                newVersion: Int,
            ): Unit = throw EngineProtocolException("protocolMismatch", "publicationVersion")
        }

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "pickDirectory") {
                if (picker != null) {
                    result.error("stateConflict", "目录选择正在进行", null)
                } else {
                    picker = result
                    activity.startActivityForResult(
                        Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                                Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                        ),
                        PICK,
                    )
                }
            } else {
                AndroidEngineRuntime.executor.execute {
                    try {
                        val args = EngineProtocol.map(call.arguments)
                        val value =
                            when (call.method) {
                                "publish" -> publish(EngineProtocol.map(args["operation"]))
                                "recoverPublication" -> recover(EngineProtocol.map(args["operation"]))
                                "cleanupPublication" -> cleanupPublication(EngineProtocol.map(args["operation"]))
                                "deleteOwned" -> fileAction(EngineProtocol.map(args["file"]), false)
                                "open" -> fileAction(EngineProtocol.map(args["file"]), true)
                                else -> throw EngineProtocolException("protocolMismatch", "storageMethod")
                            }
                        AndroidEngineRuntime.main.post { result.success(value) }
                    } catch (error: Exception) {
                        android.util.Log.e("FileStorage", "${call.method} failed; original download retained", error)
                        val code =
                            when (error) {
                                is EngineProtocolException -> error.code
                                is SecurityException -> "permissionDenied"
                                is java.io.FileNotFoundException -> "fileMissing"
                                is android.database.sqlite.SQLiteException -> "persistenceFailure"
                                else -> "fileWriteFailure"
                            }
                        AndroidEngineRuntime.main.post { result.error(code, "文件操作未完成，原始下载已保留", null) }
                    }
                }
            }
        }
    }

    fun detach() {
        picker?.error("directoryUnavailable", "目录选择已中断", null)
        picker = null
        channel.setMethodCallHandler(null)
    }

    fun onActivityResult(
        request: Int,
        result: Int,
        data: Intent?,
    ): Boolean {
        if (request != PICK) return false
        val reply = picker
        picker = null
        if (result != Activity.RESULT_OK || data?.data == null) {
            reply?.success(null)
            return true
        }
        try {
            val uri = data.data!!
            // ExternalStorageProvider's createDocument explicitly selects a unique
            // sibling name, creates a new file, and returns a fresh document ID.
            // Arbitrary providers have no equivalent no-replace guarantee.
            requireSaf(uri)
            resolver.takePersistableUriPermission(
                uri,
                data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION),
            )
            reply?.success(
                mapOf(
                    "version" to 1,
                    "platform" to "android",
                    "kind" to "userSelected",
                    "locator" to uri.toString(),
                    "displayName" to "所选目录",
                ),
            )
        } catch (error: Exception) {
            reply?.error(if (error is EngineProtocolException) error.code else "permissionDenied", "此目录无法安全保存或保持授权", null)
        }
        return true
    }

    private fun requireSaf(tree: Uri) {
        if (tree.scheme != "content" || tree.authority != "com.android.externalstorage.documents" ||
            !DocumentsContract.isTreeUri(tree)
        ) {
            fail("directoryUnsupported")
        }
        val provider = activity.packageManager.resolveContentProvider(tree.authority!!, 0) ?: fail("directoryUnsupported")
        if (provider.packageName != "com.android.externalstorage" ||
            provider.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM == 0
        ) {
            fail("directoryUnsupported")
        }
    }

    private fun fail(code: String): Nothing = throw EngineProtocolException(code, "fileStorage")

    private fun read(id: String): JSONObject? =
        publications.readableDatabase.rawQuery("SELECT record FROM publications WHERE id=?", arrayOf(id)).use {
            if (it.moveToFirst()) JSONObject(it.getString(0)) else null
        }

    private fun save(
        op: Map<String, Any?>,
        record: JSONObject,
        phase: String,
    ) {
        record.put("phase", phase)
        val id = EngineProtocol.string(op, "operationId")
        val execution = ExecutionJournal.encode(op["key"])
        val db = publications.writableDatabase
        db.beginTransaction()
        try {
            db.rawQuery("SELECT id FROM publications WHERE execution=?", arrayOf(execution)).use {
                if (it.moveToFirst() && it.getString(0) != id) fail("stateConflict")
            }
            db.execSQL(
                "INSERT INTO publications(id,execution,request,record) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET record=excluded.record",
                arrayOf(id, execution, record.getString("request"), record.toString()),
            )
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    private fun record(op: Map<String, Any?>): JSONObject? {
        val record = read(EngineProtocol.string(op, "operationId")) ?: return null
        val original = JSONObject(record.getString("request"))
        for (key in listOf("operationId", "key", "sourceRef", "sourceLength", "directory", "temporaryName")) {
            if (original.get(key).toString() != JSONObject(ExecutionJournal.encode(op)).get(key).toString()) fail("stateConflict")
        }
        val candidate = op["candidateName"]
        if (candidate != original.getString("candidateName") && candidate != record.optString("actualName", "")) fail("stateConflict")
        return record
    }

    private fun safeName(value: String): String {
        if (value.isBlank() || value == "." || value == ".." || value.any { it in "/\\\u0000" || it.code < 32 }) fail("invalidInput")
        return value
    }

    private fun directory(op: Map<String, Any?>): Pair<Boolean, String> {
        val directory = EngineProtocol.map(op["directory"])
        if (directory["platform"] != "android") fail("invalidInput")
        val sub = (directory["subdirectory"] as? String)?.let { safeName(it) + "/" } ?: ""
        return when (directory["kind"]) {
            "systemDownloads" -> {
                if (Build.VERSION.SDK_INT <
                    29
                ) {
                    fail("directoryUnsupported")
                }
                true to (Environment.DIRECTORY_DOWNLOADS + "/Downloader/" + sub)
            }

            "userSelected" -> {
                if (sub.isNotEmpty()) fail("directoryUnsupported")
                val tree = Uri.parse(EngineProtocol.string(directory, "locator"))
                requireSaf(tree)
                val grant = resolver.persistedUriPermissions.firstOrNull { it.uri == tree && it.isReadPermission && it.isWritePermission }
                if (grant == null) fail("permissionDenied")
                false to tree.toString()
            }

            else -> {
                fail("invalidInput")
            }
        }
    }

    private fun collection() = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

    private fun row(
        uri: Uri,
        media: Boolean,
    ): Map<String, Any?>? {
        val columns =
            if (media) {
                arrayOf(
                    MediaStore.MediaColumns._ID,
                    MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaStore.MediaColumns.SIZE,
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    MediaStore.MediaColumns.IS_PENDING,
                    MediaStore.MediaColumns.OWNER_PACKAGE_NAME,
                )
            } else {
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                )
            }
        return resolver.query(uri, columns, null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) {
                null
            } else {
                columns.associateWith { key ->
                    val index = cursor.getColumnIndexOrThrow(key)
                    if (cursor.isNull(index)) null else cursor.getString(index)
                }
            }
        }
    }

    private fun identity(
        uri: Uri,
        media: Boolean,
        create: Boolean = false,
    ): String {
        val token = if (media) uri.toString() else DocumentsContract.getDocumentId(uri)
        return resolver.openFileDescriptor(uri, if (create) "rw" else "r")?.use { descriptor ->
            val stat = android.system.Os.fstat(descriptor.fileDescriptor)
            if (!android.system.OsConstants.S_ISREG(stat.st_mode) || stat.st_ino == 0L) fail("directoryUnsupported")
            "$token:${stat.st_dev}:${stat.st_ino}"
        } ?: fail("publicationUncertain")
    }

    private fun verifiedLength(record: JSONObject): Long {
        val uri = Uri.parse(record.getString("uri"))
        val token = if (record.getBoolean("media")) uri.toString() else DocumentsContract.getDocumentId(uri)
        return resolver.openFileDescriptor(uri, "r")?.use { descriptor ->
            val stat = android.system.Os.fstat(descriptor.fileDescriptor)
            if ("$token:${stat.st_dev}:${stat.st_ino}" != record.getString("identity")) fail("publicationUncertain")
            // Provider SIZE metadata may lag a closed write; verify the saved file descriptor identity and length.
            stat.st_size
        } ?: fail("publicationUncertain")
    }

    private fun verify(record: JSONObject): Map<String, Any?>? {
        if (!record.has("uri")) return null
        val media = record.getBoolean("media")
        val uri = Uri.parse(record.getString("uri"))
        val row = row(uri, media) ?: return null
        if (identity(uri, media) != record.getString("identity")) fail("publicationUncertain")
        if (media &&
            (
                row[MediaStore.MediaColumns.OWNER_PACKAGE_NAME] != activity.packageName ||
                    row[MediaStore.MediaColumns.RELATIVE_PATH] != record.getString("parent")
            )
        ) {
            fail("publicationUncertain")
        }
        if (!media) {
            val tree = Uri.parse(record.getString("parent"))
            requireSaf(tree)
            if (!DocumentsContract.isChildDocument(
                    resolver,
                    DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree)),
                    uri,
                )
            ) {
                fail("publicationUncertain")
            }
        }
        return row
    }

    private fun location(record: JSONObject): Map<String, Any?> =
        mapOf(
            "version" to 1,
            "platform" to "android",
            "kind" to "contentUri",
            "locator" to record.getString("uri"),
            "identity" to record.getString("identity"),
        )

    private fun recovered(record: JSONObject): Map<String, Any?> {
        val phase = record.getString("phase")
        if (phase == "cleaned") return mapOf("version" to 1, "disposition" to "notCreated")
        if (!record.has("uri")) {
            return mapOf(
                "version" to 1,
                "disposition" to if (phase in setOf("prepared", "cleaning")) "notCreated" else "uncertain",
            )
        }
        if (!record.has("identity")) return mapOf("version" to 1, "disposition" to "uncertain")
        val row = verify(record) ?: return mapOf("version" to 1, "disposition" to if (phase == "cleaning") "notCreated" else "uncertain")
        val media = record.getBoolean("media")
        val complete = verifiedLength(record) == record.getLong("length")
        val published =
            if (media) {
                row[MediaStore.MediaColumns.IS_PENDING] == "0" && complete
            } else {
                complete &&
                    phase == "published"
            }
        return mapOf("version" to 1, "disposition" to if (published) "published" else "staged", "ownedLocation" to location(record))
    }

    private fun recover(op: Map<String, Any?>): Map<String, Any?> {
        val record = record(op) ?: return mapOf("version" to 1, "disposition" to "notCreated")
        return try {
            directory(op)
            recovered(record)
        } catch (
            error: SecurityException,
        ) {
            mapOf("version" to 1, "disposition" to "needsPermission")
        } catch (error: EngineProtocolException) {
            when (error.code) {
                "permissionDenied" -> mapOf("version" to 1, "disposition" to "needsPermission")
                "publicationUncertain" -> mapOf("version" to 1, "disposition" to "uncertain")
                else -> throw error
            }
        }
    }

    private fun cleanupPublication(op: Map<String, Any?>): Any? {
        val record = record(op) ?: return null
        if (record.getString("phase") == "cleaned") return null
        directory(op)
        val disposition = recovered(record)["disposition"]
        if (disposition !in setOf("staged", "notCreated")) fail("cleanupFailure")
        save(op, record, "cleaning")
        if (disposition == "staged") {
            verify(record) ?: fail("cleanupFailure")
            val uri = Uri.parse(record.getString("uri"))
            if (record.getBoolean("media")) {
                if (resolver.delete(uri, null, null) != 1) fail("cleanupFailure")
            } else {
                fail("cleanupFailure") // SAF document IDs encode paths; deleteDocument cannot bind the checked inode.
            }
        }
        if (recovered(record)["disposition"] != "notCreated") fail("cleanupFailure")
        save(op, record, "cleaned")
        return null
    }

    private fun publish(op: Map<String, Any?>): Map<String, Any?> {
        val source = log.publicationSource(op)
        val length = EngineProtocol.number(op, "sourceLength")
        val (media, parent) = directory(op)
        var record = record(op)
        if (record != null && record.getString("phase") in setOf("cleaning", "cleaned")) fail("stateConflict")
        if (record == null) {
            if (op["phase"] != "prepared" || op["identity"] != null || op["targetRef"] != null) fail("stateConflict")
            val candidate = safeName(EngineProtocol.string(op, "candidateName"))
            val temporary = safeName(EngineProtocol.string(op, "temporaryName"))
            if (!temporary.contains(EngineProtocol.string(op, "operationId"))) fail("invalidInput")
            record =
                JSONObject()
                    .put(
                        "request",
                        ExecutionJournal.encode(op),
                    ).put("media", media)
                    .put("parent", parent)
                    .put("length", length)
                    .put("candidate", candidate)
                    .put("temporary", temporary)
            save(op, record, "prepared")
        }
        try {
            val disposition = recovered(record)["disposition"]
            if (disposition == "uncertain") fail("publicationUncertain")
            if (disposition == "published") save(op, record, "published")
            if (disposition == "notCreated") {
                save(op, record, "creating")
                val uri =
                    if (media) {
                        val values =
                            ContentValues().apply {
                                put(MediaStore.MediaColumns.DISPLAY_NAME, record.getString("candidate"))
                                put(MediaStore.MediaColumns.TITLE, record.getString("temporary"))
                                put(MediaStore.MediaColumns.RELATIVE_PATH, parent)
                                put(MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream")
                                put(MediaStore.MediaColumns.IS_PENDING, 1)
                            }
                        resolver.insert(collection(), values) ?: fail("fileWriteFailure")
                    } else {
                        // Known AOSP ExternalStorageProvider uses unique-name create,
                        // never opens an existing document. No rename is necessary:
                        // the new document remains publishing until close+verification.
                        val tree = Uri.parse(parent)
                        DocumentsContract.createDocument(
                            resolver,
                            DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree)),
                            mime(record.getString("candidate")),
                            record.getString("candidate"),
                        )
                            ?: fail("fileWriteFailure")
                    }
                record.put("uri", uri.toString()).put("identity", identity(uri, media, true))
                save(op, record, "copying")
            }
            val uri = Uri.parse(record.getString("uri"))
            if (record.getString("phase") == "copying") {
                verify(record) ?: fail("publicationUncertain")
                // A second open can only address this saved row/document identity.
                resolver.openFileDescriptor(uri, "rw")?.use { output ->
                    val stat = android.system.Os.fstat(output.fileDescriptor)
                    val token = if (media) uri.toString() else DocumentsContract.getDocumentId(uri)
                    if ("$token:${stat.st_dev}:${stat.st_ino}" != record.getString("identity")) fail("publicationUncertain")
                    android.system.Os.ftruncate(output.fileDescriptor, 0)
                    FileInputStream(source).use { input ->
                        android.os.ParcelFileDescriptor.AutoCloseOutputStream(output).use { target ->
                            val count = input.copyTo(target, 1024 * 1024)
                            if (count != length || source.length() != length ||
                                android.system.Os
                                    .fstat(target.fd)
                                    .st_size != length
                            ) {
                                fail("fileWriteFailure")
                            }
                            target.flush()
                            target.fd.sync()
                        }
                    }
                } ?: fail("fileWriteFailure")
                verify(record) ?: fail("publicationUncertain")
                if (verifiedLength(record) != length) fail("fileWriteFailure")
                save(op, record, "finalizing")
            }
            if (record.getString("phase") == "finalizing") {
                if (media && disposition != "published") {
                    verify(record) ?: fail("publicationUncertain")
                    // The final name was allocated by INSERT, not a rename.
                    // Finalization only makes this verified own row visible.
                    val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                    if (resolver.update(uri, values, null, null) != 1) fail("publicationUncertain")
                }
                save(op, record, "published")
            }
            val final = recovered(record)
            if (final["disposition"] != "published") fail("publicationUncertain")
            val file = location(record)
            val finalRow = verify(record) ?: fail("publicationUncertain")
            val actualName =
                finalRow[if (media) MediaStore.MediaColumns.DISPLAY_NAME else DocumentsContract.Document.COLUMN_DISPLAY_NAME] as? String
                    ?: fail("publicationUncertain")
            record.put("actualName", actualName)
            save(op, record, "published")
            log.publicationReceipt(op + mapOf("candidateName" to actualName), file)
            return file
        } catch (error: Exception) {
            val code =
                when (error) {
                    is EngineProtocolException -> error.code
                    is SecurityException -> "permissionDenied"
                    is android.database.sqlite.SQLiteException -> "persistenceFailure"
                    else -> "fileWriteFailure"
                }
            record.put("error", JSONObject().put("code", code).put("message", "文件操作未完成，原始下载已保留"))
            try {
                save(op, record, record.getString("phase"))
            } catch (diagnostic: Exception) {
                error.addSuppressed(diagnostic)
            }
            throw error
        }
    }

    private fun mime(name: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"

    private fun fileAction(
        file: Map<String, Any?>,
        open: Boolean,
    ): Any? {
        val stored =
            publications.readableDatabase.rawQuery("SELECT record FROM publications", null).use { cursor ->
                var found: JSONObject? = null
                while (cursor.moveToNext()) {
                    val candidate = JSONObject(cursor.getString(0))
                    if (candidate.has("uri") && candidate.has("identity") &&
                        ExecutionJournal.encode(location(candidate)) == ExecutionJournal.encode(file)
                    ) {
                        found = candidate
                        break
                    }
                }
                found
            } ?: fail("cleanupFailure")
        val current = verify(stored)
        if (current == null) {
            if (open) fail("fileMissing") else return null
        }
        val uri = Uri.parse(stored.getString("uri"))
        if (!open) {
            if (stored.getBoolean("media")) {
                if (resolver.delete(uri, null, null) != 1) fail("cleanupFailure")
            } else {
                // ExternalStorageProvider may resolve the same document ID to a
                // replacement file. Refuse destructive pathname-based deletion.
                fail("cleanupFailure")
            }
            return null
        }
        val type = mime(stored.getString("candidate"))
        val installPermissionRequired =
            type == "application/vnd.android.package-archive" && Build.VERSION.SDK_INT >= 26 &&
                !activity.packageManager.canRequestPackageInstalls()
        val intent =
            if (installPermissionRequired) {
                Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
            } else {
                Intent(Intent.ACTION_VIEW).setDataAndType(uri, type).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        if (intent.resolveActivity(activity.packageManager) == null) fail("noHandler")
        val opened = java.util.concurrent.FutureTask<Unit> { activity.startActivity(intent) }
        AndroidEngineRuntime.main.post(opened)
        try {
            opened.get()
        } catch (error: Exception) {
            fail("noHandler")
        }
        if (installPermissionRequired) fail("installPermissionRequired")
        return null
    }

    companion object {
        const val PICK = 7391
    }
}

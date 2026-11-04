package com.example.downloader.downloader

import java.net.URI

internal class EngineProtocolException(
    val code: String,
    val reason: String,
) : RuntimeException(reason)

internal fun mismatch(): Nothing = throw EngineProtocolException("protocolMismatch", "invalidPayload")

internal fun conflict(reason: String): Nothing = throw EngineProtocolException("stateConflict", reason)

internal object EngineProtocol {
    const val METHOD_CHANNEL = "downloader/android_engine"
    const val EVENT_CHANNEL = "downloader/android_engine/events"

    fun map(value: Any?): Map<String, Any?> {
        if (value !is Map<*, *> || value.keys.any { it !is String }) mismatch()
        return value.entries.associate { it.key as String to it.value }
    }

    fun string(
        map: Map<String, Any?>,
        field: String,
    ): String = (map[field] as? String)?.takeIf { validString(it) } ?: mismatch()

    private fun validString(value: String): Boolean =
        value.isNotBlank() && value.none { it.code < 32 || it.code in 127..159 }

    fun number(
        map: Map<String, Any?>,
        field: String,
        positive: Boolean = false,
    ): Long {
        val n =
            when (val value = map[field]) {
                is Int -> value.toLong()
                is Long -> value
                else -> mismatch()
            }
        if (n < 0 || (positive && n == 0L)) mismatch()
        return n
    }

    fun request(value: Any?): Map<String, Any?> =
        map(value).also {
            if (number(it, "protocolVersion") != 1L) mismatch()
        }

    fun key(map: Map<String, Any?>) = ExecutionKey(string(map, "taskId"), string(map, "engineId"), number(map, "generation"))

    fun command(
        method: String,
        value: Any?,
    ): NativeCommand {
        val map = request(value)
        val key = key(map)
        val command =
            NativeCommand(
                method,
                string(map, "commandId"),
                key,
                string(map, "ownerSessionId"),
                number(map, "expectedReceiptVersion"),
                map,
            )
        if (method == "enqueue") validateTask(map, key)
        return command
    }

    private fun validateTask(
        map: Map<String, Any?>,
        key: ExecutionKey,
    ) {
        // EngineTask uses a nested versioned key; the transport command is flat.
        val input = request(map["input"])
        val nested = map(input["key"])
        if (number(nested, "version") != 1L) mismatch()
        if (key(nested) != key) conflict("staleExecution")
        val uri =
            try {
                URI(string(input, "url"))
            } catch (_: Exception) {
                mismatch()
            }
        if (uri.scheme !in listOf("http", "https") || uri.host.isNullOrBlank() || uri.userInfo != null) mismatch()
        string(input, "stagingLocation") // Authorization and private-path ownership belong to the worker.
        input["requestedFileName"]?.let { filename(it) }
        val directory = map(input["directory"])
        if (number(directory, "version") != 1L || directory["platform"] != "android") mismatch()
        string(directory, "displayName")
        when (directory["kind"]) {
            "systemDownloads" -> {
                if (directory["locator"] != null) mismatch()
            }

            "userSelected" -> {
                val locator =
                    try {
                        URI(string(directory, "locator"))
                    } catch (_: Exception) {
                        mismatch()
                    }
                if (locator.scheme != "content") mismatch()
            }

            else -> {
                mismatch()
            }
        }
        directory["subdirectory"]?.let { filename(it) }
    }

    private fun filename(value: Any?) {
        if (value !is String || !validString(value) || value == "." || value == ".." ||
            value.endsWith('.') || value.endsWith(' ') ||
            Regex("^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\.|$)", RegexOption.IGNORE_CASE).containsMatchIn(value) ||
            value.any { it in "/\\<>:\"|?*" }
        ) {
            mismatch()
        }
    }

    fun ack(value: Any?): NativeAck {
        val map = request(value)
        val refs = map["releaseResumeRefs"] as? List<*> ?: mismatch()
        if (refs.any { it !is String || !validString(it) }) mismatch()
        return NativeAck(key(map), number(map, "receiptVersion", true), refs.map { it as String })
    }
}

internal data class ExecutionKey(
    val taskId: String,
    val engineId: String,
    val generation: Long,
) {
    fun json() = mapOf("version" to 1L, "taskId" to taskId, "engineId" to engineId, "generation" to generation)
}

internal data class NativeCommand(
    val method: String,
    val commandId: String,
    val key: ExecutionKey,
    val ownerSessionId: String,
    val expectedReceiptVersion: Long,
    val payload: Map<String, Any?>,
)

internal data class NativeAck(
    val key: ExecutionKey,
    val receiptVersion: Long,
    val releaseResumeRefs: List<String>,
)

/** Only facts the current journal can commit. No synthetic transfer or publication states. */
internal data class NativeCheckpoint(
    val state: String,
    val downloadedBytes: Long,
    val totalBytes: Long? = null,
    val resumeSupport: String = "unknown",
    val resumeRef: String? = null,
    val stagingLocation: String? = null,
) {
    init {
        require(state in setOf("queued", "running", "paused", "waitingRecovery", "failed", "cancelling"))
        require(downloadedBytes >= 0 && (totalBytes == null || totalBytes >= 0))
        require(resumeSupport in setOf("unknown", "supported", "unsupported"))
        require(resumeRef == null || resumeRef.isNotBlank())
        require(stagingLocation == null || stagingLocation.isNotBlank())
    }

    fun receipt(
        key: ExecutionKey,
        version: Long,
    ): Map<String, Any?> =
        mapOf(
            "protocolVersion" to 1L,
            "key" to key.json(),
            "receiptVersion" to version,
            "state" to state,
            "downloadedBytes" to downloadedBytes,
            "totalBytes" to totalBytes,
            "resumeSupport" to resumeSupport,
            "resumeRef" to resumeRef,
            "stagingLocation" to stagingLocation,
            "publishOperation" to null,
            "publishedLocation" to null,
            "error" to null,
        )
}

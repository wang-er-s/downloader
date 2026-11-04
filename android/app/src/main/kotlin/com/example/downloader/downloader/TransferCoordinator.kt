package com.example.downloader.downloader

import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** All mutable execution state is confined to queue. No database row is a scheduling source. */
internal class TransferCoordinator(
    val session: String,
    private val queue: ExecutorService,
    private val journal: Journal,
    private val launch: (String) -> Unit,
    private val idle: () -> Unit,
    private val event: (Map<String, Any?>) -> Unit,
    private val diagnostic: (Exception) -> Unit = {},
    val lifecycle: ServiceLifecycle = ServiceLifecycle(),
) {
    interface Journal {
        fun register(command: NativeCommand): Map<String, Any?>?

        fun accept(command: NativeCommand): Map<String, Any?>

        fun transfer(command: NativeCommand): HttpTransfer

        fun stop(
            worker: NativeCommand,
            command: NativeCommand,
            checkpoint: NativeCheckpoint,
        ): Map<String, Any?>

        fun receipt(
            command: NativeCommand,
            checkpoint: NativeCheckpoint,
        ): Map<String, Any?>

        fun finish(
            command: NativeCommand,
            checkpoint: NativeCheckpoint,
            pause: NativeCommand?,
        ): Map<String, Any?>
    }

    private class Work(
        val command: NativeCommand,
        val accepted: CompletableFuture<Map<String, Any?>>,
    ) {
        val stop = HttpTransfer.Stop()
        var active = false
        var ready = false
        var bytes = 0L
        var total: Long? = null
        var sampleAt = 0L
        var intent: String? = null
        var failureCode: String? = null
        var pause: NativeCommand? = null
        var cancel: NativeCommand? = null
        var pauseResult: CompletableFuture<Map<String, Any?>>? = null
        lateinit var token: String
        var terminal: NativeCheckpoint? = null
        var saveFailure = false
    }

    private val workers = Executors.newFixedThreadPool(2)
    private val work = linkedMapOf<ExecutionKey, Work>()
    var sequence = 0L
        private set

    fun command(input: NativeCommand): CompletableFuture<Map<String, Any?>> {
        fun copy(value: Any?): Any? =
            when (value) {
                is Map<*, *> -> value.entries.associate { it.key to copy(it.value) }
                is List<*> -> value.map { copy(it) }
                else -> value
            }
        val command = EngineProtocol.command(input.method, copy(input.payload))
        val result = CompletableFuture<Map<String, Any?>>()
        queue.execute {
            try {
                if (command.ownerSessionId != session) conflict("staleSession")
                if (command.method == "resume") conflict("restartRequired")
                if (command.method == "enqueue" &&
                    work.keys.any { it.taskId == command.key.taskId && it != command.key }
                ) {
                    conflict("staleExecution")
                }
                val retained = work[command.key]
                if (retained?.saveFailure == true) {
                    val original =
                        when (command.method) {
                            "enqueue" -> retained.command
                            "cancel" -> retained.cancel
                            else -> retained.pause
                        }

                    fun same(
                        a: Any?,
                        b: Any?,
                    ): Boolean =
                        when {
                            a is Map<*, *> && b is Map<*, *> -> a.keys == b.keys && a.keys.all { same(a[it], b[it]) }
                            a is List<*> && b is List<*> -> a.size == b.size && a.indices.all { same(a[it], b[it]) }
                            (a is Int || a is Long) && (b is Int || b is Long) -> (a as Number).toLong() == (b as Number).toLong()
                            else -> a == b
                        }
                    if (original == null || original.method != command.method ||
                        !same(original.payload, command.payload)
                    ) {
                        conflict("commandOutcomeUnknown")
                    }
                    // The cancel intent already committed its immutable cleanupFailure result.
                    if (command.method == "cancel") throw EngineProtocolException("cleanupFailure", "materialReleaseUnavailable")
                    if (command.method == "pause") retained.pauseResult = result
                    val receipt = saveTerminal(retained)
                    if (command.method == "pause") completePause(result, receipt) else result.complete(receipt)
                    return@execute
                }
                val replay = journal.register(command)
                if (replay != null) {
                    if (command.method == "cancel") throw EngineProtocolException("cleanupFailure", "materialReleaseUnavailable")
                    if (command.method == "pause" && replay["state"] != "paused") {
                        val failure = replay["error"] as? Map<*, *>
                        throw EngineProtocolException(failure?.get("code") as? String ?: "stateConflict", "transferUnavailable")
                    }
                    result.complete(replay)
                } else if (command.method == "enqueue") {
                    val accepted = journal.accept(command)
                    val item = Work(command, result)
                    work[command.key] = item
                    emit(accepted)
                    val token = lifecycle.issue(item.stop)
                    item.token = token
                    try {
                        launch(token)
                    } catch (error: Exception) {
                        launchFailed(token, error)
                    }
                } else {
                    val item = work[command.key] ?: conflict("transferUnavailable")
                    if (item.intent == "cancel" || (item.pause != null && command.method != "cancel")) conflict("commandResultUnknown")
                    val cancelling = command.method == "cancel"
                    val receipt = journal.stop(item.command, command, checkpoint(item, if (cancelling) "cancelling" else "running"))
                    item.intent = command.method
                    if (cancelling) {
                        item.cancel = command
                        emit(receipt)
                        result.completeExceptionally(EngineProtocolException("cleanupFailure", "materialReleaseUnavailable"))
                    } else {
                        item.pause = command
                        item.pauseResult = result
                    }
                    lifecycle.revoke(item.token)
                    item.stop.request(if (cancelling) HttpTransfer.Stop.Reason.CANCEL else HttpTransfer.Stop.Reason.PAUSE)
                    if (!item.active) finish(item, null, null)
                }
            } catch (error: Exception) {
                result.completeExceptionally(error)
            }
        }
        return result
    }

    /** Production passes the actual foreground Service instance identity. */
    fun serviceReady(
        token: String?,
        instance: String? = null,
    ): Boolean {
        val item = work.values.firstOrNull { it.token == token } ?: return false
        if (!lifecycle.ready(token, instance) || item.terminal != null) return false
        item.ready = true
        item.accepted.complete(mapOf("accepted" to true))
        drain()
        return true
    }

    fun launchFailed(
        token: String,
        error: Exception,
    ) {
        val item = work.values.firstOrNull { it.token == token } ?: return
        if (item.ready || item.active || item.terminal != null) return
        lifecycle.revoke(token)
        item.failureCode = if (error is SecurityException) "permissionDenied" else "backgroundRestricted"
        item.accepted.completeExceptionally(EngineProtocolException(item.failureCode!!, "transferUnavailable"))
        finish(item, null, error)
    }

    fun restrict(
        code: String = "backgroundRestricted",
        owned: Set<String>? = null,
    ) {
        val stopping = work.values.filter { it.terminal == null && (owned == null || it.token in owned) }
        stopping.forEach {
            lifecycle.revoke(it.token)
            it.stop.request(HttpTransfer.Stop.Reason.PAUSE)
            it.failureCode = code
            it.intent = it.intent ?: "system"
        }
        for (item in stopping) {
            item.accepted.completeExceptionally(EngineProtocolException(code, "transferUnavailable"))
            if (!item.active) finish(item, null, IllegalStateException(code))
        }
    }

    fun pendingSaveCount(): Int = work.values.count { it.saveFailure }

    fun assertInspectable() {
        if (pendingSaveCount() != 0) throw EngineProtocolException("persistenceFailure", "terminalSavePending")
    }

    fun hasWork(): Boolean = work.isNotEmpty()

    private fun drain() {
        for (item in work.values.toList()) {
            if (work.values.count { it.active } >= 2) break
            if (work[item.command.key] !== item || item.active || item.terminal != null || !item.ready || item.intent != null) continue
            try {
                val transfer = journal.transfer(item.command)
                emit(journal.receipt(item.command, checkpoint(item, "running")))
                val authorized =
                    lifecycle.worker(item.token) {
                        item.active = true
                        workers.execute {
                            try {
                                val staged =
                                    transfer.run(
                                        item.command.key,
                                        EngineProtocol.string(EngineProtocol.map(item.command.payload["input"]), "url"),
                                        item.stop,
                                    ) { sample ->
                                        // Backpressure bounds the queue and propagates persistence failure into run.
                                        val saved = CompletableFuture<Unit>()
                                        queue.execute {
                                            try {
                                                item.bytes = sample.bytes
                                                item.total = sample.total
                                                if (item.intent == null && sample.monotonicMs - item.sampleAt >= 1000) {
                                                    emit(journal.receipt(item.command, checkpoint(item, "running")), sample.monotonicMs)
                                                    item.sampleAt = sample.monotonicMs
                                                }
                                                saved.complete(Unit)
                                            } catch (error: Exception) {
                                                saved.completeExceptionally(error)
                                            }
                                        }
                                        saved.get()
                                    }
                                queue.execute { finish(item, staged, null) }
                            } catch (error: Exception) {
                                queue.execute { finish(item, null, error) }
                            }
                        }
                    }
                if (!authorized) {
                    item.failureCode = "backgroundRestricted"
                    finish(item, null, IllegalStateException("authorizationExpired"))
                }
            } catch (error: Exception) {
                finish(item, null, error)
            }
        }
    }

    private fun finish(
        item: Work,
        staged: HttpTransfer.Staged?,
        error: Exception?,
    ) {
        if (work[item.command.key] !== item || item.terminal != null) return
        if (item.intent == null && item.stop.reason != null) {
            item.intent = "system"
            item.failureCode = "backgroundRestricted"
        }
        if (staged != null) {
            item.bytes = staged.bytes
            item.total = staged.total
        }
        if (error is HttpTransfer.Failure) item.bytes = error.bytes
        val state =
            when {
                item.intent == "cancel" -> "cancelling"
                error != null || item.failureCode != null -> "failed"
                item.intent == "pause" -> "paused"
                else -> "publishing"
            }
        val code =
            when {
                item.intent == "cancel" -> "cleanupFailure"
                item.failureCode != null -> item.failureCode
                error != null -> failureCode(error)
                else -> null
            }
        val location = if (state == "publishing") staged?.file?.path else null
        item.active = false // actual worker has returned; retained saves never occupy a worker slot.
        item.terminal = checkpoint(item, state, code, location)
        lifecycle.revoke(item.token)
        try {
            val receipt = saveTerminal(item)
            if (state == "paused" || state == "cancelling") {
                item.accepted.complete(mapOf("accepted" to true))
            } else {
                item.accepted.completeExceptionally(EngineProtocolException(code ?: "stateConflict", "transferUnavailable"))
            }
            item.pauseResult?.let { completePause(it, receipt) }
        } catch (failure: Exception) {
            item.saveFailure = true
            val error = EngineProtocolException("persistenceFailure", "terminalSavePending")
            diagnostic(failure)
            item.pauseResult?.completeExceptionally(error)
            item.accepted.completeExceptionally(error)
        }
        drain()
        if (work.values.none { it.terminal == null }) idle()
    }

    private fun completePause(
        result: CompletableFuture<Map<String, Any?>>,
        receipt: Map<String, Any?>,
    ) {
        if (receipt["state"] == "paused") {
            result.complete(receipt)
        } else {
            val error = receipt["error"] as? Map<*, *>
            result.completeExceptionally(EngineProtocolException(error?.get("code") as? String ?: "stateConflict", "transferUnavailable"))
        }
    }

    private fun saveTerminal(item: Work): Map<String, Any?> {
        val receipt =
            try {
                journal.finish(item.command, item.terminal ?: error("terminalRequired"), item.pause)
            } catch (failure: Exception) {
                item.saveFailure = true
                throw EngineProtocolException("persistenceFailure", "terminalSavePending").also { it.addSuppressed(failure) }
            }
        item.saveFailure = false
        emit(receipt)
        work.remove(item.command.key)
        return receipt
    }

    private fun failureCode(error: Exception): String {
        if (error is HttpTransfer.Failure) return error.code
        if (error is HttpTransfer.StageFailure) return error.code
        var cause: Throwable? = error
        while (cause != null) {
            when (cause) {
                is java.net.SocketTimeoutException -> return "timeout"
                is java.net.SocketException, is java.net.UnknownHostException -> return "networkUnavailable"
                is java.util.concurrent.ExecutionException -> return "persistenceFailure"
            }
            cause = cause.cause
        }
        return "fileWriteFailure"
    }

    private fun checkpoint(
        item: Work,
        state: String,
        code: String? = null,
        location: String? = null,
    ) = NativeCheckpoint(
        state,
        item.bytes,
        item.total,
        stagingLocation = location,
        resumeSupport = "unsupported",
        error =
            code?.let {
                mapOf(
                    "version" to 1,
                    "code" to it,
                    "message" to "原生执行停止，材料已保留",
                    "taskId" to item.command.key.taskId,
                    "details" to null,
                )
            },
    )

    private fun emit(
        receipt: Map<String, Any?>,
        time: Long = System.nanoTime() / 1_000_000,
    ) {
        sequence = Math.addExact(sequence, 1)
        try {
            event(
                mapOf(
                    "protocolVersion" to 1,
                    "ownerSessionId" to session,
                    "sequence" to sequence,
                    "key" to receipt["key"],
                    "downloadedBytes" to receipt["downloadedBytes"],
                    "totalBytes" to receipt["totalBytes"],
                    "sampleMonotonicMs" to time,
                    "receipt" to receipt,
                ),
            )
        } catch (error: Exception) {
            // A subscriber is not part of the durable operation. inspect replays this receipt.
            diagnostic(error)
        }
    }
}

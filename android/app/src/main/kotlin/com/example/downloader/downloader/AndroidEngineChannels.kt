package com.example.downloader.downloader

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

/** Process-owned journal and session. Attaching an Activity never schedules work. */
internal object AndroidEngineRuntime {
    val ownerSessionId: String = UUID.randomUUID().toString()
    val executor = Executors.newSingleThreadExecutor()
    val main = Handler(Looper.getMainLooper())

    val lifecycle = ServiceLifecycle()
    private val services = mutableMapOf<String, DownloadService>()

    // Internal instrumentation barrier; null in production. Runs outside the lifecycle monitor,
    // after the actual system request returned and before the main looper can deliver callbacks.
    internal var afterServiceStartAccepted: ((String) -> Unit)? = null

    fun attachService(
        id: String,
        service: DownloadService,
    ) {
        services[id] = service
    }

    fun detachService(id: String) {
        services.remove(id)
    }

    fun stopIdle() {
        val ticket = lifecycle.idle() ?: return
        main.post { lifecycle.stop(ticket) { id -> services[id]?.stopSelf() } }
    }

    private var journal: ExecutionJournal? = null
    private var coordinator: TransferCoordinator? = null
    private val listeners = mutableMapOf<Any, (Map<String, Any?>) -> Unit>()

    fun listen(
        owner: Any,
        listener: (Map<String, Any?>) -> Unit,
    ) {
        listeners[owner] = listener
    }

    fun unlisten(owner: Any) {
        listeners.remove(owner)
    }

    fun journal(context: Context): ExecutionJournal = journal ?: ExecutionJournal(context).also { journal = it }

    fun coordinator(context: Context): TransferCoordinator =
        coordinator ?: run {
            val app = context.applicationContext
            val log = journal(app)
            TransferCoordinator(
                ownerSessionId,
                executor,
                object : TransferCoordinator.Journal {
                    override fun beginCancel(command: NativeCommand, worker: NativeCommand?, checkpoint: NativeCheckpoint?) =
                        log.beginCancel(command, ownerSessionId, worker, checkpoint)

                    override fun finishCancel(command: NativeCommand) = log.finishCancel(command, ownerSessionId)

                    override fun register(command: NativeCommand) = log.register(command, ownerSessionId)

                    override fun accept(command: NativeCommand) = log.acceptWorker(command, ownerSessionId)

                    override fun transfer(command: NativeCommand) =
                        log.newTransfer(command, ownerSessionId) { action ->
                            val done = java.util.concurrent.CompletableFuture<Unit>()
                            executor.execute {
                                try {
                                    action()
                                    done.complete(Unit)
                                } catch (error: Exception) {
                                    done.completeExceptionally(error)
                                }
                            }
                            done.get()
                        }

                    override fun acceptResume(command: NativeCommand) = log.acceptResume(command, ownerSessionId)

                    override fun recovery(command: NativeCommand) =
                        log.newResumeTransfer(command, ownerSessionId) { action ->
                            val done = java.util.concurrent.CompletableFuture<Unit>()
                            executor.execute {
                                try {
                                    action()
                                    done.complete(Unit)
                                } catch (error: Exception) {
                                    done.completeExceptionally(error)
                                }
                            }
                            try {
                                done.get()
                            } catch (error: java.util.concurrent.ExecutionException) {
                                throw (error.cause as? Exception ?: error)
                            }
                        }

                    override fun stop(
                        worker: NativeCommand,
                        command: NativeCommand,
                        checkpoint: NativeCheckpoint,
                    ) = log.stopWorker(worker, command, ownerSessionId, checkpoint)

                    override fun receipt(
                        command: NativeCommand,
                        checkpoint: NativeCheckpoint,
                    ) = log.workerReceipt(command, ownerSessionId, checkpoint)

                    override fun finish(
                        command: NativeCommand,
                        checkpoint: NativeCheckpoint,
                        pause: NativeCommand?,
                    ) = log.finishWorker(command, ownerSessionId, checkpoint, pause)
                },
                { token ->
                    main.post {
                        try {
                            val requested = lifecycle.pending(token) {
                                // Product policy: denied notifications prevent transmission.
                                // This preflight is not the system's promotion permission check.
                                if (android.os.Build.VERSION.SDK_INT >= 33 &&
                                    app.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                                    android.content.pm.PackageManager.PERMISSION_GRANTED
                                ) {
                                    throw SecurityException("notificationPermissionRequired")
                                }
                                val intent = android.content.Intent(app, DownloadService::class.java).putExtra("token", token)
                                if (android.os.Build.VERSION.SDK_INT >= 26) app.startForegroundService(intent) else app.startService(intent)
                            }
                            if (requested) afterServiceStartAccepted?.invoke(token)
                        } catch (error: Exception) {
                            Log.e("AndroidEngine", "Service start request failed; no retry", error)
                            executor.execute {
                                coordinator(app).launchFailed(token, error)
                            }
                        }
                    }
                },
                {
                    stopIdle()
                },
                { value ->
                    listeners.values.toList().forEach {
                        it(value)
                    }
                },
                { error -> Log.e("AndroidEngine", "Worker receipt persistence failed; retained previous facts", error) },
                lifecycle,
            ).also {
                coordinator =
                    it
            }
        }
}

internal class AndroidEngineChannels(
    context: Context,
    messenger: BinaryMessenger,
) {
    private val application = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, EngineProtocol.METHOD_CHANNEL)
    private val events = EventChannel(messenger, EngineProtocol.EVENT_CHANNEL)

    init {
        methods.setMethodCallHandler { call, result ->
            AndroidEngineRuntime.executor.execute {
                try {
                    val response: Any? =
                        when (call.method) {
                            "inspect" -> {
                                EngineProtocol.request(call.arguments)
                                AndroidEngineRuntime.coordinator(application).assertInspectable()
                                mapOf(
                                    "protocolVersion" to 1,
                                    "ownerSessionId" to AndroidEngineRuntime.ownerSessionId,
                                    "sequence" to AndroidEngineRuntime.coordinator(application).sequence,
                                    "receipts" to AndroidEngineRuntime.journal(application).inspect(),
                                )
                            }

                            "acknowledge" -> {
                                AndroidEngineRuntime.journal(application).acknowledge(EngineProtocol.ack(call.arguments))
                                null
                            }

                            "enqueue", "pause", "resume", "cancel" -> {
                                val command = EngineProtocol.command(call.method, call.arguments)
                                AndroidEngineRuntime.coordinator(application).command(command).whenComplete { value, failure ->
                                    main.post {
                                        val error = if (failure is java.util.concurrent.CompletionException) failure.cause else failure
                                        when (error) {
                                            null -> {
                                                result.success(value)
                                            }

                                            is EngineProtocolException -> {
                                                result.error(
                                                    error.code,
                                                    error.reason,
                                                    mapOf("reason" to error.reason),
                                                )
                                            }

                                            else -> {
                                                Log.e("AndroidEngine", "Execution failed", error)
                                                result.error("persistenceFailure", "Native execution failed", null)
                                            }
                                        }
                                    }
                                }
                                return@execute
                            }

                            else -> {
                                throw EngineProtocolException("protocolMismatch", "unknownMethod")
                            }
                        }
                    main.post { result.success(response) }
                } catch (error: EngineProtocolException) {
                    main.post { result.error(error.code, error.reason, mapOf("reason" to error.reason)) }
                } catch (error: Exception) {
                    // Keep the actual exception and stack trace in native diagnostics; do not leak paths over the channel.
                    Log.e("AndroidEngine", "Native execution journal failed", error)
                    main.post {
                        result.error(
                            "persistenceFailure",
                            "Native execution journal failed",
                            mapOf("exceptionType" to error.javaClass.name),
                        )
                    }
                }
            }
        }
        events.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(
                    arguments: Any?,
                    sink: EventChannel.EventSink,
                ) {
                    try {
                        EngineProtocol.request(arguments)
                    } catch (error: EngineProtocolException) {
                        sink.error(error.code, error.reason, mapOf("reason" to error.reason))
                        return
                    }
                    AndroidEngineRuntime.executor.execute {
                        AndroidEngineRuntime.listen(this@AndroidEngineChannels) { value -> main.post { sink.success(value) } }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    AndroidEngineRuntime.executor.execute { AndroidEngineRuntime.unlisten(this@AndroidEngineChannels) }
                }
            },
        )
    }

    fun detach() {
        AndroidEngineRuntime.executor.execute { AndroidEngineRuntime.unlisten(this) }
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}

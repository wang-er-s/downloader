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
    private var journal: ExecutionJournal? = null

    fun journal(context: Context): ExecutionJournal = journal ?: ExecutionJournal(context).also { journal = it }
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
                                mapOf(
                                    "protocolVersion" to 1,
                                    "ownerSessionId" to AndroidEngineRuntime.ownerSessionId,
                                    "sequence" to 0L,
                                    "receipts" to AndroidEngineRuntime.journal(application).inspect(),
                                )
                            }

                            "acknowledge" -> {
                                AndroidEngineRuntime.journal(application).acknowledge(EngineProtocol.ack(call.arguments))
                                null
                            }

                            "enqueue", "pause", "resume", "cancel" -> {
                                val command = EngineProtocol.command(call.method, call.arguments)
                                if (command.ownerSessionId != AndroidEngineRuntime.ownerSessionId) conflict("staleSession")
                                throw EngineProtocolException("stateConflict", "transferUnavailable")
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
                    }
                    // No worker is connected yet: no fabricated events or transfer completion.
                }

                override fun onCancel(arguments: Any?) = Unit
            },
        )
    }

    fun detach() {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}

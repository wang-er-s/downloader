package com.example.downloader.downloader

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import com.example.downloader.MainActivity
import java.io.File
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.TimeUnit

/** Device-only harness. Uses the process Runtime and real Service; no scheduling substitute. */
internal class ServiceRuntimeTest(
    private val instrumentation: Instrumentation,
    private val baseUrl: String,
) {
    private val context get() = instrumentation.targetContext
    private var activity: Activity? = null
    private val key = ExecutionKey("runtime-${UUID.randomUUID()}", "runtime-${UUID.randomUUID()}", 0)

    private fun <T> queue(action: () -> T): T = AndroidEngineRuntime.executor.submit(Callable(action)).get(40, TimeUnit.SECONDS)

    private fun launch() {
        activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        instrumentation.waitForIdleSync()
        check(activity != null)
    }

    private fun detach() {
        activity?.let { current -> instrumentation.runOnMainSync { current.finish() } }
        instrumentation.waitForIdleSync()
        activity = null
    }

    private fun command(
        method: String,
        version: Long = 0,
    ): Map<String, Any?> {
        val payload =
            mutableMapOf<String, Any?>(
                "protocolVersion" to 1,
                "taskId" to key.taskId,
                "engineId" to key.engineId,
                "generation" to 0L,
                "commandId" to UUID.randomUUID().toString(),
                "ownerSessionId" to AndroidEngineRuntime.ownerSessionId,
                "expectedReceiptVersion" to version,
            )
        if (method == "enqueue") {
            payload["input"] =
                mapOf(
                    "protocolVersion" to 1,
                    "key" to key.json(),
                    "url" to "$baseUrl/data/${key.taskId}",
                    "stagingLocation" to "private",
                    "directory" to
                        mapOf(
                            "version" to 1,
                            "platform" to "android",
                            "kind" to "systemDownloads",
                            "displayName" to "Downloads",
                        ),
                )
        }
        val future = queue { AndroidEngineRuntime.coordinator(context).command(EngineProtocol.command(method, payload)) }
        return future.get(40, TimeUnit.SECONDS)!!
    }

    private fun inspect(): List<Map<String, Any?>> =
        queue {
            AndroidEngineRuntime.coordinator(context).assertInspectable()
            AndroidEngineRuntime.journal(context).inspect()
        }

    private fun latest(): Map<String, Any?>? =
        inspect()
            .filter {
                it["engineId"] == key.engineId ||
                    (it["key"] as? Map<*, *>)?.get("engineId") == key.engineId
            }.maxByOrNull { (it["receiptVersion"] as Number).toLong() }

    private fun waitFor(
        message: String,
        condition: () -> Boolean,
    ) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
        while (!condition()) {
            check(System.nanoTime() < deadline) { message + ": " + latest() }
            Thread.sleep(50)
        }
    }

    private fun bytes() = (latest()?.get("downloadedBytes") as? Number)?.toLong() ?: 0L

    private fun version() = (latest()!!["receiptVersion"] as Number).toLong()

    private fun evidence(value: String) {
        android.util.Log.i("ServiceRuntimeEvidence", value)
    }

    fun lifecycle() {
        launch()
        try {
            command("enqueue")
            waitFor("Service did not write bytes") { bytes() >= 8192 }
            val manager = context.getSystemService(android.app.ActivityManager::class.java)

            @Suppress("DEPRECATION")
            val service = manager.getRunningServices(100).single { it.service.className == DownloadService::class.java.name }
            check(service.foreground) { "DownloadService is not foreground" }
            evidence("real foreground Service pid=${service.pid} enqueue bytes=${bytes()} receipt=${latest()}")
            // A running worker can only be submitted after the real Service foreground handshake.
            val first = bytes()
            detach()
            waitFor("Activity detach stopped download") { bytes() > first }
            launch()
            val before = bytes()
            waitFor("Reconnect stopped download") { bytes() > before }
            val paused = command("pause", version())
            check(paused["state"] == "paused") { "$paused" }
            check((paused["downloadedBytes"] as Number).toLong() > 0)
            check(paused["resumeSupport"] == "supported") { "$paused" }
            val original = queue { AndroidEngineRuntime.journal(context).inspectMaterials(key) }
            evidence("pause returned after worker exit: $paused materials=$original")
            val stopped = bytes()
            Thread.sleep(1200)
            check(bytes() == stopped)
            repeat(3) { inspect() }
            command("resume", version())
            waitFor("206 resume did not advance") { bytes() > stopped }
            val owned = queue { AndroidEngineRuntime.journal(context).inspectMaterials(key) }
            evidence("resume bytes=${bytes()} owned=$owned")
            val cancelled = command("cancel", version())
            check(cancelled["state"] == "cancelling" && cancelled["error"] == null) { "$cancelled" }
            evidence("cancel completed: $cancelled")
            // Exact registered source and all candidate pairs, not a staging-directory scan.
            queue {
                val db = AndroidEngineRuntime.journal(context).readableDatabase
                db
                    .rawQuery(
                        "SELECT payload_path, facts_path FROM materials WHERE engine=? AND generation=?",
                        arrayOf(key.engineId, "0"),
                    ).use {
                        check(it.count == 1) { "Expected the registered original pair" }
                        while (it.moveToNext()) {
                            check(!File(it.getString(0)).exists())
                            check(!File(it.getString(1)).exists())
                        }
                    }
                db
                    .rawQuery(
                        "SELECT candidate FROM recovery_operations WHERE resume_command IN (SELECT command_id FROM worker_authorizations WHERE engine=? AND generation=?)",
                        arrayOf(key.engineId, "0"),
                    ).use {
                        check(it.count == 1) { "Expected the registered resume candidate pair" }
                        while (it.moveToNext()) {
                            val file = File(it.getString(0))
                            check(!file.exists())
                            check(
                                !File(
                                    file.parentFile,
                                    file.nameWithoutExtension + ".facts",
                                ).exists(),
                            )
                        }
                    }
            }
        } finally {
            detach()
        }
    }

    fun revokedBeforePauseCallback() = revokedBeforeCallback("pause")

    fun revokedBeforeCancelCallback() = revokedBeforeCallback("cancel")

    private fun revokedBeforeCallback(method: String) {
        launch()
        val accepted = java.util.concurrent.atomic.AtomicInteger()
        val stopped = java.util.concurrent.atomic.AtomicReference<Map<String, Any?>?>()
        instrumentation.runOnMainSync {
            AndroidEngineRuntime.afterServiceStartAccepted = {
                accepted.incrementAndGet()
                // We are still in the real start request main-looper action. No Service
                // callback can run until the durable stop and token revocation complete.
                stopped.set(command(method, 1))
            }
        }
        try {
            command("enqueue") // A stopped-before-ready enqueue must also deterministically finish.
            instrumentation.waitForIdleSync() // finish the main-thread stop barrier before observing it
            check(accepted.get() == 1) { "actual system start request did not return" }
            val receipt = stopped.get() ?: error("stop barrier did not run")
            check(receipt["state"] == if (method == "pause") "paused" else "cancelling")
            check(receipt["error"] == null)
            check((receipt["downloadedBytes"] as Number).toLong() == 0L)
            check(queue { AndroidEngineRuntime.journal(context).inspectMaterials(key) }.isEmpty())
            instrumentation.waitForIdleSync()
            // Also allow the platform's FGS deadline to expire after callback/stop.
            Thread.sleep(12000)
            val shell = instrumentation.uiAutomation.executeShellCommand("dumpsys activity services com.example.downloader")
            val services = android.os.ParcelFileDescriptor.AutoCloseInputStream(shell).bufferedReader().use { it.readText() }
            check(!services.contains("ServiceRecord{") || !services.contains(".downloader.DownloadService")) { services }
            check(latest()?.get("state") == receipt["state"])
            android.util.Log.i("ServiceRuntimeEvidence", "ACCEPTED_REVOKED_CALLBACK method=$method materials=0 bytes=0")
        } finally {
            instrumentation.runOnMainSync { AndroidEngineRuntime.afterServiceStartAccepted = null }
            detach()
        }
    }

    fun permissionChangedBeforeCallback() {
        launch()
        val permission = android.Manifest.permission.POST_NOTIFICATIONS
        check(context.checkSelfPermission(permission) == android.content.pm.PackageManager.PERMISSION_GRANTED)
        val accepted = java.util.concurrent.atomic.AtomicInteger()
        val revoked = java.util.concurrent.atomic.AtomicBoolean()
        instrumentation.runOnMainSync {
            AndroidEngineRuntime.afterServiceStartAccepted = {
                accepted.incrementAndGet()
                // Android's explicit CTS/local-test API changes the real permission without
                // killing the process. No production policy or permission check is replaced.
                instrumentation.uiAutomation.adoptShellPermissionIdentity()
                try {
                    val manager = context.getSystemService("permission") ?: error("permission service unavailable")
                    manager.javaClass.getMethod(
                        "revokePostNotificationPermissionWithoutKillForTest", String::class.java, Int::class.javaPrimitiveType,
                    ).invoke(manager, context.packageName, android.os.Process.myUserHandle().hashCode())
                } finally {
                    instrumentation.uiAutomation.dropShellPermissionIdentity()
                }
                check(context.checkSelfPermission(permission) == android.content.pm.PackageManager.PERMISSION_DENIED)
                revoked.set(true)
            }
        }
        try {
            var rejected = false
            try {
                command("enqueue")
            } catch (error: java.util.concurrent.ExecutionException) {
                val cause = error.cause as? EngineProtocolException ?: throw error
                check(cause.code == "permissionDenied") { cause.code }
                rejected = true
            }
            instrumentation.waitForIdleSync()
            check(accepted.get() == 1 && revoked.get()) { "real permission barrier was not completed" }
            check(rejected)
            val receipt = latest() ?: error("missing failed SQLite receipt")
            check(receipt["state"] == "failed")
            check((receipt["error"] as Map<*, *>)["code"] == "permissionDenied")
            check((receipt["downloadedBytes"] as Number).toLong() == 0L)
            check(queue { AndroidEngineRuntime.journal(context).inspectMaterials(key) }.isEmpty())
            Thread.sleep(12000)
            android.util.Log.i("ServiceRuntimeEvidence", "ACCEPTED_PERMISSION_REVOKED_CALLBACK failed=permissionDenied materials=0 bytes=0")
        } finally {
            instrumentation.runOnMainSync { AndroidEngineRuntime.afterServiceStartAccepted = null }
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName, permission)
            detach()
        }
    }

    /** Real denied permission + real system FGS request, with no download capability. */
    fun deniedPromotion() {
        launch()
        check(context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_DENIED)
        instrumentation.runOnMainSync {
            context.startForegroundService(Intent(context, DownloadService::class.java).putExtra("token", "invalid-denied"))
        }
        instrumentation.waitForIdleSync()
        Thread.sleep(12000)
        inspect()
        android.util.Log.i("ServiceRuntimeEvidence", "DENIED_SYSTEM_PROMOTION_SURVIVED no-download-token")
        detach()
    }

    fun denied() {
        launch()
        try {
            check(
                context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                    android.content.pm.PackageManager.PERMISSION_GRANTED,
            )
            try {
                command("enqueue")
                error("notification denial accepted")
            } catch (error: java.util.concurrent.ExecutionException) {
                val cause = error.cause
                check(cause is EngineProtocolException && cause.code == "permissionDenied") { "$cause" }
                evidence("permission denied: ${cause.code}/${cause.reason}")
            }
            check(bytes() == 0L)
            val failed = latest() ?: error("Permission failure was not persisted")
            check(failed["state"] == "failed") { "$failed" }
            check((failed["error"] as? Map<*, *>)?.get("code") == "permissionDenied") { "$failed" }
            evidence("persisted permission failure: $failed")
        } finally {
            detach()
        }
    }

    fun seedKill() {
        launch()
        command("enqueue")
        waitFor("kill seed has no bytes") { bytes() >= 16384 }
        File(context.filesDir, "service-runtime-kill-session.txt").writeText(AndroidEngineRuntime.ownerSessionId)
        File(context.filesDir, "service-runtime-kill-engine.txt").writeText(key.engineId)
        evidence("KILL_READY session=${AndroidEngineRuntime.ownerSessionId} receipt=${latest()}")
        // External host force-stops the app while the real Service is active.
        Thread.sleep(55000)
        error("external kill did not arrive")
    }

    fun inspectAfterKill() {
        launch()
        try {
            val old = File(context.filesDir, "service-runtime-kill-session.txt").readText()
            check(old != AndroidEngineRuntime.ownerSessionId)
            val snapshot = inspect()
            val killedEngine = File(context.filesDir, "service-runtime-kill-engine.txt").readText()
            val recovered = snapshot.filter { (it["key"] as? Map<*, *>)?.get("engineId") == killedEngine }
            check(recovered.isNotEmpty()) { "Killed execution was lost" }
            check(recovered.any { (it["downloadedBytes"] as Number).toLong() > 0 })
            check(recovered.none { it["state"] == "completed" })
            repeat(5) {
                inspect()
                Thread.sleep(400)
            }
            evidence("reopened inspect only oldSession=$old newSession=${AndroidEngineRuntime.ownerSessionId} receipts=${snapshot.size}")
        } finally {
            detach()
        }
    }
}

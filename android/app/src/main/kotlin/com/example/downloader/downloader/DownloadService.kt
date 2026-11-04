package com.example.downloader.downloader

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.example.downloader.MainActivity

/** Intents carry only ephemeral capabilities; never commands or persisted scheduling identities. */
class DownloadService : Service() {
    private val instance =
        java.util.UUID
            .randomUUID()
            .toString()

    override fun onCreate() {
        super.onCreate()
        AndroidEngineRuntime.attachService(instance, this)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        val token = intent?.getStringExtra("token")
        try {
            val started =
                AndroidEngineRuntime.lifecycle.foreground(token, instance) {
                    if (Build.VERSION.SDK_INT < 26) throw IllegalStateException("foregroundServiceUnsupported")
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        throw SecurityException("notificationPermissionRequired")
                    }
                    val manager = getSystemService(NotificationManager::class.java)
                    manager.createNotificationChannel(NotificationChannel("downloads", "下载传输", NotificationManager.IMPORTANCE_LOW))
                    val open =
                        PendingIntent.getActivity(
                            this,
                            0,
                            Intent(this, MainActivity::class.java),
                            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                        )
                    val notification =
                        Notification
                            .Builder(this, "downloads")
                            .setSmallIcon(android.R.drawable.stat_sys_download)
                            .setContentTitle("下载服务")
                            .setContentText("正在处理用户发起的下载")
                            .setContentIntent(open)
                            .setOngoing(true)
                            .build()
                    if (Build.VERSION.SDK_INT >= 29) {
                        startForeground(7601, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
                    } else {
                        startForeground(7601, notification)
                    }
                }
            if (!started) AndroidEngineRuntime.lifecycle.stopUnowned(instance) { stopSelf(startId) }
            AndroidEngineRuntime.executor.execute {
                val coordinator = AndroidEngineRuntime.coordinator(applicationContext)
                if (started) {
                    coordinator.serviceReady(token, instance)
                } else if (token != null &&
                    AndroidEngineRuntime.lifecycle.unclaimed(token)
                ) {
                    coordinator.launchFailed(token, IllegalStateException("serviceOwnershipRejected"))
                }
                AndroidEngineRuntime.stopIdle()
            }
        } catch (error: Exception) {
            // The foreground grant was already revoked; do not wait for SQLite to stop an idle instance.
            AndroidEngineRuntime.stopIdle()
            AndroidEngineRuntime.executor.execute {
                if (token != null) AndroidEngineRuntime.coordinator(applicationContext).launchFailed(token, error)
                AndroidEngineRuntime.stopIdle()
            }
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(
        startId: Int,
        fgsType: Int,
    ) {
        // Immediate atomic Stop publication is independent of the SQLite/coordinator queue.
        val owned =
            AndroidEngineRuntime.lifecycle.destroy(instance) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                // All grants for this instance are retired, including later start requests.
                stopSelf()
            }
        AndroidEngineRuntime.executor.execute { AndroidEngineRuntime.coordinator(applicationContext).restrict(owned = owned) }
    }

    override fun onDestroy() {
        val owned = AndroidEngineRuntime.lifecycle.destroy(instance)
        AndroidEngineRuntime.detachService(instance)
        AndroidEngineRuntime.executor.execute { AndroidEngineRuntime.coordinator(applicationContext).restrict(owned = owned) }
        super.onDestroy()
    }
}

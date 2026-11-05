package com.example.downloader

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.example.downloader.downloader.AndroidEngineChannels
import com.example.downloader.downloader.FileStorageChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channels: AndroidEngineChannels? = null
    private var fileStorage: FileStorageChannel? = null
    private var permissions: MethodChannel? = null
    private val notificationRequests = mutableListOf<MethodChannel.Result>()
    private val notificationRequestCode = 7602

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channels = AndroidEngineChannels(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        fileStorage = FileStorageChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        permissions =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "downloader/permissions").also { channel ->
                channel.setMethodCallHandler { call, result ->
                    if (call.method != "requestNotifications") {
                        result.notImplemented()
                    } else if (Build.VERSION.SDK_INT < 33 ||
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
                    ) {
                        result.success(true)
                    } else {
                        notificationRequests.add(result)
                        if (notificationRequests.size == 1) {
                            try {
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationRequestCode)
                            } catch (error: Exception) {
                                finishNotificationRequests(false)
                            }
                        }
                    }
                }
            }
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        if (fileStorage?.onActivityResult(requestCode, resultCode, data) != true) super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notificationRequestCode) {
            finishNotificationRequests(
                Build.VERSION.SDK_INT < 33 ||
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED,
            )
        }
    }

    private fun finishNotificationRequests(granted: Boolean) {
        val pending = notificationRequests.toList()
        notificationRequests.clear()
        pending.forEach { it.success(granted) }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        permissions?.setMethodCallHandler(null)
        permissions = null
        finishNotificationRequests(false)
        fileStorage?.detach()
        fileStorage = null
        channels?.detach()
        channels = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

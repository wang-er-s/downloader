package com.example.downloader

import com.example.downloader.downloader.AndroidEngineChannels
import io.flutter.embedding.android.FlutterActivity
import android.content.Intent
import com.example.downloader.downloader.FileStorageChannel
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var channels: AndroidEngineChannels? = null
    private var fileStorage: FileStorageChannel? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channels = AndroidEngineChannels(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        fileStorage = FileStorageChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (fileStorage?.onActivityResult(requestCode, resultCode, data) != true) super.onActivityResult(requestCode, resultCode, data)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        fileStorage?.detach()
        fileStorage = null
        channels?.detach()
        channels = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

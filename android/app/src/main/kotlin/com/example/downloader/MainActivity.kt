package com.example.downloader

import com.example.downloader.downloader.AndroidEngineChannels
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var channels: AndroidEngineChannels? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channels = AndroidEngineChannels(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channels?.detach()
        channels = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

package io.github.aautonomicc.watchit

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "watchit/downloads"
        )
        channel = ch
        // The 6h dataSync budget ran out (Android 15+): tell Dart to
        // system-pause the queue so nothing errors mid-transfer.
        DownloadForegroundService.onTimeoutCallback = {
            Handler(Looper.getMainLooper()).post {
                channel?.invokeMethod("onTimeout", null)
            }
        }
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "start", "update" -> {
                    val intent = Intent(this, DownloadForegroundService::class.java)
                        .setAction(
                            if (call.method == "start") {
                                DownloadForegroundService.ACTION_START
                            } else {
                                DownloadForegroundService.ACTION_UPDATE
                            }
                        )
                        .putExtra(
                            DownloadForegroundService.EXTRA_TITLE,
                            call.argument<String>("title") ?: "Downloading"
                        )
                        .putExtra(
                            DownloadForegroundService.EXTRA_TEXT,
                            call.argument<String>("text") ?: ""
                        )
                        .putExtra(
                            DownloadForegroundService.EXTRA_PERCENT,
                            call.argument<Int>("percent") ?: -1
                        )
                    try {
                        if (call.method == "start") {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        // Background-start restrictions etc. — downloads
                        // still run while the app is up; just no service.
                        result.success(false)
                    }
                }
                "stop" -> {
                    try {
                        startService(
                            Intent(this, DownloadForegroundService::class.java)
                                .setAction(DownloadForegroundService.ACTION_STOP)
                        )
                    } catch (_: Exception) {
                    }
                    result.success(true)
                }
                "notificationsEnabled" -> result.success(
                    NotificationManagerCompat.from(this).areNotificationsEnabled()
                )
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7001
                        )
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "manufacturer" -> result.success(Build.MANUFACTURER ?: "")
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        DownloadForegroundService.onTimeoutCallback = null
        channel = null
        super.onDestroy()
    }
}

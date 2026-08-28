package io.github.aautonomicc.watchit

import android.Manifest
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        private const val SAVE_DOCUMENT_REQUEST = 7002
    }

    private var channel: MethodChannel? = null

    // In-flight "watchit/export" saveFile call: the dialog's outcome
    // arrives via onActivityResult, so the MethodChannel.Result waits here.
    private var pendingSave: MethodChannel.Result? = null
    private var pendingSavePath: String? = null

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
        // Exit diagnostics: the OS keeps a record of WHY this app's
        // process last died (native crash, ANR, system kill, …) that
        // survives the death itself — the only crash evidence available
        // on a device with no adb access. Dart shows it in Settings.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "watchit/exitinfo"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getExitReasons" -> Thread {
                    val reasons = collectExitReasons()
                    Handler(Looper.getMainLooper()).post {
                        result.success(reasons)
                    }
                }.start()
                else -> result.notImplemented()
            }
        }
        // Export saves: file_selector_android has no save dialog, so Dart
        // hands us a temp file and we stream it into the content URI the
        // system's Create-Document (SAF) dialog returns.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "watchit/export"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFile" -> {
                    if (pendingSave != null) {
                        result.error(
                            "busy", "A save dialog is already open", null
                        )
                        return@setMethodCallHandler
                    }
                    val path = call.argument<String>("path")
                    if (path == null || !File(path).exists()) {
                        result.error("missing", "Nothing to save", null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
                        .addCategory(Intent.CATEGORY_OPENABLE)
                        .setType(
                            call.argument<String>("mimeType")
                                ?: "application/octet-stream"
                        )
                        .putExtra(
                            Intent.EXTRA_TITLE,
                            call.argument<String>("fileName") ?: "export"
                        )
                    pendingSave = result
                    pendingSavePath = path
                    try {
                        startActivityForResult(intent, SAVE_DOCUMENT_REQUEST)
                    } catch (e: Exception) {
                        pendingSave = null
                        pendingSavePath = null
                        result.error(
                            "dialog", "Could not open the save dialog: $e", null
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != SAVE_DOCUMENT_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingSave ?: return
        val path = pendingSavePath
        pendingSave = null
        pendingSavePath = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null || path == null) {
            result.success(null) // dialog cancelled
            return
        }
        // Copy off the main thread — bundles run to ~200MB.
        Thread {
            try {
                // "wt" truncates when the user overwrote an existing file;
                // some providers only accept the default "w" mode.
                val out = try {
                    contentResolver.openOutputStream(uri, "wt")
                } catch (_: Exception) {
                    contentResolver.openOutputStream(uri)
                } ?: throw IllegalStateException("could not open the picked location")
                out.use { o ->
                    File(path).inputStream().use { it.copyTo(o) }
                }
                val name = displayNameOf(uri)
                Handler(Looper.getMainLooper()).post { result.success(name) }
            } catch (e: Exception) {
                Handler(Looper.getMainLooper()).post {
                    result.error("write", "Could not write the file: $e", null)
                }
            }
        }.start()
    }

    private fun collectExitReasons(): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < 30) return emptyList()
        return try {
            val am = getSystemService(ACTIVITY_SERVICE) as ActivityManager
            val javaCrashes = JavaCrashRecorder.crashes(this).toMutableList()
            am.getHistoricalProcessExitReasons(packageName, 0, 8).map {
                mapOf(
                    "timestampMs" to it.timestamp,
                    "reason" to it.reason,
                    "reasonName" to reasonName(it.reason),
                    "status" to it.status,
                    "importance" to it.importance,
                    "description" to (it.description ?: ""),
                    "trace" to (readTrace(it).ifEmpty {
                        javaTraceFor(it, javaCrashes)
                    }),
                )
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    // The OS attaches no trace to a Java crash (REASON_CRASH), but our
    // uncaught-exception handler (WatchItApplication) saved the stack
    // moments before this death was recorded — match by timestamp.
    private fun javaTraceFor(
        info: ApplicationExitInfo,
        saved: MutableList<Pair<Long, String>>,
    ): String {
        if (info.reason != ApplicationExitInfo.REASON_CRASH) return ""
        val match = saved.minByOrNull { Math.abs(it.first - info.timestamp) }
            ?.takeIf { Math.abs(it.first - info.timestamp) < 60_000 }
            ?: return ""
        saved.remove(match)
        return match.second
    }

    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_EXIT_SELF -> "exit-self"
        ApplicationExitInfo.REASON_SIGNALED -> "signaled"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "low-memory"
        ApplicationExitInfo.REASON_CRASH -> "crash (java)"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "crash (native)"
        ApplicationExitInfo.REASON_ANR -> "anr"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "init-failure"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "permission-change"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE ->
            "excessive-resource-usage"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "user-requested"
        ApplicationExitInfo.REASON_USER_STOPPED -> "user-stopped"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "dependency-died"
        ApplicationExitInfo.REASON_FREEZER -> "freezer"
        ApplicationExitInfo.REASON_OTHER -> "other (system)"
        else -> "unknown-$reason"
    }

    // Tombstone-style trace, only recorded for native crashes and ANRs.
    // Capped: the full tombstone can run to hundreds of KB and the top
    // is where the signal + faulting library live.
    private fun readTrace(info: ApplicationExitInfo): String {
        if (info.reason != ApplicationExitInfo.REASON_CRASH_NATIVE &&
            info.reason != ApplicationExitInfo.REASON_ANR
        ) return ""
        return try {
            info.traceInputStream?.bufferedReader()?.use { reader ->
                val buf = CharArray(64 * 1024)
                val n = reader.read(buf)
                if (n <= 0) "" else String(buf, 0, n)
            } ?: ""
        } catch (_: Exception) {
            ""
        }
    }

    private fun displayNameOf(uri: Uri): String =
        contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
        )?.use { if (it.moveToFirst()) it.getString(0) else null }
            ?: uri.lastPathSegment ?: "file"

    override fun onDestroy() {
        DownloadForegroundService.onTimeoutCallback = null
        channel = null
        super.onDestroy()
    }
}

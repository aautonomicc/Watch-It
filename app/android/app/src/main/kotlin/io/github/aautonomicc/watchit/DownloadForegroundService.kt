package io.github.aautonomicc.watchit

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Keeps download transfers alive while the app is backgrounded.
 *
 * Android 12+ freezes cached app processes (Dart *and* the embedded Rust
 * client's tokio threads) and Doze cuts their network; the sanctioned way
 * to keep long transfers running on Pixel/Samsung is a dataSync
 * foreground service with an ongoing notification. The Dart download
 * pump stays where it is — this service only holds the process
 * unfreezable (partial wakelock + Wi-Fi lock) and shows progress.
 *
 * Driven over the "watchit/downloads" MethodChannel from MainActivity:
 * start when the queue goes active, ~1/s progress updates, stop when it
 * drains. On the Android 15+ dataSync 6h/day budget running out,
 * [onTimeout] tells Dart to system-pause the queue and swaps the
 * notification for "reopen to continue" (resume-from-byte loses nothing).
 */
class DownloadForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "downloads"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "io.github.aautonomicc.watchit.DOWNLOADS_START"
        const val ACTION_UPDATE = "io.github.aautonomicc.watchit.DOWNLOADS_UPDATE"
        const val ACTION_STOP = "io.github.aautonomicc.watchit.DOWNLOADS_STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PERCENT = "percent" // -1 = indeterminate

        /** Set by MainActivity so the 6h dataSync timeout reaches Dart. */
        @Volatile
        var onTimeoutCallback: (() -> Unit)? = null
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                releaseLocks()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            ACTION_UPDATE -> {
                val manager =
                    getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.notify(NOTIFICATION_ID, buildNotification(intent))
            }
            else -> { // ACTION_START (or a restart)
                createChannel()
                startForeground(NOTIFICATION_ID, buildNotification(intent))
                acquireLocks()
            }
        }
        return START_NOT_STICKY
    }

    /** Android 15+: the dataSync time budget (6h/day) ran out. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        onTimeoutCallback?.invoke()
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(
            NOTIFICATION_ID + 1,
            baseBuilder()
                .setContentTitle("Downloads paused")
                .setContentText("Android's background time ran out — reopen W@tch to continue.")
                .setOngoing(false)
                .setAutoCancel(true)
                .build()
        )
        releaseLocks()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "watchit:downloads"
            ).apply { acquire() }
        }
        if (wifiLock == null) {
            val wm = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= 29) {
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            } else {
                WifiManager.WIFI_MODE_FULL
            }
            wifiLock = wm.createWifiLock(mode, "watchit:downloads")
                .apply { acquire() }
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }

    private fun createChannel() {
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Progress while downloads run in the background"
                setShowBadge(false)
            }
        )
    }

    private fun baseBuilder(): NotificationCompat.Builder {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(open)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
    }

    private fun buildNotification(intent: Intent?): Notification {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Downloading"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val percent = intent?.getIntExtra(EXTRA_PERCENT, -1) ?: -1
        return baseBuilder()
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, percent.coerceIn(0, 100), percent < 0)
            .build()
    }
}

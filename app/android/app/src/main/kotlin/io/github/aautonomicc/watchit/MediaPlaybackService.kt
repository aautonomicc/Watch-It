package io.github.aautonomicc.watchit

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import java.io.File

/**
 * Keeps music playing while the screen is off and shows media controls +
 * track info in the notification shade and on the lock screen.
 *
 * Android 12+ freezes cached app processes (mpv *and* the embedded Rust
 * client's tokio threads) and Doze cuts their network — the sanctioned
 * fix for audio is a mediaPlayback foreground service (no time budget,
 * unlike the downloads service's dataSync class) with an attached
 * MediaSession. The player itself stays 100% in Dart/mpv: this service
 * only mirrors state and relays button/focus events back over the
 * "watchit/media_session" MethodChannel via [onEvent].
 *
 * Lifecycle: started when audio playback starts; on pause the service
 * leaves the foreground but the (now dismissible) notification stays;
 * dismissed-while-paused or an explicit stop tears it down.
 */
class MediaPlaybackService : Service() {

    companion object {
        const val CHANNEL_ID = "playback"
        const val NOTIFICATION_ID = 1101
        const val ACTION_START = "io.github.aautonomicc.watchit.MEDIA_START"
        const val ACTION_UPDATE = "io.github.aautonomicc.watchit.MEDIA_UPDATE"
        const val ACTION_STOP = "io.github.aautonomicc.watchit.MEDIA_STOP"
        const val ACTION_BTN_PLAY_PAUSE =
            "io.github.aautonomicc.watchit.MEDIA_BTN_PLAY_PAUSE"
        const val ACTION_BTN_NEXT = "io.github.aautonomicc.watchit.MEDIA_BTN_NEXT"
        const val ACTION_BTN_PREV = "io.github.aautonomicc.watchit.MEDIA_BTN_PREV"
        const val ACTION_DISMISSED =
            "io.github.aautonomicc.watchit.MEDIA_DISMISSED"
        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        const val EXTRA_ALBUM = "album"
        const val EXTRA_ART = "artworkPath"
        const val EXTRA_PLAYING = "playing"
        const val EXTRA_POSITION = "positionMs"
        const val EXTRA_DURATION = "durationMs"
        const val EXTRA_CAN_NEXT = "canNext"
        const val EXTRA_CAN_PREV = "canPrev"

        /**
         * Set by MainActivity: relays "play"/"pause"/"next"/"previous"/
         * "seek" (with position ms)/"stop" back to Dart.
         */
        @Volatile
        var onEvent: ((String, Long) -> Unit)? = null
    }

    private var session: MediaSessionCompat? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var focusRequest: AudioFocusRequest? = null
    private var hasFocus = false
    private var resumeOnFocusGain = false
    private var noisyRegistered = false
    private var startedForeground = false

    private var title = ""
    private var artist = ""
    private var album = ""
    private var playing = false
    private var positionMs = 0L
    private var durationMs = 0L
    private var canNext = false
    private var canPrev = false
    private var artPath = ""
    private var artBitmap: Bitmap? = null

    override fun onBind(intent: Intent?): IBinder? = null

    // Headphones unplugged / Bluetooth gone: keep the music from blaring
    // out of the speaker.
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                onEvent?.invoke("pause", 0)
            }
        }
    }

    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                resumeOnFocusGain = false
                onEvent?.invoke("pause", 0)
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // Phone call etc. — pause now, resume when it ends.
                resumeOnFocusGain = playing
                onEvent?.invoke("pause", 0)
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (resumeOnFocusGain) {
                    resumeOnFocusGain = false
                    onEvent?.invoke("play", 0)
                }
            }
            // CAN_DUCK: keep playing (notification beeps over the music).
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> teardown()
            ACTION_BTN_PLAY_PAUSE ->
                onEvent?.invoke(if (playing) "pause" else "play", 0)
            ACTION_BTN_NEXT -> onEvent?.invoke("next", 0)
            ACTION_BTN_PREV -> onEvent?.invoke("previous", 0)
            ACTION_DISMISSED -> {
                // Swiped away while paused: the session is over.
                onEvent?.invoke("stop", 0)
                teardown()
            }
            else -> apply(intent) // ACTION_START / ACTION_UPDATE
        }
        return START_NOT_STICKY
    }

    /** Mirror the state the Dart side sent into session + notification. */
    private fun apply(intent: Intent?) {
        if (intent == null) return
        title = intent.getStringExtra(EXTRA_TITLE) ?: title
        artist = intent.getStringExtra(EXTRA_ARTIST) ?: artist
        album = intent.getStringExtra(EXTRA_ALBUM) ?: album
        playing = intent.getBooleanExtra(EXTRA_PLAYING, playing)
        positionMs = intent.getLongExtra(EXTRA_POSITION, positionMs)
        durationMs = intent.getLongExtra(EXTRA_DURATION, durationMs)
        canNext = intent.getBooleanExtra(EXTRA_CAN_NEXT, canNext)
        canPrev = intent.getBooleanExtra(EXTRA_CAN_PREV, canPrev)
        val newArt = intent.getStringExtra(EXTRA_ART) ?: ""
        if (newArt != artPath) {
            artPath = newArt
            artBitmap = decodeArt(newArt)
        }

        createChannel()
        val s = ensureSession()
        s.setMetadata(
            MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
                .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, album)
                .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, durationMs)
                .apply {
                    artBitmap?.let {
                        putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, it)
                    }
                }
                .build()
        )
        var actions = PlaybackStateCompat.ACTION_PLAY or
            PlaybackStateCompat.ACTION_PAUSE or
            PlaybackStateCompat.ACTION_PLAY_PAUSE or
            PlaybackStateCompat.ACTION_SEEK_TO or
            PlaybackStateCompat.ACTION_STOP
        if (canNext) actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_NEXT
        if (canPrev) {
            actions = actions or PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
        }
        s.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(actions)
                .setState(
                    if (playing) {
                        PlaybackStateCompat.STATE_PLAYING
                    } else {
                        PlaybackStateCompat.STATE_PAUSED
                    },
                    positionMs,
                    if (playing) 1f else 0f
                )
                .build()
        )
        s.isActive = true

        if (playing) {
            requestFocus()
            registerNoisy()
            acquireLocks()
            startForeground(NOTIFICATION_ID, buildNotification())
            startedForeground = true
        } else {
            // Paused: the process may sleep again, but the notification
            // stays (dismissible) so the user can resume from the shade.
            unregisterNoisy()
            releaseLocks()
            if (startedForeground) {
                stopForeground(STOP_FOREGROUND_DETACH)
                startedForeground = false
            }
            val manager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, buildNotification())
        }
    }

    private fun ensureSession(): MediaSessionCompat {
        session?.let { return it }
        val s = MediaSessionCompat(this, "watchit-playback")
        s.setCallback(object : MediaSessionCompat.Callback() {
            override fun onPlay() {
                onEvent?.invoke("play", 0)
            }

            override fun onPause() {
                onEvent?.invoke("pause", 0)
            }

            override fun onSkipToNext() {
                onEvent?.invoke("next", 0)
            }

            override fun onSkipToPrevious() {
                onEvent?.invoke("previous", 0)
            }

            override fun onSeekTo(pos: Long) {
                onEvent?.invoke("seek", pos)
            }

            override fun onStop() {
                onEvent?.invoke("pause", 0)
            }
        })
        session = s
        return s
    }

    private fun requestFocus() {
        if (hasFocus) return
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val granted = if (Build.VERSION.SDK_INT >= 26) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            focusRequest = request
            am.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
        }
        hasFocus = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonFocus() {
        if (!hasFocus) return
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= 26) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(focusListener)
        }
        hasFocus = false
    }

    private fun registerNoisy() {
        if (noisyRegistered) return
        registerReceiver(
            noisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        )
        noisyRegistered = true
    }

    private fun unregisterNoisy() {
        if (!noisyRegistered) return
        try {
            unregisterReceiver(noisyReceiver)
        } catch (_: Exception) {
        }
        noisyRegistered = false
    }

    // Streaming tracks need the embedded client's sockets alive with the
    // screen off — the same locks the download service holds.
    private fun acquireLocks() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "watchit:playback"
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
            wifiLock = wm.createWifiLock(mode, "watchit:playback")
                .apply { acquire() }
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }

    private fun teardown() {
        unregisterNoisy()
        releaseLocks()
        abandonFocus()
        session?.isActive = false
        session?.release()
        session = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        startedForeground = false
        stopSelf()
    }

    override fun onDestroy() {
        unregisterNoisy()
        releaseLocks()
        abandonFocus()
        session?.release()
        session = null
        super.onDestroy()
    }

    /** Cover art, downsampled — posters are small but lock screens only
     * need ~512px. */
    private fun decodeArt(path: String): Bitmap? {
        if (path.isEmpty() || !File(path).exists()) return null
        return try {
            val bounds = BitmapFactory.Options().apply {
                inJustDecodeBounds = true
            }
            BitmapFactory.decodeFile(path, bounds)
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= 512 &&
                bounds.outHeight / (sample * 2) >= 512
            ) {
                sample *= 2
            }
            BitmapFactory.decodeFile(
                path,
                BitmapFactory.Options().apply { inSampleSize = sample }
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun createChannel() {
        val manager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID, "Playback", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Media controls while music plays"
                setShowBadge(false)
            }
        )
    }

    private fun servicePending(action: String, code: Int): PendingIntent =
        PendingIntent.getService(
            this, code,
            Intent(this, MediaPlaybackService::class.java).setAction(action),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(open)
            .setContentTitle(title)
            .setContentText(
                listOf(artist, album).filter { it.isNotEmpty() }
                    .joinToString(" · ")
            )
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(playing)
            .setOnlyAlertOnce(true)
            .setDeleteIntent(servicePending(ACTION_DISMISSED, 4))
        artBitmap?.let { builder.setLargeIcon(it) }
        val compact = mutableListOf<Int>()
        var index = 0
        if (canPrev) {
            builder.addAction(
                android.R.drawable.ic_media_previous, "Previous",
                servicePending(ACTION_BTN_PREV, 1)
            )
            compact.add(index++)
        }
        builder.addAction(
            if (playing) {
                android.R.drawable.ic_media_pause
            } else {
                android.R.drawable.ic_media_play
            },
            if (playing) "Pause" else "Play",
            servicePending(ACTION_BTN_PLAY_PAUSE, 2)
        )
        compact.add(index++)
        if (canNext) {
            builder.addAction(
                android.R.drawable.ic_media_next, "Next",
                servicePending(ACTION_BTN_NEXT, 3)
            )
            compact.add(index++)
        }
        builder.setStyle(
            androidx.media.app.NotificationCompat.MediaStyle()
                .setMediaSession(session?.sessionToken)
                .setShowActionsInCompactView(*compact.toIntArray())
        )
        return builder.build()
    }
}

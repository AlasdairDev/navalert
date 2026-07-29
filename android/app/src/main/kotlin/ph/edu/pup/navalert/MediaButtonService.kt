package ph.edu.pup.navalert

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock

/**
 * Discreet emergency triggering (R7 / R8, Specific Objective 4).
 *
 * The volume-key shortcuts must fire when the phone is locked and in a pocket
 * — screen off. A plain Activity `dispatchKeyEvent` only sees keys while it has
 * window focus, so it is dead in that state. An active [MediaSession] with a
 * **remote** [VolumeProvider] does receive VOLUME_UP / VOLUME_DOWN even with
 * the screen off (verified on hardware), because volume keys are handled in
 * PhoneWindowManager.interceptKeyBeforeQueueing, which runs while asleep and
 * routes them to the active session's remote volume.
 *
 * This service owns that session and does the triple-press detection natively,
 * so timing works regardless of whether the Flutter engine is currently alive.
 * Each detected shortcut is handed to the app:
 *  - SOS: delivered silently to the running engine if one is attached (no
 *    screen wake — the whole point is discretion); otherwise the activity is
 *    launched to perform it.
 *  - Fake call: always launches the activity, which shows over the lockscreen.
 *
 * Because the remote VolumeProvider intercepts the keys, every press is relayed
 * back to the real audio stream so the phone's volume still works normally.
 *
 * **Keeping priority while other media plays (the Spotify problem).** Volume
 * keys are routed to the highest-priority session that declares REMOTE volume
 * control — Android's `MediaSessionStack.getDefaultVolumeSession()` only
 * considers remote-volume sessions. Music apps (Spotify, YouTube) play LOCAL
 * audio, so they are never candidates for that slot and cannot take the keys —
 * *provided our session stays active and non-stale*. Two things guarantee that:
 *  - a silent, zero-volume keep-alive track so the session is genuinely,
 *    continuously "playing" (it requests no audio focus, so it never pauses or
 *    ducks the user's music);
 *  - a periodic re-assertion of the PLAYING state so the session never ages out
 *    of the priority stack when another app becomes active.
 */
class MediaButtonService : Service() {

    private lateinit var session: MediaSession
    private lateinit var audio: AudioManager
    private val main = Handler(Looper.getMainLooper())

    // MediaSession callbacks (including the VolumeProvider) run on the handler
    // given to setCallback. Keeping them off the main thread is essential: the
    // main thread also runs the Flutter engine, and a burst of volume events
    // relaying to the audio stream on it can jank the UI or ANR. Only the final
    // dispatch to Dart / notifications hops back to main.
    private val bgThread = HandlerThread("navalert-mediabtn").apply { start() }
    private val bg = Handler(bgThread.looper)

    private val upPresses = ArrayDeque<Long>()
    private val downPresses = ArrayDeque<Long>()
    private var lastDispatchAt = 0L

    private var keepAlive: AudioTrack? = null
    private val reassert = object : Runnable {
        override fun run() {
            assertPlaying()
            main.postDelayed(this, REASSERT_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        startForegroundNotification()

        session = MediaSession(this, "NavAlertShortcuts").apply {
            setPlaybackToRemote(volumeProvider())
            // A callback is required for the framework to treat the session as
            // controllable and route media/volume keys to it. The transport
            // callbacks are intentional no-ops — we only care about volume. The
            // background handler moves onAdjustVolume off the main thread.
            setCallback(object : MediaSession.Callback() {}, bg)
            isActive = true
        }
        assertPlaying()
        startKeepAlive()
        main.postDelayed(reassert, REASSERT_MS)
    }

    /**
     * Yields (pauses) or restores the silent keep-alive track. The keep-alive
     * holds the media audio path to keep the volume-shortcut session's
     * priority; while an alarm or the fake-call ringtone plays, it must step
     * aside or it suppresses that sound. Called from Dart (SoundService) at the
     * start/end of every alarm and ringtone.
     */
    fun setAudioYield(yield: Boolean) = bg.post {
        try {
            if (yield) keepAlive?.pause() else keepAlive?.play()
        } catch (_: Exception) {
        }
    }

    /** (Re)declare the session as actively playing to hold volume priority. */
    private fun assertPlaying() {
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY_PAUSE)
                .setState(PlaybackState.STATE_PLAYING, 0L, 1.0f)
                .build()
        )
        if (!session.isActive) session.isActive = true
    }

    /**
     * A silent, looped track that keeps the session genuinely "playing" so it
     * is never culled from the priority stack. USAGE_MEDIA at zero volume with
     * NO audio-focus request — it mixes silently alongside the user's music and
     * never interrupts it.
     */
    private fun startKeepAlive() {
        try {
            val rate = 8000
            val frames = rate // one second of silence
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(rate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(frames * 2)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .build()
            track.write(ShortArray(frames), 0, frames) // zeros = silence
            track.setLoopPoints(0, frames, -1)          // loop forever in hw
            track.setVolume(0f)
            track.play()
            keepAlive = track
        } catch (_: Exception) {
            // No audio hardware / unsupported format — the periodic re-assert
            // still keeps the session reasonably fresh on its own.
        }
    }

    /** The remote volume target: it both relays volume and detects triple-press. */
    private fun volumeProvider(): VolumeProvider {
        val musicMax = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val start = if (musicMax > 0)
            audio.getStreamVolume(AudioManager.STREAM_MUSIC) * 100 / musicMax
        else 50

        return object : VolumeProvider(VOLUME_CONTROL_RELATIVE, 100, start) {
            override fun onAdjustVolume(direction: Int) {
                if (direction == 0) return // key release — ignore

                // Relay to the real stream so volume still changes for the
                // user. Guarded: a failure here must not swallow the press.
                try {
                    audio.adjustSuggestedStreamVolume(
                        if (direction > 0) AudioManager.ADJUST_RAISE
                        else AudioManager.ADJUST_LOWER,
                        AudioManager.USE_DEFAULT_STREAM_TYPE,
                        AudioManager.FLAG_SHOW_UI
                    )
                } catch (_: Exception) {
                }
                // Mirror the real music level back so the slider tracks reality.
                if (musicMax > 0) {
                    currentVolume =
                        audio.getStreamVolume(AudioManager.STREAM_MUSIC) * 100 / musicMax
                }

                // Bug fix (ghost triggers): only treat volume presses as the
                // emergency shortcut when the rider CAN'T just use the in-app
                // buttons — i.e. the screen is off, OR NavAlert is not in the
                // foreground. While the app is open with the screen on (e.g.
                // previewing an alarm sound in Settings), normal volume
                // adjustments must NOT be read as a triple-press shortcut.
                if (isShortcutContext()) detectTriplePress(direction)
            }
        }
    }

    private fun isShortcutContext(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        val screenOn = pm.isInteractive
        return !screenOn || !MainActivity.activityResumed
    }

    /** Native triple-press within [WINDOW_MS], per direction. */
    private fun detectTriplePress(direction: Int) {
        val now = SystemClock.elapsedRealtime()
        val list = if (direction > 0) upPresses else downPresses
        list.addLast(now)
        while (list.isNotEmpty() && now - list.first() > WINDOW_MS) list.removeFirst()
        if (list.size >= 3) {
            list.clear()
            // Cooldown: a burst of presses (or a held key) must not fire twice
            // — a double SOS would send duplicate SMS to every contact, and a
            // double fake call would stack two call screens.
            val now = SystemClock.elapsedRealtime()
            if (now - lastDispatchAt < COOLDOWN_MS) return
            lastDispatchAt = now
            // Clear the other direction too, so a mixed burst can't chain.
            upPresses.clear()
            downPresses.clear()
            dispatchShortcut(if (direction > 0) "sos" else "fakecall")
        }
    }

    private fun dispatchShortcut(type: String) = main.post {
        val channel = MainActivity.keysChannel
        val engineAlive = MainActivity.engineAlive && channel != null

        when (type) {
            // SOS: a live engine handles it silently in the background — no
            // screen wake, the whole point of discretion. SMS/GPS run headless.
            "sos" -> if (engineAlive) {
                channel!!.invokeMethod("shortcut", "sos")
                return@post
            }
            // Fake call: deliver directly only if the app is already visible;
            // otherwise it must come to the foreground, which needs the
            // full-screen intent below.
            "fakecall" -> if (engineAlive && MainActivity.activityResumed) {
                channel!!.invokeMethod("shortcut", "fakecall")
                return@post
            }
        }

        // Background/screen-off, or the engine is gone: a plain startActivity
        // from a background service is blocked by Android's BAL policy, so use
        // a full-screen-intent notification instead — the sanctioned path that
        // launches the activity over the lockscreen (same as an incoming call).
        launchViaFullScreenIntent(type)
    }

    private fun launchViaFullScreenIntent(type: String) {
        val activity = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_SHORTCUT, type)
        }
        val pi = PendingIntent.getActivity(
            this, type.hashCode(), activity,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notif = Notification.Builder(this, FS_CHANNEL)
            .setContentTitle(if (type == "sos") "Sending SOS…" else "Incoming call")
            .setContentText(
                if (type == "sos") "Alerting your emergency contacts."
                else "Tap to answer."
            )
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setCategory(Notification.CATEGORY_CALL)
            // Screen off/locked: the full-screen intent auto-launches over the
            // keyguard. Screen on: it shows as a heads-up, and tapping fires
            // the CONTENT intent — so both must point at the same activity.
            .setContentIntent(pi)
            .setFullScreenIntent(pi, true)
            .setAutoCancel(true)
            .setOngoing(false)
            .build()
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(FS_NOTIF_ID, notif)
    }

    private fun startForegroundNotification() {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL, "Safety shortcuts", NotificationManager.IMPORTANCE_LOW
                ).apply { description = "Keeps the volume-button SOS shortcut active." }
            )
            // High importance so the full-screen intent actually fires when a
            // shortcut is triggered with the screen off.
            mgr.createNotificationChannel(
                NotificationChannel(
                    FS_CHANNEL, "Emergency trigger", NotificationManager.IMPORTANCE_HIGH
                ).apply { description = "Launches SOS / fake call from the volume shortcut." }
            )
        }
        val notif: Notification = Notification.Builder(this, CHANNEL)
            .setContentTitle("NavAlert safety shortcuts active")
            .setContentText("Volume-Up ×3 for SOS · Volume-Down ×3 for a fake call")
            .setSmallIcon(android.R.drawable.ic_menu_call)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
    }

    // DO NOT MODIFY LOGIC: START_STICKY fulfils UC-1 Exception 1 (Background
    // Service Terminated) — if Android kills this foreground service under
    // memory/battery pressure, the OS best-effort re-creates it (null intent)
    // so the screen-off volume-shortcut capture (SOS / fake call) is restored
    // without the rider reopening the app. Do not return START_NOT_STICKY.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_STICKY

    override fun onDestroy() {
        instance = null
        main.removeCallbacks(reassert)
        bgThread.quitSafely()
        try {
            keepAlive?.stop()
            keepAlive?.release()
        } catch (_: Exception) {
        }
        keepAlive = null
        session.isActive = false
        session.release()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        /** Live instance, so Dart (via MainActivity) can ask it to yield audio. */
        @JvmStatic
        @Volatile
        var instance: MediaButtonService? = null

        const val EXTRA_SHORTCUT = "navalert_shortcut"
        private const val CHANNEL = "navalert_shortcuts"
        private const val FS_CHANNEL = "navalert_trigger"
        private const val NOTIF_ID = 4242
        private const val FS_NOTIF_ID = 4243
        private const val WINDOW_MS = 1600L
        private const val COOLDOWN_MS = 3000L
        private const val REASSERT_MS = 20_000L
    }
}

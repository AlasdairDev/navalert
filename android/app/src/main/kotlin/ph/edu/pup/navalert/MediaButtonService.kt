package ph.edu.pup.navalert

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
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
 */
class MediaButtonService : Service() {

    private lateinit var session: MediaSession
    private lateinit var audio: AudioManager
    private val main = Handler(Looper.getMainLooper())

    private val upPresses = ArrayDeque<Long>()
    private val downPresses = ArrayDeque<Long>()
    private var lastDispatchAt = 0L

    override fun onCreate() {
        super.onCreate()
        audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        startForegroundNotification()

        session = MediaSession(this, "NavAlertShortcuts").apply {
            // A PLAYING state earns the session media-button/volume priority.
            setPlaybackState(
                PlaybackState.Builder()
                    .setActions(PlaybackState.ACTION_PLAY_PAUSE)
                    .setState(PlaybackState.STATE_PLAYING, 0L, 1.0f)
                    .build()
            )
            setPlaybackToRemote(volumeProvider())
            // A callback is required for the framework to treat the session as
            // controllable and route media/volume keys to it. The transport
            // callbacks are intentional no-ops — we only care about volume.
            setCallback(object : MediaSession.Callback() {})
            isActive = true
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

                detectTriplePress(direction)
            }
        }
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
        val engineAlive = MainActivity.engineAlive

        // SOS with a live engine goes straight to Dart — silent, no screen wake.
        if (type == "sos" && engineAlive && channel != null) {
            channel.invokeMethod("shortcut", type)
            return@post
        }

        // Otherwise launch the activity to guarantee execution. singleTop +
        // showWhenLocked means a fake call surfaces over the keyguard.
        startActivity(
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(EXTRA_SHORTCUT, type)
            }
        )
    }

    private fun startForegroundNotification() {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL, "Safety shortcuts", NotificationManager.IMPORTANCE_LOW
                ).apply { description = "Keeps the volume-button SOS shortcut active." }
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

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_STICKY

    override fun onDestroy() {
        session.isActive = false
        session.release()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val EXTRA_SHORTCUT = "navalert_shortcut"
        private const val CHANNEL = "navalert_shortcuts"
        private const val NOTIF_ID = 4242
        private const val WINDOW_MS = 1600L
        private const val COOLDOWN_MS = 3000L
    }
}

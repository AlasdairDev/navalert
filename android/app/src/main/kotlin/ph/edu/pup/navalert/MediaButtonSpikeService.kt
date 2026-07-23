package ph.edu.pup.navalert

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.KeyEvent

/**
 * SPIKE ONLY — throwaway harness to answer ONE question empirically:
 * are hardware VOLUME keys delivered to an active MediaSession when the
 * screen is completely off and the device is locked?
 *
 * All logs use the tag "NAVSPIKE". Nothing here is wired into the app's real
 * behaviour; it only logs. Delete this file, its manifest entry, and the
 * start call in MainActivity once the question is answered.
 *
 * Mechanism under test:
 *  - A MediaSession marked ACTIVE with a PLAYING PlaybackState (so the
 *    framework treats it as the priority media target).
 *  - setPlaybackToRemote(VolumeProvider): this is the ONLY documented way a
 *    session sees VOLUME_UP / VOLUME_DOWN. With local playback the keys go to
 *    the audio stream and the session never sees them; with a remote volume
 *    provider the framework calls onAdjustVolume(direction) instead.
 *  - onMediaButtonEvent + a media-button receiver cover the media-button
 *    fallback (headset / bluetooth click) in case volume keys are blocked.
 *
 * Hosted in a foreground service so the session keeps priority while the app
 * is backgrounded — the exact condition (phone in pocket) we care about.
 */
class MediaButtonSpikeService : Service() {

    private lateinit var session: MediaSession

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "service onCreate — starting media session spike")

        startForegroundNotification()

        session = MediaSession(this, "NavAlertSpike").apply {
            // A PLAYING state is what earns the session media-button priority.
            setPlaybackState(
                PlaybackState.Builder()
                    .setActions(
                        PlaybackState.ACTION_PLAY_PAUSE or
                            PlaybackState.ACTION_PLAY or
                            PlaybackState.ACTION_PAUSE
                    )
                    .setState(PlaybackState.STATE_PLAYING, 0L, 1.0f)
                    .build()
            )

            // Remote volume — the volume-key interception path under test.
            setPlaybackToRemote(object : VolumeProvider(
                VOLUME_CONTROL_RELATIVE, /* maxVolume = */ 100, /* currentVolume = */ 50
            ) {
                override fun onAdjustVolume(direction: Int) {
                    // direction: +1 = VOLUME_UP, -1 = VOLUME_DOWN, 0 = release.
                    Log.i(
                        TAG,
                        "VOLUME KEY via VolumeProvider.onAdjustVolume dir=$direction " +
                            "screenOn=${isScreenOn()} @${System.currentTimeMillis()}"
                    )
                }

                override fun onSetVolumeTo(volume: Int) {
                    Log.i(TAG, "VolumeProvider.onSetVolumeTo $volume")
                }
            })

            setCallback(object : MediaSession.Callback() {
                override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                    val ke: KeyEvent? =
                        mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
                    Log.i(
                        TAG,
                        "MEDIA BUTTON via onMediaButtonEvent key=${ke?.keyCode} " +
                            "action=${ke?.action} screenOn=${isScreenOn()}"
                    )
                    return super.onMediaButtonEvent(mediaButtonIntent)
                }
            })

            isActive = true
        }

        Log.i(TAG, "session active — press VOLUME keys now, with the screen OFF")
    }

    // Media buttons routed as ACTION_MEDIA_BUTTON also arrive here when the
    // session receiver forwards them to the service.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == Intent.ACTION_MEDIA_BUTTON) {
            val ke: KeyEvent? = intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT)
            Log.i(TAG, "MEDIA BUTTON via onStartCommand key=${ke?.keyCode}")
        }
        return START_STICKY
    }

    private fun startForegroundNotification() {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL, "NavAlert spike", NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        val notif: Notification = Notification.Builder(this, CHANNEL)
            .setContentTitle("NavAlert media-button spike")
            .setContentText("Testing volume-key delivery")
            .setSmallIcon(android.R.drawable.ic_media_play)
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

    private fun isScreenOn(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        return pm.isInteractive
    }

    override fun onDestroy() {
        session.isActive = false
        session.release()
        Log.i(TAG, "service destroyed, session released")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val TAG = "NAVSPIKE"
        private const val CHANNEL = "navalert_spike"
        private const val NOTIF_ID = 4242
    }
}

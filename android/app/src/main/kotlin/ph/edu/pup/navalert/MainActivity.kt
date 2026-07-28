package ph.edu.pup.navalert

import android.content.Intent
import android.os.Build
import android.telephony.SmsManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * NavAlert native bridge.
 *
 * 1. navalert/sms  — sends the SOS message through Native Android SMS
 *    (SmsManager), so the alert works with cellular signal only (R8).
 * 2. navalert/keys — carries the triple-Volume shortcuts (SOS / fake call).
 *    Detection happens natively in [MediaButtonService] so it works with the
 *    screen off; this channel only delivers the decoded high-level event, and
 *    a cold-launched app pulls any pending one via "consumePendingShortcut".
 * 3. navalert/lockscreen — lets the fake call render on top of the
 *    keyguard (UC-8 Exception 2), the way a real dialer shows an
 *    incoming call.
 */
class MainActivity : FlutterActivity() {

    companion object {
        /**
         * Live handle the background [MediaButtonService] uses to deliver a
         * shortcut straight to Dart when the engine is attached. Null while no
         * engine exists, so the service falls back to launching the activity.
         */
        @JvmStatic
        var keysChannel: MethodChannel? = null

        @JvmStatic
        var engineAlive: Boolean = false

        /** A shortcut that arrived before Dart was ready to receive it. */
        @JvmStatic
        var pendingShortcut: String? = null

        /**
         * True while the activity is in the foreground. Lets the service decide
         * whether a fake call can be delivered directly (app visible) or needs a
         * full-screen intent to surface it (app backgrounded / screen off).
         */
        @JvmStatic
        var activityResumed: Boolean = false
    }

    override fun onResume() {
        super.onResume()
        activityResumed = true
    }

    override fun onPause() {
        activityResumed = false
        super.onPause()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Keep the always-on shortcut capture service running.
        val svc = Intent(this, MediaButtonService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(svc)
        } else {
            startService(svc)
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "navalert/sms")
            .setMethodCallHandler { call, result ->
                if (call.method == "sendSms") {
                    val phone = call.argument<String>("phone")
                    val message = call.argument<String>("message")
                    if (phone.isNullOrBlank() || message.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        @Suppress("DEPRECATION")
                        val sms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                            getSystemService(SmsManager::class.java)
                        else
                            SmsManager.getDefault()
                        val parts = sms.divideMessage(message)
                        sms.sendMultipartTextMessage(phone, null, parts, null, null)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                } else {
                    result.notImplemented()
                }
            }

        keysChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "navalert/keys").also {
                it.setMethodCallHandler { call, result ->
                    if (call.method == "consumePendingShortcut") {
                        val pending = pendingShortcut
                        pendingShortcut = null
                        result.success(pending)
                    } else {
                        result.notImplemented()
                    }
                }
            }
        engineAlive = true
        // The app may have been launched BY a shortcut while no engine existed
        // (cold start from the background service). Stash it for Dart to pull.
        consumeShortcutIntent(intent)

        // Lets SoundService tell the shortcut service to pause its silent
        // keep-alive track while an alarm/ringtone plays (else it suppresses
        // the sound), then resume it afterwards.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "navalert/audioyield")
            .setMethodCallHandler { call, result ->
                if (call.method == "setAlarmActive") {
                    MediaButtonService.instance?.setAudioYield(call.arguments as? Boolean ?: false)
                    result.success(true)
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "navalert/lockscreen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showOverLockScreen" -> { setLockScreenVisible(true); result.success(true) }
                    "clearLockScreen" -> { setLockScreenVisible(false); result.success(true) }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Shows/hides this activity on top of the keyguard.
     *
     * Deliberately does NOT call requestDismissKeyguard: the rider must be
     * able to flash a ringing call screen without the phone demanding their
     * PIN first — prompting for it would break the illusion at exactly the
     * moment they need it, and would unlock the device in front of whoever
     * they are trying to get away from.
     *
     * Cleared when the call ends so NavAlert does not keep appearing over
     * the lock screen afterwards.
     */
    private fun setLockScreenVisible(visible: Boolean) = runOnUiThread {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(visible)
            setTurnScreenOn(visible)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (visible) window.addFlags(flags) else window.clearFlags(flags)
        }
        if (visible) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    // The service now captures volume keys in every state (foreground included,
    // via the MediaSession), so dispatchKeyEvent no longer handles them — doing
    // so would double-count presses and break the triple-press window.

    /** A shortcut arriving while the app is already running (singleTop). */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val type = intent.getStringExtra(MediaButtonService.EXTRA_SHORTCUT)
        if (type != null) {
            // Engine is alive here — deliver straight away.
            keysChannel?.invokeMethod("shortcut", type)
        }
    }

    /** Stash a shortcut carried by the launching intent for Dart to pull. */
    private fun consumeShortcutIntent(intent: Intent?) {
        intent?.getStringExtra(MediaButtonService.EXTRA_SHORTCUT)?.let {
            pendingShortcut = it
        }
    }

    override fun onDestroy() {
        // The engine is going away; the service must stop pushing to a dead
        // channel and fall back to launching the activity instead.
        engineAlive = false
        keysChannel = null
        super.onDestroy()
    }
}

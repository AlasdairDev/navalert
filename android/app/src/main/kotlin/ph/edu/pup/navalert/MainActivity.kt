package ph.edu.pup.navalert

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import android.view.WindowManager
import java.util.concurrent.atomic.AtomicInteger
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

        /**
         * True for the duration of a fake call (set by setLockScreenVisible,
         * which already brackets it exactly). MediaButtonService checks this so
         * relaying a volume change does not pop the system volume panel over the
         * call: NavAlert holds a REMOTE-volume MediaSession, and a volume change
         * from any source — an OEM "smart volume" tweak, a headset, or the
         * rider's own press — was raised with FLAG_SHOW_UI, so the slider
         * appeared unbidden on top of the incoming-call screen and broke the
         * illusion the feature exists to create (R7).
         */
        @JvmStatic
        @Volatile
        var fakeCallActive: Boolean = false
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
                        result.error(
                            "INVALID_ARGS",
                            "Contact number or message was empty.",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    // DO NOT MODIFY LOGIC: report WHY a send failed, never a bare
                    // `false`. This handler used to `catch (e: Exception) {
                    // result.success(false) }`, discarding the exception — so a
                    // SecurityException from a missing SEND_SMS grant reached Dart
                    // as an ordinary "not sent", and the rider was told "SOS queued
                    // — will retry when a cellular signal is available." That is a
                    // confident wrong diagnosis: it would fail identically on every
                    // retry, forever, while they waited for a signal that was never
                    // the problem. Each failure mode now carries its own code.
                    if (checkSelfPermission(Manifest.permission.SEND_SMS)
                        != PackageManager.PERMISSION_GRANTED
                    ) {
                        result.error(
                            "PERMISSION_DENIED",
                            "SEND_SMS permission is not granted.",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    sendSmsTracked(phone, message, result)
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

        // Earphone-only alarm routing (paper: the "Bluetooth / ear-phone only
        // detection" toggle). SoundService asks whether any headset — wired,
        // Bluetooth, or USB — is currently an audio OUTPUT so it can route the
        // alarm through the earphones instead of blasting the PUV speaker.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "navalert/audioroute")
            .setMethodCallHandler { call, result ->
                if (call.method == "isHeadsetConnected") {
                    result.success(isHeadsetConnected())
                } else {
                    result.notImplemented()
                }
            }
    }

    /**
     * True when a headset capable of playing audio is connected: wired
     * head{set,phones}, Bluetooth A2DP/SCO, or a USB headset. Uses AudioManager's
     * output-device list (API 23+, and NavAlert's minSdk is 26).
     */
    private fun isHeadsetConnected(): Boolean {
        val am = getSystemService(android.content.Context.AUDIO_SERVICE) as android.media.AudioManager
        val outputs = am.getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS)
        return outputs.any {
            it.type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                it.type == android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                it.type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                it.type == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                it.type == android.media.AudioDeviceInfo.TYPE_USB_HEADSET
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
        // Brackets the fake call for MediaButtonService (see fakeCallActive).
        fakeCallActive = visible
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

    // ── SOS SMS with real delivery tracking (R8) ────────────────────────────

    /** Distinguishes concurrent sends, so one contact's result cannot resolve another's. */
    private val smsRequestCounter = AtomicInteger(0)

    /**
     * How long to wait for the radio to report back before giving up.
     *
     * Generous on purpose: the common failures (no service, radio off) come
     * back almost immediately, so this only catches the pathological case where
     * the broadcast never arrives at all. Reporting "we don't know" beats
     * leaving the SOS button stuck reading "SENDING…" forever.
     */
    private val smsResultTimeoutMs = 30_000L

    /**
     * Sends one SMS and answers Flutter with what the NETWORK said, not with
     * whether the call threw.
     *
     * DO NOT MODIFY LOGIC - CAPSTONE DEFENSE CRITICAL:
     * `sendMultipartTextMessage` used to be called with a null `sentIntents`,
     * and the handler answered `success(true)` the moment it returned without
     * throwing. That is only a handoff to the radio: with no prepaid load or no
     * signal the message is accepted synchronously and dies asynchronously,
     * with nothing listening — so the app told the rider "Emergency SMS Sent"
     * for a message that never left the phone. On this feature a false success
     * is worse than a failure, because the rider stops trying to get help.
     *
     * Every part of a multipart message must be confirmed; the FIRST failing
     * part decides the reported outcome. `reply` is idempotent because Flutter
     * throws if a result is delivered twice, and here three different things
     * race to deliver it: the broadcast, the timeout, and a synchronous throw.
     */
    private fun sendSmsTracked(phone: String, message: String, result: MethodChannel.Result) {
        @Suppress("DEPRECATION")
        val sms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            getSystemService(SmsManager::class.java)
        else
            SmsManager.getDefault()

        val parts = sms.divideMessage(message)
        val total = if (parts.isEmpty()) 1 else parts.size
        val token = smsRequestCounter.incrementAndGet()
        val action = "$packageName.SMS_SENT.$token"
        val handler = Handler(Looper.getMainLooper())

        var replied = false
        var received = 0
        var firstFailure: Int? = null
        var receiver: BroadcastReceiver? = null
        var onTimeout: Runnable? = null

        fun reply(code: String?, msg: String?) {
            if (replied) return
            replied = true
            onTimeout?.let { handler.removeCallbacks(it) }
            receiver?.let {
                // Already gone if the activity was torn down mid-send.
                try { unregisterReceiver(it) } catch (_: IllegalArgumentException) {}
            }
            if (code == null) result.success(true) else result.error(code, msg, null)
        }

        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                received++
                if (resultCode != Activity.RESULT_OK && firstFailure == null) {
                    firstFailure = resultCode
                }
                if (received >= total) {
                    val failure = firstFailure
                    if (failure == null) reply(null, null)
                    else reply(smsErrorCode(failure), smsErrorMessage(failure))
                }
            }
        }

        val filter = IntentFilter(action)
        // API 34 refuses an unflagged runtime receiver. This one is fed only by
        // our own PendingIntent, so it must not be exported.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }

        onTimeout = Runnable {
            reply("TIMEOUT", "The network did not confirm the message in time.")
        }
        handler.postDelayed(onTimeout, smsResultTimeoutMs)

        val sentIntents = ArrayList<PendingIntent>(total)
        for (i in 0 until total) {
            val intent = Intent(action).setPackage(packageName)
            sentIntents.add(
                PendingIntent.getBroadcast(
                    this,
                    // Unique per part AND per request, or Android reuses one
                    // PendingIntent and only the last part ever reports back.
                    token * 64 + i,
                    intent,
                    // FLAG_IMMUTABLE is required from API 31; the system carries
                    // the outcome in the result CODE, not in the intent, so
                    // nothing here needs to be mutable.
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            )
        }

        try {
            sms.sendMultipartTextMessage(phone, null, parts, sentIntents, null)
        } catch (e: SecurityException) {
            reply("PERMISSION_DENIED", e.message ?: "SEND_SMS permission was refused.")
        } catch (e: IllegalArgumentException) {
            reply("INVALID_NUMBER", e.message ?: "The contact number was rejected.")
        } catch (e: Exception) {
            reply(e.javaClass.simpleName, e.message ?: "Native SMS send failed.")
        }
    }

    /** Stable codes for [SosService.describeFailure] on the Dart side. */
    private fun smsErrorCode(resultCode: Int): String = when (resultCode) {
        SmsManager.RESULT_ERROR_NO_SERVICE -> "NO_SERVICE"
        SmsManager.RESULT_ERROR_RADIO_OFF -> "RADIO_OFF"
        SmsManager.RESULT_ERROR_NULL_PDU -> "NULL_PDU"
        SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "GENERIC_FAILURE"
        else -> "SEND_FAILED_$resultCode"
    }

    private fun smsErrorMessage(resultCode: Int): String = when (resultCode) {
        SmsManager.RESULT_ERROR_NO_SERVICE -> "No cellular service."
        SmsManager.RESULT_ERROR_RADIO_OFF -> "The phone radio is off."
        SmsManager.RESULT_ERROR_NULL_PDU -> "The message could not be encoded."
        SmsManager.RESULT_ERROR_GENERIC_FAILURE ->
            "The network rejected the message (often no prepaid load)."
        else -> "The network reported error $resultCode."
    }
}

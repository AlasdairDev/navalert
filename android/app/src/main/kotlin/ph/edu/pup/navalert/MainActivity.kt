package ph.edu.pup.navalert

import android.os.Build
import android.telephony.SmsManager
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * NavAlert native bridge.
 *
 * 1. navalert/sms  — sends the SOS message through Native Android SMS
 *    (SmsManager), so the alert works with cellular signal only (R8).
 * 2. navalert/keys — forwards volume-key presses to Dart so triple
 *    Volume-Up triggers SOS and triple Volume-Down triggers the fake
 *    call (Specific Objective 4).
 * 3. navalert/lockscreen — lets the fake call render on top of the
 *    keyguard (UC-8 Exception 2), the way a real dialer shows an
 *    incoming call.
 */
class MainActivity : FlutterActivity() {
    private var keysChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "navalert/keys")

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

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP ->
                    keysChannel?.invokeMethod("volume", "up")
                KeyEvent.KEYCODE_VOLUME_DOWN ->
                    keysChannel?.invokeMethod("volume", "down")
            }
        }
        return super.dispatchKeyEvent(event)
    }
}

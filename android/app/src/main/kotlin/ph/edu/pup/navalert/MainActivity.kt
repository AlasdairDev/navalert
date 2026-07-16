package ph.edu.pup.navalert

import android.os.Build
import android.telephony.SmsManager
import android.view.KeyEvent
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

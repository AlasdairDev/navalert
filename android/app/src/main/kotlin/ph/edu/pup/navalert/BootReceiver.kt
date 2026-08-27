package ph.edu.pup.navalert

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Restarts [MediaButtonService] after the events that silently kill it.
 *
 * WHY THIS EXISTS
 * The shortcut service was only ever started from MainActivity's
 * `configureFlutterEngine`, which runs when the commuter opens the app. Nothing
 * else started it. So after a phone reboot — or after installing an update,
 * which kills the process — the volume shortcuts were dead until NavAlert
 * happened to be opened again, with no sign that anything was wrong: the
 * "safety shortcuts active" notification simply was not there.
 *
 * That is the worst possible failure for this feature. Its entire premise is a
 * phone that is pocketed with the screen off, so the commuter is least likely
 * to be looking at NavAlert precisely when they most need the shortcut to work.
 * Someone who reboots in the morning would have had no SOS shortcut all day.
 *
 * ACTIONS
 *  * BOOT_COMPLETED — delivered after the user unlocks following a reboot.
 *    LOCKED_BOOT_COMPLETED is deliberately NOT handled: it arrives before
 *    first unlock, when credential-protected storage is unreadable, and the
 *    app is not directBootAware.
 *  * MY_PACKAGE_REPLACED — sent to this app only, when it is updated.
 *  * QUICKBOOT_POWERON — the OEM equivalent of BOOT_COMPLETED on HTC and on
 *    Xiaomi/HyperOS, where stock BOOT_COMPLETED is not always delivered.
 *
 * All three are on Android 12's exemption list for starting a foreground
 * service from the background — except QUICKBOOT_POWERON, which is a vendor
 * broadcast and carries no such guarantee. Hence the catch: a boot-time crash
 * in a safety app is far worse than a shortcut that waits for the next launch.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            ACTION_QUICKBOOT_POWERON -> Unit
            else -> return
        }
        val svc = Intent(context, MediaButtonService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(svc)
            } else {
                context.startService(svc)
            }
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException on an OEM broadcast the
            // exemption list does not cover. Opening the app still arms the
            // shortcuts, so log and let it be.
            Log.w(TAG, "could not start shortcut service from ${intent.action}", e)
        }
    }

    private companion object {
        const val TAG = "NavAlertBoot"
        const val ACTION_QUICKBOOT_POWERON = "android.intent.action.QUICKBOOT_POWERON"
    }
}

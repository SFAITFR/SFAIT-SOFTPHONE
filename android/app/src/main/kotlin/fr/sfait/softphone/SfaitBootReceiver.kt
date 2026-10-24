package fr.sfait.softphone

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class SfaitBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (
            action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }

        try {
            val appContext = context.applicationContext
            if (!SoftphoneForegroundService.isPushModeEnabled(appContext)) {
                SoftphoneForegroundService.start(appContext)
            }
        } catch (_: Exception) {
            // Android can still restrict boot-started services on some vendors.
            // FCM remains the primary wake-up path for incoming calls.
        }
    }
}

package fr.sfait.softphone

import android.content.Context
import android.content.Intent
import android.os.PowerManager
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class SfaitFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        when (data["type"]) {
            "incoming_call" -> handleIncomingCall(data)
            "sip_wake" -> handleIncomingCall(data)
            "call_ended" -> SfaitAndroidCallBridge.endIncomingCallUiFromPush(applicationContext)
        }
    }

    private fun handleIncomingCall(data: Map<String, String>) {
        if (!SoftphoneForegroundService.isPushModeEnabled(applicationContext)) {
            return
        }

        val remoteIdentity = data["caller"]
            ?.takeIf { it.isNotBlank() }
            ?: data["remoteIdentity"]?.takeIf { it.isNotBlank() }
            ?: "Correspondant inconnu"

        SfaitPushWakeupStore.markIncomingWakeup(applicationContext, remoteIdentity)
        acquireIncomingCallWakeLock()
        runCatching {
            SoftphoneForegroundService.start(applicationContext, force = true)
        }
        runCatching {
            wakeFlutterSoftphone()
        }
        SfaitAndroidCallBridge.prepareIncomingCallFromPush(applicationContext, remoteIdentity)
    }

    override fun onNewToken(token: String) {
        applicationContext
            .getSharedPreferences(PUSH_PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(FCM_TOKEN_KEY, token)
            .apply()
    }

    companion object {
        const val PUSH_PREFERENCES_NAME = "sfait_push_notifications"
        const val FCM_TOKEN_KEY = "fcm_token"
    }

    private fun wakeFlutterSoftphone() {
        val intent = Intent(applicationContext, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("sfait_push_wakeup", true)
        }
        startActivity(intent)
    }

    private fun acquireIncomingCallWakeLock(): PowerManager.WakeLock? {
        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
            ?: return null
        return powerManager
            .newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "SFAITSoftphone:IncomingCall",
            )
            .apply { acquire(15_000L) }
    }
}

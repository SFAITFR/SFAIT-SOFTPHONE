package fr.sfait.softphone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

class SoftphoneForegroundService : Service() {
    companion object {
        private const val ACTION_STOP = "fr.sfait.softphone.action.STOP_FOREGROUND"
        private const val ACTION_UPDATE_STATUS = "fr.sfait.softphone.action.UPDATE_STATUS"
        private const val CHANNEL_ID = "sfait_softphone_background"
        private const val NOTIFICATION_ID = 4101
        private const val PREFERENCES_NAME = "sfait_softphone_foreground_status"
        private const val MODE_PREFERENCES_NAME = "sfait_softphone_android_mode"
        private const val STATUS_KEY = "status"
        private const val MESSAGE_KEY = "message"
        private const val EXTENSION_KEY = "extension"
        private const val PUSH_MODE_KEY = "push_mode_enabled"

        fun start(context: Context, force: Boolean = false) {
            if (!force && isPushModeEnabled(context)) {
                return
            }
            startServiceIntent(context, Intent(context, SoftphoneForegroundService::class.java))
        }

        fun setPushModeEnabled(context: Context, enabled: Boolean) {
            context.applicationContext
                .getSharedPreferences(MODE_PREFERENCES_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(PUSH_MODE_KEY, enabled)
                .apply()

            if (enabled) {
                runCatching { stop(context) }
            } else {
                runCatching { start(context, force = true) }
            }
        }

        fun isPushModeEnabled(context: Context): Boolean {
            return context.applicationContext
                .getSharedPreferences(MODE_PREFERENCES_NAME, Context.MODE_PRIVATE)
                .getBoolean(PUSH_MODE_KEY, false)
        }

        fun updateStatus(
            context: Context,
            status: String,
            message: String,
            extension: String,
        ) {
            context.applicationContext
                .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(STATUS_KEY, status)
                .putString(MESSAGE_KEY, message)
                .putString(EXTENSION_KEY, extension)
                .apply()

            if (!shouldKeepForeground(context, status)) {
                runCatching { stop(context) }
                return
            }

            runCatching {
                startServiceIntent(
                    context,
                    Intent(context, SoftphoneForegroundService::class.java).apply {
                        action = ACTION_UPDATE_STATUS
                    },
                )
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, SoftphoneForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }

        private fun startServiceIntent(context: Context, intent: Intent) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        private fun shouldKeepForeground(context: Context, status: String): Boolean {
            if (!isPushModeEnabled(context)) {
                return true
            }

            return status == "connecting" ||
                (status == "registered" && SfaitPushWakeupStore.isActive(context)) ||
                status == "calling" ||
                status == "ringing" ||
                status == "inCall"
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (isPushModeEnabled(applicationContext)) {
            stopSelf()
            super.onTaskRemoved(rootIntent)
            return
        }

        runCatching { SfaitFlutterEngineHost.ensureEngine(applicationContext) }
        runCatching { start(applicationContext) }
        super.onTaskRemoved(rootIntent)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        val notification = buildForegroundNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        runCatching { SfaitFlutterEngineHost.ensureEngine(applicationContext) }
        return START_STICKY
    }

    private fun buildForegroundNotification(): Notification {
        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureNotificationChannel(notificationManager)

        val launchIntent = (packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            4101,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val statusText = currentStatusText()

        return builder
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setContentTitle("SFAIT Softphone")
            .setContentText(statusText)
            .setStyle(Notification.BigTextStyle().bigText(statusText))
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(Notification.PRIORITY_LOW)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun ensureNotificationChannel(notificationManager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val channel = NotificationChannel(
            CHANNEL_ID,
            "Softphone en arrière-plan",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Maintient SFAIT Softphone disponible en arrière-plan."
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
        }
        notificationManager.createNotificationChannel(channel)
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun currentStatusText(): String {
        val preferences = getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
        val status = preferences.getString(STATUS_KEY, "") ?: ""
        val message = preferences.getString(MESSAGE_KEY, "") ?: ""
        val extension = preferences.getString(EXTENSION_KEY, "") ?: ""
        val extensionSuffix = if (extension.isBlank()) "" else " (poste $extension)"

        return when (status) {
            "connecting" -> "SIP en connexion$extensionSuffix"
            "registered" -> "SIP enregistré$extensionSuffix"
            "calling" -> "Appel en cours$extensionSuffix"
            "ringing" -> "Appel entrant$extensionSuffix"
            "inCall" -> "Communication en cours$extensionSuffix"
            "error" -> if (message.isBlank()) {
                "SIP en erreur$extensionSuffix"
            } else {
                "SIP en erreur$extensionSuffix : $message"
            }
            "offline" -> if (extension.isBlank()) {
                "SIP non configuré"
            } else {
                "SIP non enregistré$extensionSuffix"
            }
            else -> "Démarrage du service SIP..."
        }
    }
}

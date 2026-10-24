package fr.sfait.softphone

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

object SfaitAndroidCallBridge {
    const val CHANNEL_NAME = "sfait/android_call_ui"
    const val EXTRA_REMOTE_IDENTITY = "fr.sfait.softphone.extra.REMOTE_IDENTITY"

    private const val LEGACY_PHONE_ACCOUNT_ID = "sfait_softphone_phone_account"
    private const val PHONE_ACCOUNT_ID = "sfait_softphone_native_phone_account_v2"
    private const val PREFERENCES_NAME = "sfait_android_call_ui"
    private const val PENDING_ACTION_KEY = "pending_call_action"
    private const val PENDING_REMOTE_IDENTITY_KEY = "pending_remote_identity"
    private const val INCOMING_CALL_CHANNEL_ID = "sfait_softphone_incoming_calls"
    private const val INCOMING_CALL_NOTIFICATION_ID = 4102
    private const val STALE_INCOMING_UI_TIMEOUT_MS = 60_000L

    private var methodChannel: MethodChannel? = null
    private var activeConnection: SfaitCallConnection? = null
    private var incomingActivityRef: WeakReference<IncomingCallActivity>? = null
    private var appContext: Context? = null
    private var suppressIncomingUiUntilMillis: Long = 0L
    private var incomingUiGeneration: Long = 0L
    private var hasPendingIncomingUi = false
    private var hasConfirmedSipIncomingCall = false
    private val mainHandler = Handler(Looper.getMainLooper())

    fun configure(context: Context, flutterEngine: FlutterEngine) {
        attachContext(context)
        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME
        ).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "registerPhoneAccount" -> {
                        runCatching { registerPhoneAccount(context.applicationContext) }
                            .fold(
                                onSuccess = { result.success(null) },
                                onFailure = { result.error("android_call_ui", it.message, null) },
                            )
                    }

                    "isPhoneAccountActive" -> {
                        result.success(isPhoneAccountActive(context.applicationContext))
                    }

                    "openPhoneAccountSettings" -> {
                        openPhoneAccountSettings(context.applicationContext)
                        result.success(null)
                    }

                    "showIncomingCallUi" -> {
                        val remoteIdentity =
                            call.argument<String>("remoteIdentity")?.takeIf { it.isNotBlank() }
                                ?: "Correspondant inconnu"
                        runCatching {
                            showIncomingCallUi(context.applicationContext, remoteIdentity)
                        }.fold(
                            onSuccess = { result.success(null) },
                            onFailure = { result.error("android_call_ui", it.message, null) },
                        )
                    }

                    "setCallActive" -> {
                        markSipIncomingCallConfirmed()
                        activeConnection?.markActiveFromFlutter()
                        cancelIncomingCallNotification()
                        dismissIncomingActivity()
                        result.success(null)
                    }

                    "setCallRinging" -> {
                        markSipIncomingCallConfirmed()
                        result.success(null)
                    }

                    "endCallUi" -> {
                        endCallUiFromFlutter()
                        result.success(null)
                    }

                    "consumePendingCallAction" -> {
                        result.success(consumePendingCallAction(context.applicationContext))
                    }

                    else -> result.notImplemented()
                }
            }
        }
    }

    fun attachContext(context: Context) {
        appContext = context.applicationContext
    }

    fun createIncomingConnection(remoteIdentity: String): SfaitCallConnection {
        return SfaitCallConnection(remoteIdentity).also { activeConnection = it }
    }

    fun registerIncomingActivity(activity: IncomingCallActivity) {
        incomingActivityRef = WeakReference(activity)
    }

    fun unregisterIncomingActivity(activity: IncomingCallActivity) {
        if (incomingActivityRef?.get() === activity) {
            incomingActivityRef = null
        }
    }

    fun showIncomingActivity(context: Context, remoteIdentity: String) {
        if (shouldSuppressIncomingUi()) {
            launchMainActivity(context)
            return
        }

        val intent = Intent(context, IncomingCallActivity::class.java).apply {
            putExtra(EXTRA_REMOTE_IDENTITY, remoteIdentity)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }
        context.startActivity(intent)
    }

    fun showIncomingActivity(remoteIdentity: String) {
        appContext?.let { showIncomingActivity(it, remoteIdentity) }
    }

    fun prepareIncomingCallFromPush(context: Context, remoteIdentity: String) {
        attachContext(context)
        // The push only wakes Flutter/SIP. The native call screen is created by
        // the real SIP INVITE so answering is only possible once media exists.
        clearPendingIncomingUi()
    }

    fun endIncomingCallUiFromPush(context: Context) {
        attachContext(context)
        activeConnection?.disconnectRemoteCanceled()
        activeConnection = null
        cancelIncomingCallNotification()
        dismissIncomingActivity()
        clearSuppressedIncomingUi()
        clearPendingIncomingUi()
    }

    fun answerFromNativeUi() {
        suppressIncomingUiTemporarily()
        cancelIncomingCallNotification()
        dismissIncomingActivity()
        activeConnection?.markAnsweredFromNativeUi()
        dispatchCallAction("answer")
    }

    fun rejectFromNativeUi() {
        cancelIncomingCallNotification()
        dismissIncomingActivity()
        activeConnection?.markRejectedFromNativeUi()
        dispatchCallAction("reject")
        activeConnection = null
        clearPendingIncomingUi()
    }

    fun hangupFromNativeUi() {
        cancelIncomingCallNotification()
        dismissIncomingActivity()
        activeConnection?.markDisconnectedFromNativeUi()
        dispatchCallAction("hangup")
        activeConnection = null
        clearPendingIncomingUi()
    }

    private fun dispatchCallAction(action: String) {
        val payload = mapOf(
            "action" to action,
            "remoteIdentity" to (activeConnection?.remoteIdentity ?: ""),
        )
        val channel = methodChannel
        if (channel != null) {
            channel.invokeMethod("onCallAction", payload)
            return
        }

        val context = appContext ?: return
        persistPendingCallAction(context, action, payload["remoteIdentity"].orEmpty())
        launchMainActivity(context)
    }

    private fun persistPendingCallAction(
        context: Context,
        action: String,
        remoteIdentity: String,
    ) {
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(PENDING_ACTION_KEY, action)
            .putString(PENDING_REMOTE_IDENTITY_KEY, remoteIdentity)
            .apply()
    }

    private fun consumePendingCallAction(context: Context): Map<String, String>? {
        val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
        val action = preferences.getString(PENDING_ACTION_KEY, null)?.takeIf { it.isNotBlank() }
            ?: return null
        val remoteIdentity = preferences.getString(PENDING_REMOTE_IDENTITY_KEY, "") ?: ""
        preferences.edit()
            .remove(PENDING_ACTION_KEY)
            .remove(PENDING_REMOTE_IDENTITY_KEY)
            .apply()
        return mapOf(
            "action" to action,
            "remoteIdentity" to remoteIdentity,
        )
    }

    private fun launchMainActivity(context: Context) {
        val intent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        context.startActivity(intent)
    }

    private fun showIncomingCallUi(context: Context, remoteIdentity: String) {
        if (shouldSuppressIncomingUi()) {
            launchMainActivity(context)
            return
        }

        if (hasIncomingUiInProgress()) {
            markSipIncomingCallConfirmed()
            return
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            showIncomingActivity(context, remoteIdentity)
            return
        }

        registerPhoneAccount(context)
        val telecomManager = telecomManager(context)
            ?: throw IllegalStateException("TelecomManager indisponible.")
        val handle = phoneAccountHandle(context)
        val extras = Bundle().apply {
            putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
            putParcelable(
                TelecomManager.EXTRA_INCOMING_CALL_ADDRESS,
                Uri.fromParts("tel", remoteIdentity, null),
            )
            putString(EXTRA_REMOTE_IDENTITY, remoteIdentity)
        }

        try {
            telecomManager.addNewIncomingCall(handle, extras)
        } catch (_: Exception) {
            showIncomingActivity(context, remoteIdentity)
        }
    }

    fun showIncomingCallNotification(context: Context, remoteIdentity: String) {
        attachContext(context)
        if (shouldSuppressIncomingUi()) {
            launchMainActivity(context)
            return
        }

        val appContext = context.applicationContext
        val notificationManager =
            appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        ensureIncomingCallChannel(notificationManager)

        val callIntent = Intent(appContext, IncomingCallActivity::class.java).apply {
            putExtra(EXTRA_REMOTE_IDENTITY, remoteIdentity)
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
        }
        val fullScreenIntent = PendingIntent.getActivity(
            appContext,
            INCOMING_CALL_NOTIFICATION_ID,
            callIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(appContext, INCOMING_CALL_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(appContext)
        }

        val notification = builder
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setContentTitle("Appel entrant")
            .setContentText(remoteIdentity)
            .setCategory(Notification.CATEGORY_CALL)
            .setPriority(Notification.PRIORITY_MAX)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setContentIntent(fullScreenIntent)
            .setFullScreenIntent(fullScreenIntent, true)
            .build()

        notificationManager.notify(INCOMING_CALL_NOTIFICATION_ID, notification)
    }

    fun showIncomingCallNotification(remoteIdentity: String) {
        appContext?.let { showIncomingCallNotification(it, remoteIdentity) }
    }

    fun isPhoneAccountActive(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return true
        }

        return runCatching {
            registerPhoneAccount(context.applicationContext)
            if (!canReadPhoneAccountState(context)) {
                return@runCatching false
            }
            val telecomManager = telecomManager(context)
                ?: return@runCatching false
            telecomManager.getPhoneAccount(phoneAccountHandle(context))?.isEnabled == true
        }.getOrDefault(false)
    }

    fun openPhoneAccountSettings(context: Context) {
        val appContext = context.applicationContext
        val intent = Intent(TelecomManager.ACTION_CHANGE_PHONE_ACCOUNTS).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        runCatching { appContext.startActivity(intent) }
            .onFailure {
                val fallbackIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:${appContext.packageName}")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                appContext.startActivity(fallbackIntent)
            }
    }

    private fun registerPhoneAccount(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val telecomManager = telecomManager(context)
            ?: throw IllegalStateException("TelecomManager indisponible.")
        unregisterLegacyPhoneAccount(context, telecomManager)
        val handle = phoneAccountHandle(context)
        val account = PhoneAccount.builder(handle, "SFAIT Softphone")
            .setCapabilities(PhoneAccount.CAPABILITY_CALL_PROVIDER)
            .setShortDescription("SFAIT Softphone")
            .setSupportedUriSchemes(listOf(PhoneAccount.SCHEME_TEL))
            .build()
        telecomManager.registerPhoneAccount(account)
    }

    private fun unregisterLegacyPhoneAccount(
        context: Context,
        telecomManager: TelecomManager,
    ) {
        val legacyHandle = PhoneAccountHandle(
            ComponentName(context, SfaitConnectionService::class.java),
            LEGACY_PHONE_ACCOUNT_ID,
        )
        runCatching { telecomManager.unregisterPhoneAccount(legacyHandle) }
    }

    private fun phoneAccountHandle(context: Context): PhoneAccountHandle {
        return PhoneAccountHandle(
            ComponentName(context, SfaitConnectionService::class.java),
            PHONE_ACCOUNT_ID,
        )
    }

    private fun telecomManager(context: Context): TelecomManager? {
        return context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
    }

    private fun dismissIncomingActivity() {
        incomingActivityRef?.get()?.finishFromBridge()
        incomingActivityRef = null
    }

    private fun endCallUiFromFlutter() {
        activeConnection?.disconnectFromFlutter()
        activeConnection = null
        cancelIncomingCallNotification()
        dismissIncomingActivity()
        clearSuppressedIncomingUi()
        clearPendingIncomingUi()
    }

    private fun startPendingIncomingUi() {
        hasPendingIncomingUi = true
        hasConfirmedSipIncomingCall = false
        incomingUiGeneration += 1
        val generation = incomingUiGeneration
        mainHandler.postDelayed(
            {
                if (generation == incomingUiGeneration && !hasConfirmedSipIncomingCall) {
                    activeConnection?.disconnectRemoteCanceled()
                    activeConnection = null
                    cancelIncomingCallNotification()
                    dismissIncomingActivity()
                    clearSuppressedIncomingUi()
                    clearPendingIncomingUi()
                }
            },
            STALE_INCOMING_UI_TIMEOUT_MS,
        )
    }

    private fun markSipIncomingCallConfirmed() {
        hasConfirmedSipIncomingCall = true
    }

    private fun clearPendingIncomingUi() {
        hasPendingIncomingUi = false
        hasConfirmedSipIncomingCall = false
        incomingUiGeneration += 1
    }

    private fun hasIncomingUiInProgress(): Boolean {
        return hasPendingIncomingUi ||
            activeConnection != null ||
            incomingActivityRef?.get() != null
    }

    private fun suppressIncomingUiTemporarily() {
        suppressIncomingUiUntilMillis = System.currentTimeMillis() + 15_000L
    }

    private fun clearSuppressedIncomingUi() {
        suppressIncomingUiUntilMillis = 0L
    }

    private fun shouldSuppressIncomingUi(): Boolean {
        return System.currentTimeMillis() < suppressIncomingUiUntilMillis
    }

    private fun canReadPhoneAccountState(context: Context): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun cancelIncomingCallNotification() {
        val context = appContext ?: return
        val notificationManager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.cancel(INCOMING_CALL_NOTIFICATION_ID)
    }

    private fun ensureIncomingCallChannel(notificationManager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val channel = NotificationChannel(
            INCOMING_CALL_CHANNEL_ID,
            "Appels entrants",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Affiche les appels entrants SFAIT Softphone."
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setSound(null, null)
        }
        notificationManager.createNotificationChannel(channel)
    }
}

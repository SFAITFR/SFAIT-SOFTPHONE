package fr.sfait.softphone

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object SfaitNativeChannels {
    fun configure(context: Context, flutterEngine: FlutterEngine) {
        val appContext = context.applicationContext

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "sfait/system_settings",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "listPrivacyPermissions" -> result.success(
                    buildList {
                        add(
                            mapOf(
                                "kind" to "microphone",
                                "label" to "Microphone",
                                "description" to "Autorise la capture de votre voix pendant les appels.",
                                "isActive" to isRecordAudioGranted(appContext),
                            ),
                        )
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            add(
                                mapOf(
                                    "kind" to "notifications",
                                    "label" to "Notifications",
                                    "description" to "Affiche le softphone actif en arrière-plan.",
                                    "isActive" to isNotificationPermissionGranted(appContext),
                                ),
                            )
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            add(
                                mapOf(
                                    "kind" to "androidPhoneAccount",
                                    "label" to "Compte d'appel Android",
                                    "description" to "Autorise l'interface d'appel native Samsung/Android.",
                                    "isActive" to SfaitAndroidCallBridge.isPhoneAccountActive(
                                        appContext,
                                    ),
                                ),
                            )
                        }
                    },
                )

                "startAndroidBackgroundService" -> {
                    runCatching { SoftphoneForegroundService.start(appContext) }
                    result.success(null)
                }

                "setAndroidPushModeEnabled" -> {
                    SoftphoneForegroundService.setPushModeEnabled(
                        appContext,
                        call.argument<Boolean>("enabled") ?: false,
                    )
                    result.success(null)
                }

                "consumeAndroidPushWakeup" -> {
                    result.success(SfaitPushWakeupStore.snapshot(appContext))
                }

                "stopAndroidBackgroundService" -> {
                    runCatching { SoftphoneForegroundService.stop(appContext) }
                    result.success(null)
                }

                "updateAndroidBackgroundStatus" -> {
                    SoftphoneForegroundService.updateStatus(
                        appContext,
                        call.argument<String>("status").orEmpty(),
                        call.argument<String>("message").orEmpty(),
                        call.argument<String>("extension").orEmpty(),
                    )
                    result.success(null)
                }

                "openPrivacyPermissionSettings" -> {
                    if (call.argument<String>("kind") == "androidPhoneAccount") {
                        SfaitAndroidCallBridge.openPhoneAccountSettings(appContext)
                    } else {
                        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = Uri.parse("package:${appContext.packageName}")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        appContext.startActivity(intent)
                    }
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "sfait/android_audio_route",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSpeakerEnabled" -> {
                    setSpeakerEnabled(appContext, call.argument<Boolean>("enabled") ?: false)
                    result.success(null)
                }

                "resetAudioRoute" -> {
                    resetAudioRoute(appContext)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "sfait/push_notifications",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getFcmToken" -> {
                    FirebaseMessaging.getInstance().token
                        .addOnCompleteListener { task ->
                            if (task.isSuccessful) {
                                result.success(task.result)
                            } else {
                                result.error(
                                    "fcm_token_error",
                                    task.exception?.message ?: "Token FCM indisponible.",
                                    null,
                                )
                            }
                        }
                }

                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "sfait/ringtone",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "playRingtone",
                "stopRingtone",
                "setRingtoneVolume" -> result.success(null)
                "importRingtone" -> result.success(null)
                else -> result.notImplemented()
            }
        }
    }

    private fun isNotificationPermissionGranted(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun isRecordAudioGranted(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun setSpeakerEnabled(context: Context, enabled: Boolean) {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val targetType = if (enabled) {
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            } else {
                AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            }
            val targetDevice = audioManager.availableCommunicationDevices
                .firstOrNull { device -> device.type == targetType }

            if (targetDevice != null) {
                audioManager.setCommunicationDevice(targetDevice)
            } else if (!enabled) {
                audioManager.clearCommunicationDevice()
            }
        }

        @Suppress("DEPRECATION")
        audioManager.isSpeakerphoneOn = enabled
    }

    private fun resetAudioRoute(context: Context) {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        @Suppress("DEPRECATION")
        audioManager.isSpeakerphoneOn = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.clearCommunicationDevice()
        }
        audioManager.mode = AudioManager.MODE_NORMAL
    }
}

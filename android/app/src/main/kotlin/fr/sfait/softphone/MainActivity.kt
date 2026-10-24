package fr.sfait.softphone

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestRuntimePermissions()
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        return SfaitFlutterEngineHost.ensureEngine(context)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        SfaitFlutterEngineHost.configureChannels(this, flutterEngine)
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    @Deprecated("Use OnBackPressedDispatcher when moving away from FlutterActivity defaults.")
    override fun onBackPressed() {
        moveTaskToBack(true)
    }

    private fun requestRuntimePermissions() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }

        val missingPermissions = mutableListOf<String>()
        if (!isRecordAudioGranted()) {
            missingPermissions.add(Manifest.permission.RECORD_AUDIO)
        }
        if (!isReadPhoneStateGranted()) {
            missingPermissions.add(Manifest.permission.READ_PHONE_STATE)
        }
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !isNotificationPermissionGranted()
        ) {
            missingPermissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }

        if (missingPermissions.isNotEmpty()) {
            requestPermissions(missingPermissions.toTypedArray(), 4100)
        }
    }

    private fun isNotificationPermissionGranted(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun isRecordAudioGranted(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun isReadPhoneStateGranted(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            checkSelfPermission(Manifest.permission.READ_PHONE_STATE) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }
}

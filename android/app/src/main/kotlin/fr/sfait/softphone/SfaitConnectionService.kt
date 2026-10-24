package fr.sfait.softphone

import android.net.Uri
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.TelecomManager

class SfaitConnectionService : ConnectionService() {
    override fun onCreate() {
        super.onCreate()
        SfaitAndroidCallBridge.attachContext(applicationContext)
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: android.telecom.PhoneAccountHandle?,
        request: ConnectionRequest?,
    ): Connection {
        val remoteIdentity = request?.extras
            ?.getString(SfaitAndroidCallBridge.EXTRA_REMOTE_IDENTITY)
            ?.takeIf { it.isNotBlank() }
            ?: request?.address?.schemeSpecificPart?.takeIf { it.isNotBlank() }
            ?: "Correspondant inconnu"

        return SfaitAndroidCallBridge
            .createIncomingConnection(remoteIdentity)
            .also { it.setRinging() }
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: android.telecom.PhoneAccountHandle?,
        request: ConnectionRequest?,
    ) {
        super.onCreateIncomingConnectionFailed(connectionManagerPhoneAccount, request)
        SfaitAndroidCallBridge.rejectFromNativeUi()
    }
}

class SfaitCallConnection(
    val remoteIdentity: String,
) : Connection() {
    private var isEnding = false
    private var hasBeenAnswered = false

    init {
        setAddress(
            Uri.fromParts("tel", remoteIdentity, null),
            TelecomManager.PRESENTATION_ALLOWED,
        )
        setCallerDisplayName(remoteIdentity, TelecomManager.PRESENTATION_ALLOWED)
        setAudioModeIsVoip(true)
        connectionCapabilities =
            CAPABILITY_MUTE or CAPABILITY_SUPPORT_HOLD or CAPABILITY_HOLD
    }

    override fun onShowIncomingCallUi() {
        // Managed Telecom accounts use the Android system incoming-call UI.
        // The app fallback UI is launched only when Telecom rejects the account.
    }

    override fun onAnswer() {
        SfaitAndroidCallBridge.answerFromNativeUi()
    }

    override fun onReject() {
        SfaitAndroidCallBridge.rejectFromNativeUi()
    }

    override fun onAbort() {
        SfaitAndroidCallBridge.rejectFromNativeUi()
    }

    override fun onDisconnect() {
        if (isEnding) {
            return
        }
        SfaitAndroidCallBridge.hangupFromNativeUi()
    }

    fun markAnsweredFromNativeUi() {
        if (isEnding) {
            return
        }
        hasBeenAnswered = true
        setActive()
    }

    fun markRejectedFromNativeUi() {
        disconnect(DisconnectCause.REJECTED)
    }

    fun markDisconnectedFromNativeUi() {
        disconnect(DisconnectCause.LOCAL)
    }

    fun markActiveFromFlutter() {
        if (isEnding) {
            return
        }
        hasBeenAnswered = true
        setActive()
    }

    fun disconnectFromFlutter() {
        disconnect(DisconnectCause.LOCAL)
    }

    fun disconnectRemoteCanceled() {
        disconnect(DisconnectCause.REMOTE)
    }

    private fun disconnect(cause: Int) {
        if (isEnding) {
            return
        }
        isEnding = true
        setDisconnected(DisconnectCause(cause))
        destroy()
    }
}

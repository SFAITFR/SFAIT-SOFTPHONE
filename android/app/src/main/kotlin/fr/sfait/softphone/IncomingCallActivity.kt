package fr.sfait.softphone

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.pow

class IncomingCallActivity : Activity() {
    private var ringtonePlayer: MediaPlayer? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private val audioFocusChangeListener = AudioManager.OnAudioFocusChangeListener { }
    private var remoteIdentity: String = "Correspondant inconnu"
    private var isCompleting = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        SfaitAndroidCallBridge.registerIncomingActivity(this)
        configureWindow()
        remoteIdentity = readRemoteIdentity(intent)
        setContentView(buildContent())
        startSystemRingtone()
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        remoteIdentity = readRemoteIdentity(intent)
        setContentView(buildContent())
        startSystemRingtone()
    }

    @Deprecated("Incoming call screen intentionally consumes Back.")
    override fun onBackPressed() {
        // Do not hide the incoming call screen accidentally.
    }

    override fun onDestroy() {
        stopSystemRingtone()
        SfaitAndroidCallBridge.unregisterIncomingActivity(this)
        super.onDestroy()
    }

    fun finishFromBridge() {
        stopSystemRingtone()
        finish()
        overridePendingTransition(0, 0)
    }

    private fun configureWindow() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }

        window.addFlags(
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_ALLOW_LOCK_WHILE_SCREEN_ON
        )
        window.statusBarColor = Color.parseColor("#07111f")
        window.navigationBarColor = Color.parseColor("#07111f")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val keyguardManager =
                getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            keyguardManager?.requestDismissKeyguard(this, null)
        }
    }

    private fun buildContent(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(36), dp(28), dp(34))
            setBackgroundColor(Color.parseColor("#07111f"))
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }

        root.addView(
            TextView(this).apply {
                text = "SFAIT Softphone"
                setTextColor(Color.parseColor("#dbe7ff"))
                textSize = 20f
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        root.addView(spacer(weight = 1f))

        root.addView(
            ImageView(this).apply {
                setImageResource(android.R.drawable.sym_call_incoming)
                setColorFilter(Color.parseColor("#a9c3ff"))
            },
            LinearLayout.LayoutParams(dp(56), dp(56)).apply {
                bottomMargin = dp(18)
            },
        )

        root.addView(
            TextView(this).apply {
                text = "Appel entrant"
                setTextColor(Color.parseColor("#a9c3ff"))
                textSize = 19f
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        root.addView(
            TextView(this).apply {
                text = remoteIdentity
                setTextColor(Color.WHITE)
                textSize = 32f
                typeface = Typeface.DEFAULT_BOLD
                gravity = Gravity.CENTER
                includeFontPadding = false
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply {
                topMargin = dp(12)
            },
        )

        root.addView(
            TextView(this).apply {
                text = "Appel SIP entrant"
                setTextColor(Color.parseColor("#c9d4e8"))
                textSize = 15f
                gravity = Gravity.CENTER
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply {
                topMargin = dp(10)
            },
        )

        root.addView(spacer(weight = 1.4f))

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }

        actions.addView(
            actionButton(
                label = "Décliner",
                color = "#ef4444",
                onClick = {
                    completeIncomingCall {
                        SfaitAndroidCallBridge.rejectFromNativeUi()
                    }
                },
            ),
            LinearLayout.LayoutParams(0, dp(58), 1f).apply {
                marginEnd = dp(10)
            },
        )

        actions.addView(
            actionButton(
                label = "Répondre",
                color = "#22c55e",
                onClick = {
                    completeIncomingCall {
                        SfaitAndroidCallBridge.answerFromNativeUi()
                    }
                },
            ),
            LinearLayout.LayoutParams(0, dp(58), 1f).apply {
                marginStart = dp(10)
            },
        )

        root.addView(
            actions,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ),
        )

        return root
    }

    private fun completeIncomingCall(action: () -> Unit) {
        if (isCompleting) {
            return
        }
        isCompleting = true
        stopSystemRingtone()
        finish()
        overridePendingTransition(0, 0)
        action()
    }

    private fun actionButton(
        label: String,
        color: String,
        onClick: () -> Unit,
    ): Button {
        return Button(this).apply {
            text = label
            textSize = 16f
            typeface = Typeface.DEFAULT_BOLD
            isAllCaps = false
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply {
                cornerRadius = dp(28).toFloat()
                setColor(Color.parseColor(color))
            }
            setOnClickListener { onClick() }
        }
    }

    private fun spacer(weight: Float): TextView {
        return TextView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                weight,
            )
        }
    }

    private fun startSystemRingtone() {
        stopSystemRingtone()
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val volume = currentSystemRingtoneVolume(audioManager)
        if (volume <= 0f || audioManager.ringerMode != AudioManager.RINGER_MODE_NORMAL) {
            return
        }

        val uri = RingtoneManager.getActualDefaultRingtoneUri(
            this,
            RingtoneManager.TYPE_RINGTONE,
        ) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)

        requestRingtoneAudioFocus()
        ringtonePlayer = MediaPlayer().apply {
            setDataSource(this@IncomingCallActivity, uri)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build())
            } else {
                @Suppress("DEPRECATION")
                setAudioStreamType(AudioManager.STREAM_RING)
            }
            isLooping = true
            prepare()
            setVolume(volume, volume)
            start()
        }
    }

    private fun stopSystemRingtone() {
        ringtonePlayer?.let { player ->
            runCatching {
                if (player.isPlaying) {
                    player.stop()
                }
            }
            player.release()
        }
        ringtonePlayer = null
        abandonRingtoneAudioFocus()
    }

    private fun requestRingtoneAudioFocus() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build())
                .setOnAudioFocusChangeListener(audioFocusChangeListener)
                .build()
            audioFocusRequest = request
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                audioFocusChangeListener,
                AudioManager.STREAM_RING,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            )
        }
    }

    private fun abandonRingtoneAudioFocus() {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            audioFocusRequest = null
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(audioFocusChangeListener)
        }
    }

    private fun currentSystemRingtoneVolume(audioManager: AudioManager): Float {
        val maxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_RING)
        if (maxVolume <= 0) {
            return 1f
        }

        val currentVolume = audioManager
            .getStreamVolume(AudioManager.STREAM_RING)
            .coerceIn(0, maxVolume)
        val normalizedVolume = currentVolume.toFloat() / maxVolume.toFloat()

        // Android exposes ringtone volume in coarse hardware steps. The first
        // audible step can still be loud, so we apply a perceptual curve before
        // feeding MediaPlayer's linear gain.
        return normalizedVolume.toDouble()
            .pow(2.4)
            .toFloat()
            .coerceIn(0f, 1f)
    }

    private fun readRemoteIdentity(intent: Intent?): String {
        return intent?.getStringExtra(SfaitAndroidCallBridge.EXTRA_REMOTE_IDENTITY)
            ?.takeIf { it.isNotBlank() }
            ?: "Correspondant inconnu"
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }
}

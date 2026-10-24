package fr.sfait.softphone

import android.content.Context

object SfaitPushWakeupStore {
    private const val PREFERENCES_NAME = "sfait_softphone_push_wakeup"
    private const val ACTIVE_UNTIL_KEY = "active_until"
    private const val REMOTE_IDENTITY_KEY = "remote_identity"
    private const val WAKE_WINDOW_MS = 45_000L

    fun markIncomingWakeup(context: Context, remoteIdentity: String) {
        val activeUntil = System.currentTimeMillis() + WAKE_WINDOW_MS
        context.applicationContext
            .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .putLong(ACTIVE_UNTIL_KEY, activeUntil)
            .putString(REMOTE_IDENTITY_KEY, remoteIdentity)
            .apply()
    }

    fun isActive(context: Context): Boolean {
        val preferences = context.applicationContext
            .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
        return preferences.getLong(ACTIVE_UNTIL_KEY, 0L) > System.currentTimeMillis()
    }

    fun snapshot(context: Context): Map<String, Any> {
        val preferences = context.applicationContext
            .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val activeUntil = preferences.getLong(ACTIVE_UNTIL_KEY, 0L)
        val active = activeUntil > now
        return mapOf(
            "active" to active,
            "remainingMs" to if (active) activeUntil - now else 0L,
            "remoteIdentity" to preferences.getString(REMOTE_IDENTITY_KEY, "").orEmpty(),
        )
    }
}

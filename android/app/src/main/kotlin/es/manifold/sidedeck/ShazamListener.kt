package es.manifold.sidedeck

import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import io.flutter.plugin.common.EventChannel

/// Passes what Shazam shows in its result notification (song and artist) to the app.
object ShazamBridge {
    var sink: EventChannel.EventSink? = null
    private const val PREFS = "shazam_bridge"
    private const val KEY = "pending"

    fun post(ctx: Context, title: String, artist: String) {
        val s = sink
        if (s != null) {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                s.success(mapOf("title" to title, "artist" to artist))
            }
        } else {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val old = p.getString(KEY, "") ?: ""
            p.edit().putString(KEY, old + title + "\t" + artist + "\n").apply()
        }
    }

    fun drain(ctx: Context): List<Map<String, String>> {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val raw = p.getString(KEY, "") ?: ""
        p.edit().remove(KEY).apply()
        return raw.split("\n").filter { it.contains("\t") }.map {
            val parts = it.split("\t")
            mapOf("title" to parts[0], "artist" to parts.getOrElse(1) { "" })
        }
    }
}

class ShazamListener : NotificationListenerService() {
    private var last = ""

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName != "com.shazam.android") return
        val extras = sbn.notification.extras ?: return
        val title = extras.getCharSequence("android.title")?.toString()?.trim() ?: return
        val text = extras.getCharSequence("android.text")?.toString()?.trim() ?: ""
        if (title.isEmpty() || text.isEmpty()) return
        val low = (title + " " + text).lowercase()
        // Not a result: listening, searching, no match, reminders.
        val skip = listOf("listening", "tap to", "couldn't", "could not", "no result", "no match",
            "try again", "shazam is", "auto shazam", "searching", "tagging", "offline")
        if (skip.any { low.contains(it) }) return
        val key = "$title|$text"
        if (key == last) return
        last = key
        ShazamBridge.post(applicationContext, title, text)
    }
}

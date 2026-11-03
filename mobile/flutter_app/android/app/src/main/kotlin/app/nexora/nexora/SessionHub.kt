package app.nexora.nexora

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The message in flight in each conversation, shared by the two Flutter
 * engines of the process (full app and bubble): a window cannot send while
 * the other waits for its answer. Memory only: a new process starts free. A
 * window that closes releases its turns; a turn older than the client's own
 * deadline (150 s) expires.
 */
object SessionHub {
    private const val MAX_TURN_MS = 180_000L

    private data class Turn(val owner: String, val text: String, val since: Long)

    private val turns = HashMap<String, Turn>()
    private val windows = HashMap<MethodChannel, String>()
    private val main = Handler(Looper.getMainLooper())

    /** Called by each activity for its engine; [owner] is `app` or `bubble`. */
    fun attach(messenger: BinaryMessenger, owner: String): MethodChannel {
        val channel = MethodChannel(messenger, "app.nexora/session")
        channel.setMethodCallHandler { call, result ->
            val conversation = call.argument<String>("conversation") ?: ""
            when (call.method) {
                "begin" -> result.success(
                    begin(conversation, call.argument<String>("owner") ?: owner, call.argument<String>("text") ?: ""),
                )
                "end" -> {
                    end(conversation, call.argument<String>("owner") ?: owner)
                    result.success(null)
                }
                "inFlight" -> result.success(
                    current(conversation)?.let { mapOf("owner" to it.owner, "text" to it.text) },
                )
                else -> result.notImplemented()
            }
        }
        synchronized(this) { windows[channel] = owner }
        return channel
    }

    fun detach(channel: MethodChannel) {
        channel.setMethodCallHandler(null)
        val released = synchronized(this) {
            val owner = windows.remove(channel) ?: return
            // Another engine of the same window kind may still be open.
            if (windows.containsValue(owner)) return
            val mine = turns.filterValues { it.owner == owner }.keys.toList()
            mine.forEach { turns.remove(it) }
            mine
        }
        released.forEach(::changed)
    }

    private fun current(conversation: String): Turn? = synchronized(this) {
        val turn = turns[conversation] ?: return null
        if (SystemClock.elapsedRealtime() - turn.since > MAX_TURN_MS) {
            turns.remove(conversation)
            return null
        }
        turn
    }

    private fun begin(conversation: String, owner: String, text: String): Boolean {
        synchronized(this) {
            if (current(conversation) != null) return false
            turns[conversation] = Turn(owner, text, SystemClock.elapsedRealtime())
        }
        changed(conversation)
        return true
    }

    private fun end(conversation: String, owner: String) {
        synchronized(this) {
            if (turns[conversation]?.owner != owner) return
            turns.remove(conversation)
        }
        changed(conversation)
    }

    private fun changed(conversation: String) {
        main.post {
            val channels = synchronized(this) { windows.keys.toList() }
            channels.forEach { it.invokeMethod("changed", conversation) }
        }
    }
}

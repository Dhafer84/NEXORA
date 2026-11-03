package app.nexora.nexora

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The mini-chat shown inside the Android bubble: a second Flutter engine
 * running `bubbleMain` in the same process as the full app, so both share the
 * secure key store, the drafts and [SessionHub].
 */
class BubbleActivity : FlutterActivity() {
    private var voice: VoiceBridge? = null
    private var bubble: BubbleBridge? = null
    private var session: MethodChannel? = null

    override fun getDartEntrypointFunctionName(): String = "bubbleMain"

    /**
     * Back on the mini-chat's last screen. Finishing the activity would make
     * Android remove the whole bubble, so it only goes to the back (Android
     * 11-13). From Android 14 the manifest lets the system handle that Back
     * itself, which collapses the bubble to its icon.
     */
    override fun popSystemNavigator(): Boolean {
        moveTaskToBack(true)
        return true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        voice = VoiceBridge(this, messenger)
        bubble = BubbleBridge(this, messenger, inBubble = true)
        session = SessionHub.attach(messenger, "bubble")
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (voice?.onPermissionResult(requestCode, grantResults) != true) {
            bubble?.onPermissionResult(requestCode)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        voice?.dispose()
        bubble?.dispose()
        session?.let(SessionHub::detach)
        voice = null
        bubble = null
        session = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

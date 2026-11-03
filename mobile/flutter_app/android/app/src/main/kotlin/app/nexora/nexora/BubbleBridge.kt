package app.nexora.nexora

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.Intent
import android.content.LocusId
import android.content.pm.PackageManager
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The NEXORA conversation bubble (Android 11+): a conversation notification
 * whose bubble opens [BubbleActivity], the mini-chat. No "display over other
 * apps" permission: Android draws and places the bubble. The launcher shortcut
 * "Chat NEXORA" opens the full app on the chat where bubbles are unavailable.
 * The notification carries no server data.
 */
class BubbleBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val inBubble: Boolean,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "app.nexora/bubble")
    private val notifications = activity.getSystemService(NotificationManager::class.java)
    private var initialLaunch: Map<String, String?>? = if (inBubble) null else launchArgs(activity.intent)
    private var pendingShow: (() -> Unit)? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(status())
            "show" -> show(
                call.argument<String>("conversation") ?: "",
                call.argument<Boolean>("expand") == true,
                result,
            )
            "hide" -> {
                notifications.cancel(NOTIFICATION_ID)
                result.success(null)
            }
            "openSettings" -> {
                openBubbleSettings()
                result.success(null)
            }
            "pinShortcut" -> result.success(pinShortcut())
            "bubbleConversation" -> result.success(
                if (inBubble) activity.intent?.getStringExtra(EXTRA_CONVERSATION) else null,
            )
            "openFullScreen" -> {
                openFullScreen(call.argument<String>("conversation"), call.argument<String>("approval"))
                result.success(null)
            }
            "initialLaunch" -> {
                result.success(initialLaunch)
                initialLaunch = null
            }
            else -> result.notImplemented()
        }
    }

    /** New intent on the full app (shortcut, mini-chat "full screen"). */
    fun onNewIntent(intent: Intent) {
        launchArgs(intent)?.let { channel.invokeMethod("launch", it) }
    }

    // ----- Status -----------------------------------------------------------------

    private fun status(): Map<String, Any> {
        val active = notifications.activeNotifications.firstOrNull { it.id == NOTIFICATION_ID }
        val bubbled = active != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            (active.notification.flags and Notification.FLAG_BUBBLE) != 0
        return mapOf(
            "availability" to availability(),
            "shown" to (active != null),
            "bubbled" to bubbled,
        )
    }

    private fun availability(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return "unsupported"
        if (!notifications.areNotificationsEnabled()) return "notifications_blocked"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!notifications.areBubblesEnabled()) return "blocked"
            return when (notifications.bubblePreference) {
                NotificationManager.BUBBLE_PREFERENCE_ALL -> "allowed"
                NotificationManager.BUBBLE_PREFERENCE_SELECTED -> "selected"
                // Also Android's default for a newly installed app.
                else -> "not_allowed"
            }
        }
        @Suppress("DEPRECATION")
        return if (notifications.areBubblesAllowed()) "allowed" else "not_allowed"
    }

    // ----- Bubble -----------------------------------------------------------------

    private fun show(conversation: String, expand: Boolean, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            result.success("Les bulles demandent Android 11 ou plus. Utilisez le raccourci « Chat NEXORA ».")
            return
        }
        if (conversation.isEmpty()) {
            result.success("Aucune discussion à ouvrir.")
            return
        }
        val post = {
            if (!notifications.areNotificationsEnabled()) {
                result.success("Notifications refusées : autorisez-les pour NEXORA afin d’afficher la bulle.")
            } else {
                post(conversation, expand)
                result.success(null)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            pendingShow = post
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
            return
        }
        post()
    }

    /** Forwarded by the activity. Returns true when the request was ours. */
    fun onPermissionResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_NOTIFICATIONS) return false
        pendingShow?.invoke()
        pendingShow = null
        return true
    }

    private fun post(conversation: String, expand: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val context: Context = activity.applicationContext
        val channel = NotificationChannel(CHANNEL_ID, "Mini-chat NEXORA", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Bulle de conversation avec NEXORA. Aucun son, aucun contenu du serveur."
            setSound(null, null)
            enableVibration(false)
            setAllowBubbles(true)
        }
        notifications.createNotificationChannel(channel)
        val icon = Icon.createWithResource(context, R.mipmap.ic_nexora_bubble)
        // Not marked as a bot: Android never bubbles a conversation made only of bots.
        val nexora = Person.Builder().setName("NEXORA").setIcon(icon).setImportant(true).build()
        context.getSystemService(ShortcutManager::class.java).pushDynamicShortcut(shortcut(context, conversation))

        val bubbleIntent = Intent(context, BubbleActivity::class.java)
            .setAction(Intent.ACTION_VIEW)
            .setData(Uri.parse("nexora://chat/$conversation"))
            .putExtra(EXTRA_CONVERSATION, conversation)
        // Mutable: required by Android for the activity shown in a bubble.
        val bubble = PendingIntent.getActivity(
            context, 0, bubbleIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        val openApp = PendingIntent.getActivity(
            context, 1, appIntent(context, conversation, null), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val metadata = Notification.BubbleMetadata.Builder(bubble, icon)
            .setDesiredHeight(640)
            .setAutoExpandBubble(expand)
            .setSuppressNotification(true)
            .build()
        val me = Person.Builder().setName("Moi").build()
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_nexora_chat)
            .setContentTitle("NEXORA")
            .setContentText("Touchez la bulle pour discuter avec NEXORA.")
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setShortcutId(SHORTCUT_ID)
            .setLocusId(LocusId(SHORTCUT_ID))
            .setStyle(
                Notification.MessagingStyle(me).addMessage(
                    Notification.MessagingStyle.Message(
                        "Touchez la bulle pour discuter avec NEXORA.",
                        System.currentTimeMillis(),
                        nexora,
                    ),
                ),
            )
            .setBubbleMetadata(metadata)
            .setContentIntent(openApp)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .build()
        notifications.notify(NOTIFICATION_ID, notification)
    }

    private fun shortcut(context: Context, conversation: String?): ShortcutInfo {
        val icon = Icon.createWithResource(context, R.mipmap.ic_nexora_bubble)
        val builder = ShortcutInfo.Builder(context, SHORTCUT_ID)
            .setShortLabel("Chat NEXORA")
            .setLongLabel("Discuter avec NEXORA")
            .setIcon(icon)
            .setIntent(appIntent(context, conversation, null))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setLongLived(true)
                .setLocusId(LocusId(SHORTCUT_ID))
                .setPerson(Person.Builder().setName("NEXORA").setIcon(icon).build())
        }
        return builder.build()
    }

    private fun pinShortcut(): Boolean {
        val manager = activity.getSystemService(ShortcutManager::class.java)
        if (!manager.isRequestPinShortcutSupported) return false
        return manager.requestPinShortcut(shortcut(activity.applicationContext, null), null)
    }

    private fun openBubbleSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Intent(Settings.ACTION_APP_NOTIFICATION_BUBBLE_SETTINGS)
        } else {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
        }
        activity.startActivity(intent.putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName))
    }

    // ----- Full screen ------------------------------------------------------------

    private fun openFullScreen(conversation: String?, approval: String?) {
        activity.startActivity(
            appIntent(activity, conversation?.ifEmpty { null }, approval)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        )
        // Android collapses the bubble when the full app comes to the front.
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    companion object {
        private const val CHANNEL_ID = "nexora_minichat"
        private const val SHORTCUT_ID = "nexora_chat"
        private const val NOTIFICATION_ID = 7001
        private const val REQUEST_NOTIFICATIONS = 4311
        const val EXTRA_CONVERSATION = "app.nexora.conversation"
        const val EXTRA_APPROVAL = "app.nexora.approval"

        fun appIntent(context: Context, conversation: String?, approval: String?): Intent =
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .putExtra(EXTRA_CONVERSATION, conversation)
                .putExtra(EXTRA_APPROVAL, approval)

        fun launchArgs(intent: Intent?): Map<String, String?>? {
            val conversation = intent?.getStringExtra(EXTRA_CONVERSATION)
            val approval = intent?.getStringExtra(EXTRA_APPROVAL)
            if (conversation == null && approval == null) return null
            return mapOf("conversation" to conversation, "approval" to approval)
        }
    }
}

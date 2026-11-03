package app.nexora.nexora

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

/**
 * Dictation and reading aloud with the phone's own services, for one Flutter
 * engine. One utterance per tap: no continuous listening, nothing recorded in
 * the background, no audio file. Recognition runs on the device when Android
 * offers it for French; the phone's default service (which may send the audio
 * to its publisher) is used only when the Dart side passes `remote`, i.e. after
 * the user enabled it. Only offline French voices are used for reading.
 */
class VoiceBridge(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methods = MethodChannel(messenger, "app.nexora/voice")
    private val events = EventChannel(messenger, "app.nexora/voice/events")
    private var sink: EventChannel.EventSink? = null

    private var recognizer: SpeechRecognizer? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var frenchOnDevice: Boolean? = null

    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var ttsOutput = "unavailable"
    private val ttsWaiting = mutableListOf<() -> Unit>()
    private var speakingId: String? = null

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(vararg values: Pair<String, Any?>) {
        activity.runOnUiThread { sink?.success(mapOf(*values)) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> capabilities(result)
            "requestMicrophone" -> requestMicrophone(result)
            "startListening" -> {
                startListening(call.argument<Boolean>("remote") == true)
                result.success(null)
            }
            "stopListening" -> {
                recognizer?.stopListening()
                result.success(null)
            }
            "cancelListening" -> {
                releaseRecognizer()
                result.success(null)
            }
            "speak" -> {
                speak(call.argument<String>("id") ?: "", call.argument<String>("text") ?: "")
                result.success(null)
            }
            "stopSpeaking" -> {
                stopSpeaking()
                result.success(null)
            }
            "openAppSettings" -> {
                activity.startActivity(
                    Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", activity.packageName, null),
                    ),
                )
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ----- Capabilities ---------------------------------------------------------

    private fun capabilities(result: MethodChannel.Result) {
        checkFrenchOnDevice {
            withTts {
                result.success(
                    mapOf(
                        "recognition" to recognitionMode(),
                        "service" to recognitionServiceName(),
                        "output" to ttsOutput,
                        "engine" to engineName(),
                    ),
                )
            }
        }
    }

    private fun onDeviceAvailable(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)

    private fun recognitionMode(): String = when {
        onDeviceAvailable() && frenchOnDevice != false -> "on_device"
        SpeechRecognizer.isRecognitionAvailable(activity) -> "remote"
        else -> "unavailable"
    }

    /** Android 13+: is French installed for on-device recognition? */
    private fun checkFrenchOnDevice(then: () -> Unit) {
        if (frenchOnDevice != null || !onDeviceAvailable() ||
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU
        ) {
            then()
            return
        }
        val probe = SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
        probe.checkRecognitionSupport(
            recognitionIntent(remote = false),
            activity.mainExecutor,
            object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    frenchOnDevice = support.installedOnDeviceLanguages.any { it.startsWith("fr") }
                    probe.destroy()
                    then()
                }

                override fun onError(error: Int) {
                    frenchOnDevice = false
                    probe.destroy()
                    then()
                }
            },
        )
    }

    private fun recognitionServiceName(): String? {
        val pm = activity.packageManager
        val configured = Settings.Secure.getString(activity.contentResolver, "voice_recognition_service")
            ?.let { ComponentName.unflattenFromString(it)?.packageName }
        val name = configured ?: pm.queryIntentServices(Intent(RecognitionService.SERVICE_INTERFACE), 0)
            .firstOrNull()?.serviceInfo?.packageName
        return name?.let { label(it) }
    }

    private fun engineName(): String? = tts?.defaultEngine?.let { label(it) }

    private fun label(packageName: String): String = try {
        val pm = activity.packageManager
        pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
    } catch (error: PackageManager.NameNotFoundException) {
        packageName
    }

    // ----- Microphone -------------------------------------------------------------

    private fun requestMicrophone(result: MethodChannel.Result) {
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            result.success("granted")
            return
        }
        if (pendingPermission != null) {
            result.success("denied")
            return
        }
        pendingPermission = result
        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MICROPHONE)
    }

    /** Forwarded by the activity. Returns true when the request was ours. */
    fun onPermissionResult(requestCode: Int, grants: IntArray): Boolean {
        if (requestCode != REQUEST_MICROPHONE) return false
        val result = pendingPermission ?: return true
        pendingPermission = null
        result.success(
            when {
                grants.firstOrNull() == PackageManager.PERMISSION_GRANTED -> "granted"
                // Refused with "don't ask again" (or twice): only the settings can change it.
                !activity.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) ->
                    "permanently_denied"
                else -> "denied"
            },
        )
        return true
    }

    // ----- Recognition ------------------------------------------------------------

    private fun recognitionIntent(remote: Boolean) = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, "fr-FR")
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
        if (!remote) putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
    }

    private fun startListening(remote: Boolean) {
        releaseRecognizer()
        // NEXORA's own voice must not be transcribed.
        stopSpeaking()
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            emit("type" to "error", "code" to "permission")
            return
        }
        val created = when {
            !remote && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                SpeechRecognizer.isOnDeviceRecognitionAvailable(activity) ->
                SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
            remote && SpeechRecognizer.isRecognitionAvailable(activity) ->
                SpeechRecognizer.createSpeechRecognizer(activity)
            else -> null
        }
        if (created == null) {
            emit("type" to "error", "code" to "unavailable")
            return
        }
        recognizer = created
        created.setRecognitionListener(Listener(created))
        created.startListening(recognitionIntent(remote))
    }

    private fun releaseRecognizer() {
        recognizer?.let {
            it.cancel()
            it.destroy()
        }
        recognizer = null
    }

    private inner class Listener(private val owner: SpeechRecognizer) : RecognitionListener {
        private fun current() = recognizer === owner

        override fun onReadyForSpeech(params: Bundle?) {
            if (current()) emit("type" to "listening")
        }

        override fun onPartialResults(partialResults: Bundle?) {
            if (!current()) return
            val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
            if (!text.isNullOrBlank()) emit("type" to "partial", "text" to text)
        }

        override fun onResults(results: Bundle?) {
            if (!current()) return
            val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""
            releaseRecognizer()
            emit("type" to "final", "text" to text)
        }

        override fun onError(error: Int) {
            if (!current()) return
            releaseRecognizer()
            emit("type" to "error", "code" to errorCode(error))
        }

        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun errorCode(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_NO_MATCH -> "no_match"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "speech_timeout"
        SpeechRecognizer.ERROR_NETWORK,
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT,
        SpeechRecognizer.ERROR_SERVER,
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "network"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY,
        SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> "busy"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "permission"
        SpeechRecognizer.ERROR_AUDIO -> "audio"
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED,
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "language"
        else -> "client"
    }

    // ----- Reading aloud ----------------------------------------------------------

    private fun withTts(then: () -> Unit) {
        if (ttsReady) {
            then()
            return
        }
        ttsWaiting += then
        if (tts != null) return
        tts = TextToSpeech(activity.applicationContext) { status ->
            activity.runOnUiThread {
                if (status == TextToSpeech.SUCCESS) configureTts() else ttsOutput = "unavailable"
                ttsReady = true
                val waiting = ttsWaiting.toList()
                ttsWaiting.clear()
                waiting.forEach { it() }
            }
        }
    }

    private fun configureTts() {
        val engine = tts ?: return
        val french = (engine.voices ?: emptySet<Voice>()).filter { it.locale.language == "fr" }
        val offline = french.filter {
            !it.isNetworkConnectionRequired &&
                !it.features.contains(TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED)
        }
        val voice = offline.firstOrNull { it.locale.country == "FR" } ?: offline.firstOrNull()
        ttsOutput = when {
            voice != null -> {
                engine.voice = voice
                "offline"
            }
            french.isNotEmpty() -> "network_only"
            else -> "unavailable"
        }
        engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String) = emit("type" to "speak_start", "id" to utteranceId)
            override fun onDone(utteranceId: String) = ended(utteranceId)

            @Deprecated("Required override")
            override fun onError(utteranceId: String) = ended(utteranceId)
            override fun onStop(utteranceId: String, interrupted: Boolean) = ended(utteranceId)
        })
    }

    private fun ended(id: String) {
        if (speakingId == id) speakingId = null
        emit("type" to "speak_end", "id" to id)
    }

    private fun speak(id: String, text: String) {
        withTts {
            val engine = tts
            if (engine == null || ttsOutput != "offline" || recognizer != null) {
                emit("type" to "speak_end", "id" to id)
                return@withTts
            }
            speakingId = id
            val limit = TextToSpeech.getMaxSpeechInputLength()
            engine.speak(text.take(limit), TextToSpeech.QUEUE_FLUSH, Bundle(), id)
        }
    }

    private fun stopSpeaking() {
        val id = speakingId ?: return
        tts?.stop()
        ended(id)
    }

    fun dispose() {
        releaseRecognizer()
        pendingPermission?.success("denied")
        pendingPermission = null
        tts?.stop()
        tts?.shutdown()
        tts = null
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }

    companion object {
        private const val REQUEST_MICROPHONE = 4310
    }
}

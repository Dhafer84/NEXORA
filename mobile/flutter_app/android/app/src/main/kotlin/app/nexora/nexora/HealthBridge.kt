package app.nexora.nexora

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.Build
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.HealthConnectFeatures
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.metadata.Device
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import kotlin.reflect.KClass

/**
 * Local Health Connect diagnostic (prototype of step 5): reads one finished
 * day of steps, sleep, heart rate or workouts, with one read permission per
 * category. Values only go to the Dart screen of this device: nothing is
 * logged, stored or sent to the NEXORA server or the AI provider.
 */
class HealthBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "app.nexora/health")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var pendingRequest: Pair<String, MethodChannel.Result>? = null

    init {
        channel.setMethodCallHandler(this)
    }

    private fun sdkStatus(): Int = HealthConnectClient.getSdkStatus(activity)

    private val client: HealthConnectClient by lazy { HealthConnectClient.getOrCreate(activity) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> run(result) { status() }
            "request" -> request(call.argument<String>("category") ?: "", result)
            "read" -> run(result) {
                read(call.argument<String>("category") ?: "", LocalDate.parse(call.argument<String>("day")))
            }
            "oldest" -> run(result) { oldest(call.argument<String>("category") ?: "") }
            "openSettings" -> {
                openSettings()
                result.success(null)
            }
            "writeSamples" -> run(result) { writeSamples(LocalDate.parse(call.argument<String>("day"))) }
            else -> result.notImplemented()
        }
    }

    /** Runs [work] off the call; Health Connect errors become channel errors without values. */
    private fun run(result: MethodChannel.Result, work: suspend () -> Any?) {
        scope.launch {
            try {
                result.success(work())
            } catch (error: SecurityException) {
                result.error("permission_denied", "Lecture non autorisée", null)
            } catch (error: IllegalStateException) {
                result.error("unavailable", "Health Connect indisponible", null)
            } catch (error: Exception) {
                result.error("failed", error.javaClass.simpleName, null)
            }
        }
    }

    // ----- Availability and permissions ----------------------------------------

    private suspend fun status(): Map<String, Any?> {
        val zone = ZoneId.systemDefault()
        val base = mapOf(
            "zone" to zone.id,
            "offset" to zone.rules.getOffset(Instant.now()).id,
            "debugSamples" to debuggable(),
        )
        val sdk = when (sdkStatus()) {
            HealthConnectClient.SDK_AVAILABLE -> "available"
            HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> "update_required"
            else -> "unavailable"
        }
        if (sdk != "available") return base + mapOf("sdk" to sdk)
        val granted = client.permissionController.getGrantedPermissions()
        val history = client.features.getFeatureStatus(HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_HISTORY) ==
            HealthConnectFeatures.FEATURE_STATUS_AVAILABLE
        return base + mapOf(
            "sdk" to sdk,
            "granted" to CATEGORIES.filter { (_, type) -> HealthPermission.getReadPermission(type) in granted }.keys.toList(),
            "historyFeature" to history,
            "historyGranted" to (HealthPermission.PERMISSION_READ_HEALTH_DATA_HISTORY in granted),
        )
    }

    private fun request(category: String, result: MethodChannel.Result) {
        val type = CATEGORIES[category] ?: return result.error("invalid", "Catégorie inconnue", null)
        if (sdkStatus() != HealthConnectClient.SDK_AVAILABLE) {
            return result.error("unavailable", "Health Connect indisponible", null)
        }
        if (pendingRequest != null) return result.error("busy", "Demande déjà en cours", null)
        pendingRequest = category to result
        if (!askPermissions(setOf(HealthPermission.getReadPermission(type)), REQUEST_PERMISSION)) {
            pendingRequest = null
            result.error("unavailable", "Écran des autorisations introuvable", null)
        }
    }

    /**
     * Shows Health Connect's permission screen. Android 14+ holds the health
     * permissions itself: they are requested like any runtime permission (the
     * library's contract relies on a ComponentActivity there, which
     * FlutterActivity is not). Before, the contract's intent opens the
     * Health Connect app. Returns false when no screen could be opened.
     */
    private fun askPermissions(permissions: Set<String>, requestCode: Int): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            activity.requestPermissions(permissions.toTypedArray(), requestCode)
            return true
        }
        return try {
            val contract = PermissionController.createRequestPermissionResultContract()
            activity.startActivityForResult(contract.createIntent(activity, permissions), requestCode)
            true
        } catch (error: ActivityNotFoundException) {
            false
        }
    }

    /** Forwarded by the activity (activity or permission result). Returns true when it was ours. */
    fun onActivityResult(requestCode: Int): Boolean {
        if (requestCode == REQUEST_WRITE) return true
        if (requestCode != REQUEST_PERMISSION) return false
        val (category, result) = pendingRequest ?: return true
        pendingRequest = null
        run(result) {
            HealthPermission.getReadPermission(CATEGORIES.getValue(category)) in
                client.permissionController.getGrantedPermissions()
        }
        return true
    }

    private fun openSettings() {
        val intent = if (sdkStatus() == HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED) {
            Intent(Intent.ACTION_VIEW, Uri.parse(PLAY_STORE)).setPackage("com.android.vending")
        } else {
            Intent(HealthConnectClient.ACTION_HEALTH_CONNECT_SETTINGS)
        }
        try {
            activity.startActivity(intent)
        } catch (error: Exception) {
            activity.startActivity(Intent(android.provider.Settings.ACTION_SETTINGS))
        }
    }

    // ----- Reading --------------------------------------------------------------

    private suspend fun read(category: String, day: LocalDate): Map<String, Any?> {
        val zone = ZoneId.systemDefault()
        val start = day.atStartOfDay(zone).toInstant()
        val end = day.plusDays(1).atStartOfDay(zone).toInstant()
        val range = TimeRangeFilter.between(start, end)
        val common = mapOf("zone" to zone.id, "start" to start.toEpochMilli(), "end" to end.toEpochMilli())
        return common + when (category) {
            "steps" -> {
                val (records, truncated) = readAll<StepsRecord>(range)
                val total = client.aggregate(AggregateRequest(setOf(StepsRecord.COUNT_TOTAL), range))
                mapOf(
                    "total" to total[StepsRecord.COUNT_TOTAL],
                    "totalOrigins" to total.dataOrigins.map { it.packageName },
                    "truncated" to truncated,
                    "entries" to records.map {
                        entry(it.metadata, it.startTime, it.endTime, it.startZoneOffset) + ("value" to it.count)
                    },
                )
            }
            "sleep" -> {
                // The night that ends on this day: sessions ending between 00:00 and 24:00.
                val (records, truncated) = readAll<SleepSessionRecord>(
                    TimeRangeFilter.between(start.minus(Duration.ofDays(1)), end),
                )
                mapOf(
                    "truncated" to truncated,
                    "entries" to records.filter { !it.endTime.isBefore(start) && it.endTime.isBefore(end) }.map {
                        entry(it.metadata, it.startTime, it.endTime, it.startZoneOffset) + mapOf(
                            "value" to Duration.between(it.startTime, it.endTime).toMinutes(),
                            "stages" to it.stages.groupBy { stage -> stage.stage }.mapKeys { (k, _) -> k.toString() }
                                .mapValues { (_, stages) ->
                                    stages.sumOf { s -> Duration.between(s.startTime, s.endTime).toMinutes() }
                                },
                        )
                    },
                )
            }
            "heart_rate" -> {
                val (records, truncated) = readAll<HeartRateRecord>(range)
                val stats = client.aggregate(
                    AggregateRequest(
                        setOf(
                            HeartRateRecord.BPM_MIN,
                            HeartRateRecord.BPM_MAX,
                            HeartRateRecord.BPM_AVG,
                            HeartRateRecord.MEASUREMENTS_COUNT,
                        ),
                        range,
                    ),
                )
                mapOf(
                    "min" to stats[HeartRateRecord.BPM_MIN],
                    "max" to stats[HeartRateRecord.BPM_MAX],
                    "avg" to stats[HeartRateRecord.BPM_AVG],
                    "count" to stats[HeartRateRecord.MEASUREMENTS_COUNT],
                    "truncated" to truncated,
                    "entries" to records.map {
                        entry(it.metadata, it.startTime, it.endTime, it.startZoneOffset) + mapOf(
                            "value" to it.samples.size.toLong(),
                            "min" to it.samples.minOfOrNull { s -> s.beatsPerMinute },
                            "max" to it.samples.maxOfOrNull { s -> s.beatsPerMinute },
                        )
                    },
                )
            }
            "exercise" -> {
                val (records, truncated) = readAll<ExerciseSessionRecord>(range)
                mapOf(
                    "truncated" to truncated,
                    // Titles and notes are not read: the type and duration are enough here.
                    "entries" to records.map {
                        entry(it.metadata, it.startTime, it.endTime, it.startZoneOffset) + mapOf(
                            "value" to Duration.between(it.startTime, it.endTime).toMinutes(),
                            "exerciseType" to it.exerciseType,
                        )
                    },
                )
            }
            else -> throw IllegalArgumentException(category)
        }
    }

    /** Start of the oldest readable entry: the history depth Health Connect grants. */
    private suspend fun oldest(category: String): Long? {
        val range = TimeRangeFilter.between(Instant.parse("2000-01-01T00:00:00Z"), Instant.now())
        val start = when (category) {
            "steps" -> first<StepsRecord>(range)?.startTime
            "sleep" -> first<SleepSessionRecord>(range)?.startTime
            "heart_rate" -> first<HeartRateRecord>(range)?.startTime
            "exercise" -> first<ExerciseSessionRecord>(range)?.startTime
            else -> throw IllegalArgumentException(category)
        }
        return start?.toEpochMilli()
    }

    private suspend inline fun <reified T : Record> first(range: TimeRangeFilter): T? =
        client.readRecords(ReadRecordsRequest<T>(range, ascendingOrder = true, pageSize = 1)).records.firstOrNull()

    private suspend inline fun <reified T : Record> readAll(range: TimeRangeFilter): Pair<List<T>, Boolean> {
        val records = mutableListOf<T>()
        var token: String? = null
        do {
            val page = client.readRecords(ReadRecordsRequest<T>(range, pageToken = token))
            records += page.records
            token = page.pageToken
        } while (token != null && records.size < MAX_RECORDS)
        return records to (token != null)
    }

    private fun entry(meta: Metadata, start: Instant, end: Instant, offset: ZoneOffset?): Map<String, Any?> = mapOf(
        "origin" to meta.dataOrigin.packageName,
        "start" to start.toEpochMilli(),
        "end" to end.toEpochMilli(),
        "offset" to offset?.totalSeconds,
        "deviceType" to meta.device?.type,
        "manufacturer" to meta.device?.manufacturer,
        "model" to meta.device?.model,
        "method" to meta.recordingMethod,
    )

    // ----- Debug builds only: sample data for the emulator ------------------------

    private fun debuggable() = (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    /**
     * Writes a few entries of NEXORA itself for [day] so the screen can be tried
     * on an emulator. The write permissions only exist in the debug manifest.
     */
    private suspend fun writeSamples(day: LocalDate): Int {
        if (!debuggable()) throw SecurityException("debug only")
        val writes = setOf(
            HealthPermission.getWritePermission(StepsRecord::class),
            HealthPermission.getWritePermission(SleepSessionRecord::class),
            HealthPermission.getWritePermission(HeartRateRecord::class),
            HealthPermission.getWritePermission(ExerciseSessionRecord::class),
        )
        val granted = client.permissionController.getGrantedPermissions()
        if (!granted.containsAll(writes)) {
            askPermissions(writes, REQUEST_WRITE)
            return -1
        }
        val zone = ZoneId.systemDefault()
        val at = { hour: Long, minute: Long -> day.atStartOfDay(zone).toInstant().plus(Duration.ofMinutes(hour * 60 + minute)) }
        val offset = zone.rules.getOffset(at(12, 0))
        val phone = Metadata.autoRecorded(Device(type = Device.TYPE_PHONE, manufacturer = "Essai", model = "Téléphone"))
        val watch = Metadata.autoRecorded(Device(type = Device.TYPE_WATCH, manufacturer = "Essai", model = "Montre"))
        val records = listOf(
            StepsRecord(at(8, 0), offset, at(9, 0), offset, 1200, phone),
            StepsRecord(at(8, 0), offset, at(9, 0), offset, 1350, watch),
            StepsRecord(at(18, 0), offset, at(18, 30), offset, 800, watch),
            SleepSessionRecord(
                at(-2, 0), offset, at(6, 30), offset, watch,
                stages = listOf(
                    SleepSessionRecord.Stage(at(-2, 0), at(1, 0), SleepSessionRecord.STAGE_TYPE_LIGHT),
                    SleepSessionRecord.Stage(at(1, 0), at(3, 0), SleepSessionRecord.STAGE_TYPE_DEEP),
                    SleepSessionRecord.Stage(at(3, 0), at(6, 30), SleepSessionRecord.STAGE_TYPE_REM),
                ),
            ),
            HeartRateRecord(
                at(10, 0), offset, at(10, 3), offset,
                listOf(
                    HeartRateRecord.Sample(at(10, 0), 62),
                    HeartRateRecord.Sample(at(10, 1), 71),
                    HeartRateRecord.Sample(at(10, 2), 88),
                ),
                watch,
            ),
            ExerciseSessionRecord(
                startTime = at(18, 0), startZoneOffset = offset, endTime = at(18, 30), endZoneOffset = offset,
                metadata = watch, exerciseType = ExerciseSessionRecord.EXERCISE_TYPE_WALKING,
            ),
        )
        client.insertRecords(records)
        return records.size
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    companion object {
        private const val REQUEST_PERMISSION = 4320
        private const val REQUEST_WRITE = 4321
        private const val MAX_RECORDS = 20_000
        private const val PLAY_STORE =
            "market://details?id=com.google.android.apps.healthdata&url=healthconnect%3A%2F%2Fonboarding"

        private val CATEGORIES: Map<String, KClass<out Record>> = mapOf(
            "steps" to StepsRecord::class,
            "sleep" to SleepSessionRecord::class,
            "heart_rate" to HeartRateRecord::class,
            "exercise" to ExerciseSessionRecord::class,
        )
    }
}

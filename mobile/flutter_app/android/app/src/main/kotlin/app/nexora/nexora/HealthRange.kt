package app.nexora.nexora

import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.metadata.DataOrigin
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.AggregateGroupByPeriodRequest
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.Period
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * Activity module (step 6): several days of one category, bucketed by local
 * day of the phone's time zone. Days are cut with local date-times, so a
 * 23 h or 25 h day at a clock change stays one day. Everything is read again
 * on each refresh: updated or deleted records are reflected, and the same
 * records always give the same figures. Values only go back to Dart.
 */
class HealthRange(private val client: HealthConnectClient) {

    private val zone: ZoneId = ZoneId.systemDefault()

    suspend fun read(category: String, from: LocalDate, to: LocalDate): Map<String, Any?> {
        val common = mapOf(
            "zone" to zone.id,
            "from" to from.toString(),
            "to" to to.toString(),
            "readAt" to System.currentTimeMillis(),
        )
        return common + when (category) {
            "steps" -> steps(from, to)
            "sleep" -> sleep(from, to)
            "heart_rate" -> heartRate(from, to)
            "exercise" -> exercise(from, to)
            else -> throw IllegalArgumentException(category)
        }
    }

    private fun localRange(from: LocalDate, to: LocalDate) =
        TimeRangeFilter.between(from.atStartOfDay(), to.plusDays(1).atStartOfDay())

    private fun instantRange(from: LocalDate, to: LocalDate) =
        TimeRangeFilter.between(from.atStartOfDay(zone).toInstant(), to.plusDays(1).atStartOfDay(zone).toInstant())

    private fun date(instant: Instant): String = instant.atZone(zone).toLocalDate().toString()

    private fun local(instant: Instant): String = instant.atZone(zone).format(LOCAL)

    // ----- Steps -------------------------------------------------------------------

    private suspend fun steps(from: LocalDate, to: LocalDate): Map<String, Any?> {
        val range = localRange(from, to)
        // Health Connect's own total: overlapping sources counted once, by its priority order.
        val all = dailySteps(range, emptySet())
        val origins = client.aggregate(AggregateRequest(setOf(StepsRecord.COUNT_TOTAL), range)).dataOrigins
        return mapOf(
            "days" to all,
            "origins" to origins.map { origin ->
                val latest = client.readRecords(
                    ReadRecordsRequest<StepsRecord>(
                        range, dataOriginFilter = setOf(origin), ascendingOrder = false, pageSize = DEVICE_SAMPLE,
                    ),
                ).records
                mapOf(
                    "origin" to origin.packageName,
                    "days" to dailySteps(range, setOf(origin)),
                    "devices" to devices(latest.map { it.metadata }),
                    "lastEndLocal" to latest.maxOfOrNull { it.endTime }?.let { local(it) },
                )
            },
        )
    }

    private suspend fun dailySteps(range: TimeRangeFilter, origins: Set<DataOrigin>): List<Map<String, Any?>> =
        client.aggregateGroupByPeriod(
            AggregateGroupByPeriodRequest(setOf(StepsRecord.COUNT_TOTAL), range, Period.ofDays(1), origins),
        ).mapNotNull { bucket ->
            bucket.result[StepsRecord.COUNT_TOTAL]?.let {
                mapOf("date" to bucket.startTime.toLocalDate().toString(), "value" to it)
            }
        }

    // ----- Sleep -------------------------------------------------------------------

    private suspend fun sleep(from: LocalDate, to: LocalDate): Map<String, Any?> {
        // A night belongs to the day it ends (wake-up day): read one day before.
        val (records, truncated) = readAll<SleepSessionRecord>(instantRange(from.minusDays(1), to))
        val first = from.toString()
        val last = to.toString()
        return mapOf(
            "truncated" to truncated,
            "sessions" to records.filter { date(it.endTime) in first..last }.map {
                source(it.metadata) + mapOf(
                    "start" to it.startTime.toEpochMilli(),
                    "end" to it.endTime.toEpochMilli(),
                    "startLocal" to local(it.startTime),
                    "endLocal" to local(it.endTime),
                    "date" to date(it.endTime),
                    "stages" to it.stages.groupBy { stage -> stage.stage }.mapKeys { (k, _) -> k.toString() }
                        .mapValues { (_, stages) ->
                            stages.sumOf { s -> Duration.between(s.startTime, s.endTime).toMinutes() }
                        },
                )
            },
        )
    }

    // ----- Heart rate --------------------------------------------------------------

    private class Bucket {
        var count = 0L
        var sum = 0L
        var min = Long.MAX_VALUE
        var max = Long.MIN_VALUE
        var hours = 0
    }

    /** Per source and local day, from the samples really present (no interpolation). */
    private suspend fun heartRate(from: LocalDate, to: LocalDate): Map<String, Any?> {
        val buckets = linkedMapOf<Pair<String, String>, Bucket>()
        val metas = mutableMapOf<String, MutableList<Metadata>>()
        val last = mutableMapOf<String, Instant>()
        var token: String? = null
        var samples = 0L
        val range = instantRange(from, to)
        val first = from.toString()
        val end = to.toString()
        do {
            val page = client.readRecords(ReadRecordsRequest<HeartRateRecord>(range, pageToken = token))
            for (record in page.records) {
                val origin = record.metadata.dataOrigin.packageName
                metas.getOrPut(origin) { mutableListOf() }.let { if (it.size < DEVICE_SAMPLE) it += record.metadata }
                for (sample in record.samples) {
                    val at = sample.time.atZone(zone)
                    val day = at.toLocalDate().toString()
                    if (day < first || day > end) continue
                    val bucket = buckets.getOrPut(origin to day) { Bucket() }
                    bucket.count++
                    bucket.sum += sample.beatsPerMinute
                    bucket.min = minOf(bucket.min, sample.beatsPerMinute)
                    bucket.max = maxOf(bucket.max, sample.beatsPerMinute)
                    bucket.hours = bucket.hours or (1 shl at.hour)
                    samples++
                    if (last[origin]?.isBefore(sample.time) != false) last[origin] = sample.time
                }
            }
            token = page.pageToken
        } while (token != null && samples < MAX_SAMPLES)
        return mapOf(
            "truncated" to (token != null),
            "days" to buckets.map { (key, b) ->
                mapOf(
                    "origin" to key.first,
                    "date" to key.second,
                    "count" to b.count,
                    "sum" to b.sum,
                    "min" to b.min,
                    "max" to b.max,
                    "hours" to Integer.bitCount(b.hours),
                )
            },
            "origins" to metas.map { (origin, list) ->
                mapOf("origin" to origin, "devices" to devices(list), "lastEndLocal" to last[origin]?.let { local(it) })
            },
        )
    }

    // ----- Workouts ----------------------------------------------------------------

    private suspend fun exercise(from: LocalDate, to: LocalDate): Map<String, Any?> {
        val (records, truncated) = readAll<ExerciseSessionRecord>(instantRange(from, to))
        val distance = HealthPermission.getReadPermission(DistanceRecord::class) in
            client.permissionController.getGrantedPermissions()
        return mapOf(
            "truncated" to truncated,
            "distanceGranted" to distance,
            // Titles and notes are not read.
            "sessions" to records.map {
                source(it.metadata) + mapOf(
                    "start" to it.startTime.toEpochMilli(),
                    "end" to it.endTime.toEpochMilli(),
                    "startLocal" to local(it.startTime),
                    "endLocal" to local(it.endTime),
                    "date" to date(it.startTime),
                    "exerciseType" to it.exerciseType,
                    // Distance written by the same source over the session, when allowed.
                    "distance" to if (distance) {
                        client.aggregate(
                            AggregateRequest(
                                setOf(DistanceRecord.DISTANCE_TOTAL),
                                TimeRangeFilter.between(it.startTime, it.endTime),
                                setOf(it.metadata.dataOrigin),
                            ),
                        )[DistanceRecord.DISTANCE_TOTAL]?.inMeters
                    } else {
                        null
                    },
                )
            },
        )
    }

    // ----- Helpers -----------------------------------------------------------------

    private suspend inline fun <reified T : androidx.health.connect.client.records.Record> readAll(
        range: TimeRangeFilter,
    ): Pair<List<T>, Boolean> {
        val records = mutableListOf<T>()
        var token: String? = null
        do {
            val page = client.readRecords(ReadRecordsRequest<T>(range, pageToken = token))
            records += page.records
            token = page.pageToken
        } while (token != null && records.size < MAX_RECORDS)
        return records to (token != null)
    }

    private fun source(meta: Metadata): Map<String, Any?> = mapOf(
        "origin" to meta.dataOrigin.packageName,
        "deviceType" to meta.device?.type,
        "manufacturer" to meta.device?.manufacturer,
        "model" to meta.device?.model,
    )

    /** Distinct devices named by the metadata (none when the source gives none). */
    private fun devices(metas: List<Metadata>): List<Map<String, Any?>> =
        metas.map { it.device }.distinct().map {
            mapOf("deviceType" to it?.type, "manufacturer" to it?.manufacturer, "model" to it?.model)
        }

    companion object {
        private const val MAX_RECORDS = 20_000
        private const val MAX_SAMPLES = 500_000L
        private const val DEVICE_SAMPLE = 200
        private val LOCAL: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm")
    }
}

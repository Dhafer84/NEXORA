package app.nexora.nexora

import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.metadata.Device
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.units.Length
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * Synthetic history for the emulator (debug builds only, called after the
 * debuggable check). Deterministic: the same day always gives the same
 * entries, and each one has a client id, so writing again updates instead
 * of duplicating. Some days are left empty on purpose, the phone and the
 * "watch" overlap on some mornings, and one source names no device.
 */
object HealthSamples {

    private val watch = Device(type = Device.TYPE_WATCH, manufacturer = "Essai", model = "Montre de test")
    private val phone = Device(type = Device.TYPE_PHONE, manufacturer = "Essai", model = "Téléphone de test")

    suspend fun write(client: HealthConnectClient, days: Int): Int {
        val zone = ZoneId.systemDefault()
        val today = LocalDate.now(zone)
        val records = mutableListOf<Record>()
        // Health Connect refuses entries in the future (today before 10:00).
        val now = Instant.now()
        fun add(end: Instant, make: () -> Record) {
            if (end <= now) records += make()
        }
        for (back in 0..days) {
            val day = today.minusDays(back.toLong())
            val n = day.toEpochDay().toInt()
            val at = { hour: Int, minute: Int ->
                day.atStartOfDay(zone).plusHours(hour.toLong()).plusMinutes(minute.toLong()).toInstant()
            }
            val off = { i: Instant -> zone.rules.getOffset(i) }
            fun id(kind: String, i: Int) = "nexora-essai-$kind-$day-$i"
            fun meta(device: Device?, kind: String, i: Int) =
                if (device == null) Metadata.unknownRecordingMethod(id(kind, i)) else Metadata.autoRecorded(device, id(kind, i))

            // Today stops at 10:00: a partial day, as before a sync.
            val lastHour = if (back == 0) 10 else 22
            if (n % 9 != 4) {
                for (hour in 7 until lastHour) {
                    val count = 300 + (n * 37 + hour * 53) % 700
                    add(at(hour, 59)) { StepsRecord(at(hour, 0), off(at(hour, 0)), at(hour, 59), off(at(hour, 59)), count.toLong(), meta(watch, "pas", hour)) }
                }
                // The phone counts the same morning hour on some days.
                if (n % 3 == 0) {
                    add(at(8, 59)) { StepsRecord(at(8, 0), off(at(8, 0)), at(8, 59), off(at(8, 59)), 900, meta(phone, "pas-tel", 8)) }
                }
                // A source that names no device.
                if (n % 4 == 1 && back > 0) {
                    add(at(21, 30)) { StepsRecord(at(21, 0), off(at(21, 0)), at(21, 30), off(at(21, 30)), 150, meta(null, "pas-inconnu", 21)) }
                }
            }
            if (n % 11 != 6 && back > 0) {
                val bed = at(-1, (n * 13) % 90) // 23:00 to 00:30 the evening before
                val wake = at(6, (n * 17) % 75)
                val third = Duration.between(bed, wake).dividedBy(3)
                records += SleepSessionRecord(
                    bed, off(bed), wake, off(wake), meta(watch, "nuit", 0),
                    stages = listOf(
                        SleepSessionRecord.Stage(bed, bed.plus(third), SleepSessionRecord.STAGE_TYPE_LIGHT),
                        SleepSessionRecord.Stage(bed.plus(third), bed.plus(third.multipliedBy(2)), SleepSessionRecord.STAGE_TYPE_DEEP),
                        SleepSessionRecord.Stage(bed.plus(third.multipliedBy(2)), wake, SleepSessionRecord.STAGE_TYPE_REM),
                    ),
                )
            }
            if (n % 7 != 2) {
                for (hour in 8 until lastHour step 2) {
                    val samples = (0 until 6).map { k ->
                        HeartRateRecord.Sample(at(hour, k * 10), (58 + (n * 7 + hour * 5 + k * 3) % 40).toLong())
                    }
                    add(at(hour, 51)) { HeartRateRecord(at(hour, 0), off(at(hour, 0)), at(hour, 51), off(at(hour, 51)), samples, meta(watch, "coeur", hour)) }
                }
            }
            if (n % 3 == 1 && back > 0) {
                val start = at(18, 0)
                val end = at(18, 30 + n % 30)
                records += ExerciseSessionRecord(
                    startTime = start, startZoneOffset = off(start), endTime = end, endZoneOffset = off(end),
                    metadata = meta(watch, "seance", 0),
                    exerciseType = if (n % 2 == 0) ExerciseSessionRecord.EXERCISE_TYPE_RUNNING else ExerciseSessionRecord.EXERCISE_TYPE_WALKING,
                )
                records += DistanceRecord(start, off(start), end, off(end), Length.meters(2000.0 + (n % 10) * 250), meta(watch, "distance", 0))
            }
        }
        records.chunked(500).forEach { client.insertRecords(it) }
        return records.size
    }
}

import '../health/health_service.dart';
import '../health/health_summary.dart';

/// Local day key, `YYYY-MM-DD`, as computed by Android in the phone's time
/// zone. Dart never cuts days itself: a 23 h or 25 h day at a clock change
/// stays one key.
typedef DayKey = String;

DateTime parseDay(DayKey key) => DateTime.utc(
  int.parse(key.substring(0, 4)),
  int.parse(key.substring(5, 7)),
  int.parse(key.substring(8, 10)),
);

DayKey keyOf(DateTime day) =>
    dayKey(DateTime.utc(day.year, day.month, day.day));

/// Days from [from] to [to], both included.
List<DayKey> daysBetween(DayKey from, DayKey to) {
  final end = parseDay(to);
  return [
    for (
      var d = parseDay(from);
      !d.isAfter(end);
      d = d.add(const Duration(days: 1))
    )
      keyOf(d),
  ];
}

DayKey shiftDay(DayKey day, int days) =>
    keyOf(parseDay(day).add(Duration(days: days)));

/// A device as described by the entry's own metadata.
class DeviceInfo {
  const DeviceInfo({this.type, this.manufacturer, this.model});

  factory DeviceInfo.fromMap(Map<Object?, Object?> raw) => DeviceInfo(
    type: (raw['deviceType'] as num?)?.toInt(),
    manufacturer: _text(raw['manufacturer']),
    model: _text(raw['model']),
  );

  final int? type;
  final String? manufacturer;
  final String? model;

  /// The metadata names the device (a model or a maker), not only a type.
  bool get identified => model != null || manufacturer != null;

  String get name => [?manufacturer, ?model].join(' ');

  @override
  bool operator ==(Object other) =>
      other is DeviceInfo &&
      other.type == type &&
      other.manufacturer == manufacturer &&
      other.model == model;

  @override
  int get hashCode => Object.hash(type, manufacturer, model);
}

String? _text(Object? value) {
  final text = (value as String?)?.trim();
  return text == null || text.isEmpty ? null : text;
}

const unidentifiedDevice = 'Appareil d’origine non identifié';

/// The application that wrote entries (Health Sync, the phone's counter…)
/// and the devices its entries name. Writing app ≠ measuring device: a
/// device is shown only when every entry read names the same one.
class SourceRef {
  const SourceRef(this.origin, [this.devices = const []]);

  factory SourceRef.fromMap(Map<Object?, Object?> raw) =>
      SourceRef(raw['origin'] as String? ?? '', [
        for (final d in (raw['devices'] as List? ?? const []))
          DeviceInfo.fromMap(d as Map),
      ]);

  final String origin;
  final List<DeviceInfo> devices;

  String get app => appName(origin);
  SourceKind get kind => classify(
    HealthEntry(
      origin: origin,
      start: DateTime(0),
      end: DateTime(0),
      value: 0,
      deviceType: devices.length == 1 ? devices.single.type : null,
    ),
  );

  /// « montre · HUAWEI WATCH GT 5 Pro » when the metadata says so; otherwise
  /// « Appareil d’origine non identifié ».
  String get device {
    final distinct = devices.toSet();
    if (distinct.length != 1 || !distinct.single.identified) {
      return unidentifiedDevice;
    }
    final d = distinct.single;
    final type = deviceLabel(d.type);
    return [?type, d.name].join(' · ');
  }

  String get label => '$app — $device';
}

/// Common header of one category read over a range of days.
abstract class RangeData {
  RangeData(Map<Object?, Object?> raw)
    : zone = raw['zone'] as String? ?? '',
      from = raw['from'] as String,
      to = raw['to'] as String,
      readAt = DateTime.fromMillisecondsSinceEpoch(
        (raw['readAt'] as num).toInt(),
      ),
      truncated = raw['truncated'] as bool? ?? false;

  final String zone;
  final DayKey from;
  final DayKey to;
  final DateTime readAt;
  final bool truncated;

  HealthCategory get category;
}

class StepsOrigin {
  StepsOrigin(this.source, this.days, this.lastEndLocal);

  final SourceRef source;
  final Map<DayKey, int> days;

  /// Local `YYYY-MM-DDTHH:mm` end of the newest entry.
  final String? lastEndLocal;
}

class StepsData extends RangeData {
  StepsData(super.raw)
    : total = _days(raw['days']),
      origins = [
        for (final o in (raw['origins'] as List? ?? const []))
          StepsOrigin(
            SourceRef.fromMap(o as Map),
            _days(o['days']),
            o['lastEndLocal'] as String?,
          ),
      ];

  /// Health Connect's own daily total (overlaps removed by its priority order).
  final Map<DayKey, int> total;
  final List<StepsOrigin> origins;

  @override
  HealthCategory get category => HealthCategory.steps;

  static Map<DayKey, int> _days(Object? raw) => {
    for (final d in (raw as List? ?? const []))
      (d as Map)['date'] as String: (d['value'] as num).toInt(),
  };
}

class SleepSession {
  SleepSession.fromMap(Map<Object?, Object?> raw)
    : source = SourceRef(raw['origin'] as String? ?? '', [
        DeviceInfo.fromMap(raw),
      ]),
      start = DateTime.fromMillisecondsSinceEpoch(
        (raw['start'] as num).toInt(),
      ),
      end = DateTime.fromMillisecondsSinceEpoch((raw['end'] as num).toInt()),
      startLocal = raw['startLocal'] as String,
      endLocal = raw['endLocal'] as String,
      date = raw['date'] as String,
      stages = {
        for (final e in (raw['stages'] as Map? ?? const {}).entries)
          int.parse(e.key as String): (e.value as num).toInt(),
      };

  final SourceRef source;
  final DateTime start;
  final DateTime end;
  final String startLocal;
  final String endLocal;

  /// Wake-up day: the night counts once, on the day it ends.
  final DayKey date;
  final Map<int, int> stages;

  int get minutes => end.difference(start).inMinutes;
}

class SleepData extends RangeData {
  SleepData(super.raw)
    : sessions = [
        for (final s in (raw['sessions'] as List? ?? const []))
          SleepSession.fromMap(s as Map),
      ];

  final List<SleepSession> sessions;

  @override
  HealthCategory get category => HealthCategory.sleep;
}

class HeartDay {
  HeartDay.fromMap(Map<Object?, Object?> raw)
    : origin = raw['origin'] as String? ?? '',
      date = raw['date'] as String,
      count = (raw['count'] as num).toInt(),
      sum = (raw['sum'] as num).toInt(),
      min = (raw['min'] as num).toInt(),
      max = (raw['max'] as num).toInt(),
      hours = (raw['hours'] as num).toInt();

  final String origin;
  final DayKey date;

  /// Samples really measured that day (no interpolation).
  final int count;
  final int sum;
  final int min;
  final int max;

  /// Hours of the day with at least one sample, out of 24.
  final int hours;
}

class HeartData extends RangeData {
  HeartData(super.raw)
    : days = [
        for (final d in (raw['days'] as List? ?? const []))
          HeartDay.fromMap(d as Map),
      ],
      origins = {
        for (final o in (raw['origins'] as List? ?? const []))
          (o as Map)['origin'] as String: (
            source: SourceRef.fromMap(o),
            lastEndLocal: o['lastEndLocal'] as String?,
          ),
      };

  final List<HeartDay> days;
  final Map<String, ({SourceRef source, String? lastEndLocal})> origins;

  @override
  HealthCategory get category => HealthCategory.heartRate;
}

class Workout {
  Workout.fromMap(Map<Object?, Object?> raw)
    : source = SourceRef(raw['origin'] as String? ?? '', [
        DeviceInfo.fromMap(raw),
      ]),
      start = DateTime.fromMillisecondsSinceEpoch(
        (raw['start'] as num).toInt(),
      ),
      end = DateTime.fromMillisecondsSinceEpoch((raw['end'] as num).toInt()),
      startLocal = raw['startLocal'] as String,
      endLocal = raw['endLocal'] as String,
      date = raw['date'] as String,
      type = (raw['exerciseType'] as num?)?.toInt(),
      distanceMeters = (raw['distance'] as num?)?.toDouble();

  final SourceRef source;
  final DateTime start;
  final DateTime end;
  final String startLocal;
  final String endLocal;
  final DayKey date;
  final int? type;

  /// Only when the source wrote a distance and reading it is allowed.
  final double? distanceMeters;

  int get minutes => end.difference(start).inMinutes;
}

class ExerciseData extends RangeData {
  ExerciseData(super.raw)
    : distanceGranted = raw['distanceGranted'] as bool? ?? false,
      sessions = [
        for (final s in (raw['sessions'] as List? ?? const []))
          Workout.fromMap(s as Map),
      ];

  final bool distanceGranted;
  final List<Workout> sessions;

  @override
  HealthCategory get category => HealthCategory.exercise;
}

RangeData parseRange(HealthCategory category, Map<Object?, Object?> raw) =>
    switch (category) {
      HealthCategory.steps => StepsData(raw),
      HealthCategory.sleep => SleepData(raw),
      HealthCategory.heartRate => HeartData(raw),
      HealthCategory.exercise => ExerciseData(raw),
    };

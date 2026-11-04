import 'package:flutter/services.dart';

/// Health Connect categories of the local diagnostic, each with its own read
/// permission. The values never leave the phone: no log, no storage, no call
/// to the NEXORA server or the AI provider.
enum HealthCategory {
  steps('steps', 'Pas'),
  sleep('sleep', 'Sommeil'),
  heartRate('heart_rate', 'Fréquence cardiaque'),
  exercise('exercise', 'Entraînements');

  const HealthCategory(this.wire, this.label);

  final String wire;
  final String label;
}

enum HealthSdk { available, updateRequired, unavailable }

class HealthStatus {
  const HealthStatus({
    required this.sdk,
    required this.zone,
    required this.offset,
    this.granted = const {},
    this.historyFeature = false,
    this.historyGranted = false,
    this.debugSamples = false,
    this.distanceGranted = false,
  });

  final HealthSdk sdk;

  /// Time zone of the phone, used for the day boundaries (e.g. Africa/Tunis).
  final String zone;
  final String offset;
  final Set<HealthCategory> granted;

  /// Health Connect can grant reading beyond 30 days before the first grant.
  final bool historyFeature;
  final bool historyGranted;

  /// Debug build: sample entries can be written for an emulator.
  final bool debugSamples;

  /// Workouts: reading distances was allowed too (separate toggle).
  final bool distanceGranted;
}

/// One Health Connect entry, as written by its source application.
class HealthEntry {
  const HealthEntry({
    required this.origin,
    required this.start,
    required this.end,
    required this.value,
    this.offsetSeconds,
    this.deviceType,
    this.manufacturer,
    this.model,
    this.method = 0,
    this.stages = const {},
    this.exerciseType,
    this.min,
    this.max,
  });

  factory HealthEntry.fromMap(Map<dynamic, dynamic> raw) => HealthEntry(
    origin: raw['origin'] as String? ?? '',
    start: DateTime.fromMillisecondsSinceEpoch(raw['start'] as int),
    end: DateTime.fromMillisecondsSinceEpoch(raw['end'] as int),
    value: (raw['value'] as num?)?.toInt() ?? 0,
    offsetSeconds: raw['offset'] as int?,
    deviceType: raw['deviceType'] as int?,
    manufacturer: raw['manufacturer'] as String?,
    model: raw['model'] as String?,
    method: raw['method'] as int? ?? 0,
    stages: {
      for (final e in (raw['stages'] as Map? ?? const {}).entries)
        int.parse(e.key as String): (e.value as num).toInt(),
    },
    exerciseType: raw['exerciseType'] as int?,
    min: (raw['min'] as num?)?.toInt(),
    max: (raw['max'] as num?)?.toInt(),
  );

  /// Package of the application that wrote the entry.
  final String origin;
  final DateTime start;
  final DateTime end;

  /// Steps, minutes (sleep, workout) or number of heart rate samples.
  final int value;
  final int? offsetSeconds;

  /// Health Connect `Device.type` (1 watch, 2 phone, 6 band…), if given.
  final int? deviceType;
  final String? manufacturer;
  final String? model;

  /// Health Connect recording method (1 active, 2 automatic, 3 manual).
  final int method;

  /// Sleep: minutes per Health Connect stage type.
  final Map<int, int> stages;
  final int? exerciseType;

  /// Heart rate: lowest and highest sample of the entry.
  final int? min;
  final int? max;
}

/// Outcome of one category for one day.
sealed class HealthReading {
  const HealthReading();
}

/// Entries were read (possibly none: "Aucune donnée disponible").
class HealthData extends HealthReading {
  const HealthData({
    required this.category,
    required this.day,
    required this.zone,
    required this.entries,
    this.total,
    this.totalOrigins = const [],
    this.min,
    this.max,
    this.avg,
    this.samples,
    this.truncated = false,
  });

  final HealthCategory category;
  final DateTime day;
  final String zone;
  final List<HealthEntry> entries;

  /// Steps: Health Connect's own total, which removes overlaps by its
  /// priority order of applications.
  final int? total;
  final List<String> totalOrigins;

  /// Heart rate, over the whole day.
  final int? min;
  final int? max;
  final int? avg;
  final int? samples;

  /// More than 20 000 entries: only the first ones were read.
  final bool truncated;

  bool get isEmpty => entries.isEmpty;
}

/// Several days of one category, as Android returned them (JSON-compatible:
/// it is what the activity module keeps on the phone).
class HealthRangeRaw extends HealthReading {
  const HealthRangeRaw(this.category, this.raw);

  final HealthCategory category;
  final Map<String, Object?> raw;
}

class HealthDenied extends HealthReading {
  const HealthDenied();
}

class HealthUnavailable extends HealthReading {
  const HealthUnavailable();
}

class HealthFailed extends HealthReading {
  const HealthFailed(this.code);

  final String code;
}

abstract class HealthService {
  Future<HealthStatus> status();

  /// Shows Health Connect's permission screen for this category only.
  /// Returns whether reading is granted afterwards.
  Future<bool> request(HealthCategory category);

  /// One finished day, from 00:00 to 24:00 in the phone's time zone.
  Future<HealthReading> read(HealthCategory category, DateTime day);

  /// Days [from] to [to] (`YYYY-MM-DD`, both included) of one category.
  Future<HealthReading> range(HealthCategory category, String from, String to);

  /// Debug builds: synthetic history of [days] days (see `HealthSamples.kt`).
  /// Returns the number of entries, or -1 when permissions were requested.
  Future<int> writeHistory(int days);

  /// Start of the oldest entry readable in this category, if any.
  Future<DateTime?> oldest(HealthCategory category);

  /// Health Connect settings (or the store when an update is required).
  Future<void> openSettings();

  /// Debug builds: writes sample entries of NEXORA itself for [day]. Returns
  /// the number written, or -1 when write permissions were just requested.
  Future<int> writeSamples(DateTime day);
}

String dayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

class NativeHealthService implements HealthService {
  static const _channel = MethodChannel('app.nexora/health');

  @override
  Future<HealthStatus> status() async {
    try {
      final raw = await _channel.invokeMethod<Map>('status') ?? const {};
      return HealthStatus(
        sdk: switch (raw['sdk']) {
          'available' => HealthSdk.available,
          'update_required' => HealthSdk.updateRequired,
          _ => HealthSdk.unavailable,
        },
        zone: raw['zone'] as String? ?? '',
        offset: raw['offset'] as String? ?? '',
        granted: {
          for (final wire in (raw['granted'] as List? ?? const []))
            ...HealthCategory.values.where((c) => c.wire == wire),
        },
        historyFeature: raw['historyFeature'] as bool? ?? false,
        historyGranted: raw['historyGranted'] as bool? ?? false,
        debugSamples: raw['debugSamples'] as bool? ?? false,
        distanceGranted: raw['distanceGranted'] as bool? ?? false,
      );
    } on PlatformException {
      return HealthStatus(
        sdk: HealthSdk.unavailable,
        zone: DateTime.now().timeZoneName,
        offset: '',
      );
    }
  }

  @override
  Future<bool> request(HealthCategory category) async {
    try {
      return await _channel.invokeMethod<bool>('request', {
            'category': category.wire,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<HealthReading> read(HealthCategory category, DateTime day) async {
    try {
      final raw = await _channel.invokeMethod<Map>('read', {
        'category': category.wire,
        'day': dayKey(day),
      });
      if (raw == null) return const HealthFailed('empty');
      return HealthData(
        category: category,
        day: day,
        zone: raw['zone'] as String? ?? '',
        entries: [
          for (final e in (raw['entries'] as List? ?? const []))
            HealthEntry.fromMap(e as Map),
        ],
        total: (raw['total'] as num?)?.toInt(),
        totalOrigins: [
          for (final o in (raw['totalOrigins'] as List? ?? const []))
            o as String,
        ],
        min: (raw['min'] as num?)?.toInt(),
        max: (raw['max'] as num?)?.toInt(),
        avg: (raw['avg'] as num?)?.toInt(),
        samples: (raw['count'] as num?)?.toInt(),
        truncated: raw['truncated'] as bool? ?? false,
      );
    } on PlatformException catch (error) {
      return switch (error.code) {
        'permission_denied' => const HealthDenied(),
        'unavailable' => const HealthUnavailable(),
        _ => HealthFailed(error.code),
      };
    }
  }

  @override
  Future<HealthReading> range(
    HealthCategory category,
    String from,
    String to,
  ) async {
    try {
      final raw = await _channel.invokeMethod<Map>('range', {
        'category': category.wire,
        'from': from,
        'to': to,
      });
      if (raw == null) return const HealthFailed('empty');
      return HealthRangeRaw(category, _json(raw) as Map<String, Object?>);
    } on PlatformException catch (error) {
      return switch (error.code) {
        'permission_denied' => const HealthDenied(),
        'unavailable' => const HealthUnavailable(),
        _ => HealthFailed(error.code),
      };
    }
  }

  /// Channel maps and lists, made plain JSON values.
  static Object? _json(Object? value) => switch (value) {
    final Map m => {for (final e in m.entries) e.key as String: _json(e.value)},
    final List l => [for (final v in l) _json(v)],
    _ => value,
  };

  @override
  Future<int> writeHistory(int days) async =>
      await _channel.invokeMethod<int>('writeHistory', {'days': days}) ?? 0;

  @override
  Future<DateTime?> oldest(HealthCategory category) async {
    final ms = await _channel.invokeMethod<int>('oldest', {
      'category': category.wire,
    });
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  @override
  Future<void> openSettings() => _channel.invokeMethod('openSettings');

  @override
  Future<int> writeSamples(DateTime day) async =>
      await _channel.invokeMethod<int>('writeSamples', {'day': dayKey(day)}) ??
      0;
}

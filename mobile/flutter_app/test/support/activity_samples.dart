// Synthetic Health Connect range answers, shaped like HealthRange.kt's.
// Invented values only: no real health data in tests.

import 'package:nexora/src/activity/activity_models.dart';
import 'package:nexora/src/health/health_summary.dart';

const fitPackage = 'com.google.android.apps.fitness';
const watch = {
  'deviceType': 1,
  'manufacturer': 'HUAWEI',
  'model': 'WATCH GT 5 Pro',
};

/// 3 November 2026, 10:00: today is partial, yesterday is the last full day.
final sampleNow = DateTime(2026, 11, 3, 10);
const sampleToday = '2026-11-03';
final sampleReadAt = DateTime(2026, 11, 3, 9, 55).millisecondsSinceEpoch;

Map<String, Object?> _header(String from, String to) => {
  'zone': 'Africa/Tunis',
  'from': from,
  'to': to,
  'readAt': sampleReadAt,
};

/// Steps: Health Sync (watch) every day from [from] except [gaps], the phone
/// counter on the same mornings; Health Connect's total removes the overlap.
Map<String, Object?> stepsRaw({
  String from = '2026-09-05',
  String to = sampleToday,
  Set<DayKey> gaps = const {},
  int Function(DayKey day)? watchSteps,
  Map<String, Object?> device = watch,
}) {
  final days = daysBetween(from, to).where((d) => !gaps.contains(d)).toList();
  int w(DayKey d) => watchSteps?.call(d) ?? 8000;
  return {
    ..._header(from, to),
    'days': [
      for (final d in days) {'date': d, 'value': w(d) + 500},
    ],
    'origins': [
      {
        'origin': healthSyncPackage,
        'days': [
          for (final d in days) {'date': d, 'value': w(d)},
        ],
        'devices': [device],
        'lastEndLocal': '${sampleToday}T09:30',
      },
      {
        'origin': fitPackage,
        'days': [
          for (final d in days) {'date': d, 'value': 1500},
        ],
        'devices': [
          {'deviceType': 2},
        ],
        'lastEndLocal': '${sampleToday}T09:40',
      },
    ],
  };
}

Map<String, Object?> sleepSession(
  String origin,
  String start,
  String end, {
  Map<String, int> stages = const {},
  Map<String, Object?> device = watch,
}) {
  final s = DateTime.parse(start);
  final e = DateTime.parse(end);
  return {
    'origin': origin,
    ...device,
    'start': s.millisecondsSinceEpoch,
    'end': e.millisecondsSinceEpoch,
    'startLocal': start.substring(0, 16),
    'endLocal': end.substring(0, 16),
    'date': end.substring(0, 10),
    'stages': stages,
  };
}

Map<String, Object?> sleepRaw(List<Map<String, Object?>> sessions) => {
  ..._header('2026-09-05', sampleToday),
  'sessions': sessions,
};

Map<String, Object?> heartRaw(List<Map<String, Object?>> days) => {
  ..._header('2026-09-05', sampleToday),
  'days': days,
  'origins': [
    {
      'origin': healthSyncPackage,
      'devices': [watch],
      'lastEndLocal': '${sampleToday}T09:00',
    },
  ],
  'truncated': false,
};

Map<String, Object?> heartDay(
  String date,
  int count,
  int sum,
  int min,
  int max, {
  int hours = 12,
  String origin = healthSyncPackage,
}) => {
  'origin': origin,
  'date': date,
  'count': count,
  'sum': sum,
  'min': min,
  'max': max,
  'hours': hours,
};

Map<String, Object?> workout(
  String origin,
  String start,
  String end, {
  int type = 56,
  double? distance,
}) {
  final s = DateTime.parse(start);
  final e = DateTime.parse(end);
  return {
    'origin': origin,
    ...watch,
    'start': s.millisecondsSinceEpoch,
    'end': e.millisecondsSinceEpoch,
    'startLocal': start.substring(0, 16),
    'endLocal': end.substring(0, 16),
    'date': start.substring(0, 10),
    'exerciseType': type,
    'distance': ?distance,
  };
}

Map<String, Object?> exerciseRaw(
  List<Map<String, Object?>> sessions, {
  bool distanceGranted = true,
}) => {
  ..._header('2026-09-05', sampleToday),
  'distanceGranted': distanceGranted,
  'sessions': sessions,
};

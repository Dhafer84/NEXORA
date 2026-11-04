import 'package:nexora/src/health/health_service.dart';

/// Health Connect without Android: entries per category for any day, and the
/// answer of the user on each permission screen.
class FakeHealth implements HealthService {
  FakeHealth({
    this.sdk = HealthSdk.available,
    Set<HealthCategory>? granted,
    Map<HealthCategory, List<HealthEntry>>? entries,
    Set<HealthCategory>? refuse,
    Map<HealthCategory, Map<String, Object?>>? ranges,
  }) : granted = granted ?? {},
       entries = entries ?? {},
       refuse = refuse ?? {},
       ranges = ranges ?? {};

  HealthSdk sdk;
  final Set<HealthCategory> granted;
  final Map<HealthCategory, List<HealthEntry>> entries;

  /// Categories the user refuses on the permission screen.
  final Set<HealthCategory> refuse;
  int? stepsTotal;

  /// Answer of a range read per category (see activity_samples.dart).
  final Map<HealthCategory, Map<String, Object?>> ranges;

  /// Failure code of the next range reads, per category.
  final Map<HealthCategory, String> failRange = {};
  final List<String> calls = [];
  final List<DateTime> days = [];

  @override
  Future<HealthStatus> status() async => HealthStatus(
    sdk: sdk,
    zone: 'Africa/Tunis',
    offset: '+01:00',
    granted: {...granted},
  );

  @override
  Future<bool> request(HealthCategory category) async {
    calls.add('request:${category.wire}');
    if (!refuse.contains(category)) granted.add(category);
    return granted.contains(category);
  }

  @override
  Future<HealthReading> read(HealthCategory category, DateTime day) async {
    calls.add('read:${category.wire}');
    days.add(day);
    if (!granted.contains(category)) return const HealthDenied();
    final dayEntries = [
      for (final e in entries[category] ?? const <HealthEntry>[])
        if (e.end.year == day.year &&
            e.end.month == day.month &&
            e.end.day == day.day)
          e,
    ];
    return HealthData(
      category: category,
      day: day,
      zone: 'Africa/Tunis',
      entries: dayEntries,
      total: category == HealthCategory.steps && dayEntries.isNotEmpty
          ? stepsTotal
          : null,
    );
  }

  @override
  Future<DateTime?> oldest(HealthCategory category) async {
    calls.add('oldest:${category.wire}');
    final all = entries[category] ?? const <HealthEntry>[];
    if (all.isEmpty) return null;
    return all.map((e) => e.start).reduce((a, b) => a.isBefore(b) ? a : b);
  }

  @override
  Future<void> openSettings() async => calls.add('settings');

  @override
  Future<int> writeSamples(DateTime day) async => 0;

  @override
  Future<HealthReading> range(
    HealthCategory category,
    String from,
    String to,
  ) async {
    calls.add('range:${category.wire}:$from:$to');
    if (!granted.contains(category)) return const HealthDenied();
    if (failRange[category] case final code?) return HealthFailed(code);
    return HealthRangeRaw(
      category,
      ranges[category] ??
          {'zone': 'Africa/Tunis', 'from': from, 'to': to, 'readAt': 0},
    );
  }

  @override
  Future<int> writeHistory(int days) async {
    calls.add('writeHistory:$days');
    return 0;
  }
}

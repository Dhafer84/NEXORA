import 'health_service.dart';

/// Where an entry comes from, to avoid counting the same steps twice.
enum SourceKind {
  /// Written by Health Sync. That names the transferring app only: the
  /// device is known only when the entry's metadata gives it.
  healthSync,

  /// Measured by the phone itself (its step counter, whatever the app).
  phone,

  /// Sample entries of NEXORA (debug builds on an emulator).
  nexora,

  otherApp,
}

const healthSyncPackage = 'nl.appyhapps.healthsync';

const _appNames = {
  healthSyncPackage: 'Health Sync',
  'com.huawei.health': 'Huawei Health',
  'com.google.android.apps.fitness': 'Google Fit',
  'com.google.android.apps.healthdata': 'Health Connect',
  'com.android.healthconnect.controller': 'Health Connect',
  'android': 'Android',
  'com.sec.android.app.shealth': 'Samsung Health',
  'com.fitbit.FitbitMobile': 'Fitbit',
  'com.xiaomi.wearable': 'Mi Fitness',
  'app.nexora.mobile': 'NEXORA (essai)',
};

/// Packages that only write what the phone itself measures.
const _phonePackages = {
  'android',
  'com.android.healthconnect.controller',
  'com.google.android.apps.healthdata',
};

String appName(String origin) => _appNames[origin] ?? origin;

String? deviceLabel(int? type) => switch (type) {
  1 => 'montre',
  2 => 'téléphone',
  3 => 'balance',
  4 => 'bague',
  5 => 'casque',
  6 => 'bracelet',
  7 => 'ceinture cardio',
  8 => 'écran connecté',
  _ => null,
};

SourceKind classify(HealthEntry entry) {
  // Health Sync first: its entries may say "phone" when the steps were
  // counted by Huawei Health on the phone, but they are still a transfer.
  if (entry.origin.startsWith(healthSyncPackage)) return SourceKind.healthSync;
  if (entry.origin == 'app.nexora.mobile') return SourceKind.nexora;
  if (entry.deviceType == 2 || _phonePackages.contains(entry.origin)) {
    return SourceKind.phone;
  }
  return SourceKind.otherApp;
}

/// Entries of one application and one device.
class SourceGroup {
  SourceGroup._(this.kind, this.origin, this.deviceType, this.device);

  final SourceKind kind;
  final String origin;
  final int? deviceType;

  /// "HUAWEI WATCH GT 5 Pro" when the source names the device.
  final String? device;
  int total = 0;
  int entries = 0;
  late DateTime first;
  late DateTime last;
  final List<(DateTime, DateTime)> _intervals = [];

  String get app => appName(origin);

  String get label {
    final type = deviceLabel(deviceType);
    final what = [?type, ?device].join(' · ');
    return what.isEmpty ? app : '$app — $what';
  }

  String get key => '$origin|$deviceType|$device';

  /// Union of this group's intervals, sorted.
  List<(DateTime, DateTime)> get union {
    final sorted = [..._intervals]..sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(DateTime, DateTime)>[];
    for (final interval in sorted) {
      if (merged.isNotEmpty && !interval.$1.isAfter(merged.last.$2)) {
        final last = merged.removeLast();
        merged.add((
          last.$1,
          interval.$2.isAfter(last.$2) ? interval.$2 : last.$2,
        ));
      } else {
        merged.add(interval);
      }
    }
    return merged;
  }
}

/// Two sources recording the same period: adding them would count twice.
class Overlap {
  const Overlap(this.a, this.b, this.minutes);

  final SourceGroup a;
  final SourceGroup b;
  final int minutes;
}

class SourceSummary {
  SourceSummary._(this.groups, this.overlaps);

  factory SourceSummary.of(List<HealthEntry> entries) {
    final byKey = <String, SourceGroup>{};
    for (final entry in entries) {
      final model = [
        ?entry.manufacturer,
        ?entry.model,
      ].where((p) => p.trim().isNotEmpty).join(' ');
      final group = SourceGroup._(
        classify(entry),
        entry.origin,
        entry.deviceType,
        model.isEmpty ? null : model,
      );
      final existing = byKey.putIfAbsent(group.key, () {
        group
          ..first = entry.start
          ..last = entry.end;
        return group;
      });
      existing
        ..total += entry.value
        ..entries += 1;
      if (entry.start.isBefore(existing.first)) existing.first = entry.start;
      if (entry.end.isAfter(existing.last)) existing.last = entry.end;
      existing._intervals.add((entry.start, entry.end));
    }
    final groups = byKey.values.toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    final overlaps = <Overlap>[];
    final unions = {for (final g in groups) g.key: g.union};
    for (var i = 0; i < groups.length; i++) {
      for (var j = i + 1; j < groups.length; j++) {
        final minutes = _overlapMinutes(
          unions[groups[i].key]!,
          unions[groups[j].key]!,
        );
        if (minutes > 0) overlaps.add(Overlap(groups[i], groups[j], minutes));
      }
    }
    return SourceSummary._(groups, overlaps);
  }

  final List<SourceGroup> groups;
  final List<Overlap> overlaps;

  int get sum => groups.fold(0, (total, g) => total + g.total);

  /// Total of the entries written by Health Sync: the figure to compare with
  /// Huawei Health.
  int? get healthSyncTotal {
    final mine = groups.where((g) => g.kind == SourceKind.healthSync);
    return mine.isEmpty ? null : mine.fold<int>(0, (t, g) => t + g.total);
  }

  bool get hasHealthSync => groups.any((g) => g.kind == SourceKind.healthSync);
}

int _overlapMinutes(
  List<(DateTime, DateTime)> a,
  List<(DateTime, DateTime)> b,
) {
  var i = 0, j = 0;
  var total = Duration.zero;
  while (i < a.length && j < b.length) {
    final start = a[i].$1.isAfter(b[j].$1) ? a[i].$1 : b[j].$1;
    final end = a[i].$2.isBefore(b[j].$2) ? a[i].$2 : b[j].$2;
    if (end.isAfter(start)) total += end.difference(start);
    if (a[i].$2.isBefore(b[j].$2)) {
      i++;
    } else {
      j++;
    }
  }
  return total.inMinutes;
}

/// Yesterday: the most recent finished day in the phone's time zone.
DateTime lastFinishedDay(DateTime now) =>
    DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));

const sleepStageNames = {
  0: 'non précisé',
  1: 'éveil',
  2: 'sommeil',
  3: 'hors du lit',
  4: 'léger',
  5: 'profond',
  6: 'paradoxal',
  7: 'éveil au lit',
};

String exerciseName(int? type) => switch (type) {
  8 => 'Vélo',
  9 => 'Vélo d’appartement',
  37 => 'Randonnée',
  56 => 'Course à pied',
  57 => 'Course sur tapis',
  70 => 'Musculation',
  73 => 'Natation en eau libre',
  74 => 'Natation en piscine',
  79 => 'Marche',
  81 => 'Haltérophilie',
  83 => 'Yoga',
  0 => 'Autre activité',
  null => 'Activité',
  _ => 'Activité (type $type)',
};

import 'dart:math' as math;

import '../health/health_summary.dart';
import 'activity_models.dart';

/// Every source of the category together. For steps this is Health
/// Connect's own total, which removes overlapping periods (for example the
/// phone's counter and the watch transferred by Health Sync).
const allSources = '*';

enum DayState {
  /// Data for a finished day.
  complete,

  /// Today, or a day whose newest entry ends before 21:00 (sync not done).
  partial,

  /// No entry: shown as missing, never as zero.
  missing,
}

class DayPoint {
  const DayPoint(this.day, this.value, this.state, {this.low, this.high});

  final DayKey day;
  final num? value;
  final DayState state;

  /// Heart rate: lowest and highest sample of the day.
  final num? low;
  final num? high;
}

/// Descriptive figures over a window of days.
class PeriodStats {
  PeriodStats(this.points)
    : days = points.length,
      complete = points.where((p) => p.state == DayState.complete).length,
      partial = points.where((p) => p.state == DayState.partial).length,
      missing = points.where((p) => p.state == DayState.missing).length;

  final List<DayPoint> points;
  final int days;
  final int complete;
  final int partial;
  final int missing;

  Iterable<num> get _complete =>
      points.where((p) => p.state == DayState.complete).map((p) => p.value!);

  /// Mean over finished days with data (partial and missing days excluded).
  double? get mean {
    final values = _complete.toList();
    if (values.isEmpty) return null;
    return values.fold<num>(0, (a, b) => a + b) / values.length;
  }

  /// Sum of every day with data, partial ones included.
  num get total =>
      points.where((p) => p.value != null).fold<num>(0, (a, p) => a + p.value!);

  num? get min => _complete.isEmpty ? null : _complete.reduce(math.min);
  num? get max => _complete.isEmpty ? null : _complete.reduce(math.max);

  double get coverage => days == 0 ? 0 : complete / days;
}

/// Current window against the one just before, when their coverage allows.
class Comparison {
  const Comparison({
    required this.comparable,
    this.change,
    this.previousMean,
    this.reason,
  });

  final bool comparable;

  /// Relative change of the mean, e.g. 0.12 for +12 %.
  final double? change;
  final double? previousMean;

  /// Why the comparison would mislead, when it is not comparable.
  final String? reason;
}

/// Minimum share of finished days with data in each window, and maximum gap
/// between the two counts (15 % of the window, at least one day).
const minCoverage = 0.7;

Comparison compare(PeriodStats current, PeriodStats previous) {
  final n = current.days;
  final allowedGap = math.max(1, (n * 0.15).round());
  String? reason;
  if (previous.complete == 0) {
    reason = 'aucune donnée sur la période précédente';
  } else if (current.coverage < minCoverage ||
      previous.coverage < minCoverage) {
    reason =
        'couverture insuffisante (${current.complete}/$n jours, contre '
        '${previous.complete}/${previous.days})';
  } else if ((current.complete - previous.complete).abs() > allowedGap) {
    reason =
        'nombre de jours renseignés trop différent (${current.complete} '
        'contre ${previous.complete})';
  }
  final now = current.mean;
  final before = previous.mean;
  if (reason != null || now == null || before == null || before == 0) {
    return Comparison(
      comparable: false,
      previousMean: before,
      reason: reason ?? 'moyennes indisponibles',
    );
  }
  return Comparison(
    comparable: true,
    change: (now - before) / before,
    previousMean: before,
  );
}

/// [days] days ending on [end], and the [days] before.
({List<DayKey> current, List<DayKey> previous}) windows(DayKey end, int days) =>
    (
      current: daysBetween(shiftDay(end, 1 - days), end),
      previous: daysBetween(shiftDay(end, 1 - 2 * days), shiftDay(end, -days)),
    );

DayState _state(
  DayKey day,
  num? value,
  DayKey today,
  Iterable<String?> lastEnds,
) {
  if (value == null) return DayState.missing;
  if (day == today) return DayState.partial;
  for (final last in lastEnds) {
    if (last != null &&
        last.startsWith(day) &&
        last.substring(11).compareTo('21:00') < 0) {
      return DayState.partial;
    }
  }
  return DayState.complete;
}

String? _preferHealthSync(Iterable<String> origins) =>
    origins.where((o) => o.startsWith(healthSyncPackage)).firstOrNull;

// ----- Steps ---------------------------------------------------------------------

List<String> stepsSources(StepsData data) => [
  allSources,
  for (final o in data.origins) o.source.origin,
];

/// Health Sync when it wrote steps (the figure Huawei Health shows), else
/// Health Connect's deduplicated total.
String defaultStepsSource(StepsData data) =>
    _preferHealthSync(data.origins.map((o) => o.source.origin)) ?? allSources;

List<DayPoint> stepsSeries(
  StepsData data,
  String source,
  List<DayKey> days,
  DayKey today,
) {
  final origin = data.origins.where((o) => o.source.origin == source);
  final values = source == allSources ? data.total : origin.firstOrNull?.days;
  final lastEnds = source == allSources
      ? data.origins.map((o) => o.lastEndLocal)
      : origin.map((o) => o.lastEndLocal);
  return [
    for (final day in days)
      DayPoint(day, values?[day], _state(day, values?[day], today, lastEnds)),
  ];
}

/// Steps Health Connect did not count twice on [day]: sum of the sources
/// minus its total. Zero when no source overlaps another.
int stepsOverlap(StepsData data, DayKey day) {
  final total = data.total[day];
  if (total == null) return 0;
  final sum = data.origins.fold<int>(0, (a, o) => a + (o.days[day] ?? 0));
  return math.max(0, sum - total);
}

// ----- Sleep ---------------------------------------------------------------------

class Night {
  const Night({
    required this.day,
    required this.minutes,
    required this.bedtime,
    required this.wake,
    required this.stages,
    required this.sessions,
    required this.sources,
  });

  /// Wake-up day.
  final DayKey day;

  /// Union of the sessions: overlapping sessions are not added twice.
  final int minutes;

  /// `HH:mm` of the longest session.
  final String bedtime;
  final String wake;
  final Map<int, int> stages;
  final int sessions;
  final Set<String> sources;
}

List<String> sleepSources(SleepData data) => [
  allSources,
  ...{for (final s in data.sessions) s.source.origin},
];

String defaultSleepSource(SleepData data) {
  final origins = [for (final s in data.sessions) s.source.origin];
  final sync = _preferHealthSync(origins);
  if (sync != null) return sync;
  if (origins.toSet().length <= 1) return origins.firstOrNull ?? allSources;
  final counts = <String, int>{};
  for (final o in origins) {
    counts[o] = (counts[o] ?? 0) + 1;
  }
  return (counts.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
}

int _unionMinutes(List<SleepSession> sessions) {
  final sorted = [...sessions]..sort((a, b) => a.start.compareTo(b.start));
  var total = Duration.zero;
  DateTime? start;
  DateTime? end;
  for (final s in sorted) {
    if (end == null || s.start.isAfter(end)) {
      if (start != null) total += end!.difference(start);
      start = s.start;
      end = s.end;
    } else if (s.end.isAfter(end)) {
      end = s.end;
    }
  }
  if (start != null) total += end!.difference(start);
  return total.inMinutes;
}

Map<DayKey, Night> nights(SleepData data, String source) {
  final byDay = <DayKey, List<SleepSession>>{};
  for (final s in data.sessions) {
    if (source != allSources && s.source.origin != source) continue;
    byDay.putIfAbsent(s.date, () => []).add(s);
  }
  return byDay.map((day, sessions) {
    final main = sessions.reduce((a, b) => b.minutes > a.minutes ? b : a);
    final sources = {for (final s in sessions) s.source.origin};
    // Several sources describe the same night: only the main session's phases.
    final stages = <int, int>{};
    for (final s in sources.length > 1 ? [main] : sessions) {
      s.stages.forEach((k, v) => stages[k] = (stages[k] ?? 0) + v);
    }
    return MapEntry(
      day,
      Night(
        day: day,
        minutes: _unionMinutes(sessions),
        bedtime: main.startLocal.substring(11),
        wake: main.endLocal.substring(11),
        stages: stages,
        sessions: sessions.length,
        sources: sources,
      ),
    );
  });
}

List<DayPoint> sleepSeries(Map<DayKey, Night> byDay, List<DayKey> days) => [
  for (final day in days)
    DayPoint(
      day,
      byDay[day]?.minutes,
      byDay[day] == null ? DayState.missing : DayState.complete,
    ),
];

// ----- Heart rate ----------------------------------------------------------------

List<String> heartSources(HeartData data) =>
    {for (final d in data.days) d.origin}.toList();

String? defaultHeartSource(HeartData data) {
  final origins = heartSources(data);
  final sync = _preferHealthSync(origins);
  if (sync != null) return sync;
  final counts = <String, int>{};
  for (final d in data.days) {
    counts[d.origin] = (counts[d.origin] ?? 0) + d.count;
  }
  if (counts.isEmpty) return null;
  return (counts.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
}

Map<DayKey, HeartDay> heartDays(HeartData data, String source) => {
  for (final d in data.days)
    if (d.origin == source) d.date: d,
};

List<DayPoint> heartSeries(
  HeartData data,
  String source,
  List<DayKey> days,
  DayKey today,
) {
  final byDay = heartDays(data, source);
  final last = data.origins[source]?.lastEndLocal;
  return [
    for (final day in days)
      if (byDay[day] case final d?)
        DayPoint(
          day,
          (d.sum / d.count).round(),
          _state(day, d.count, today, [last]),
          low: d.min,
          high: d.max,
        )
      else
        DayPoint(day, null, DayState.missing),
  ];
}

/// Statistics from the samples really present: the mean weights each day by
/// its number of samples.
class HeartStats {
  HeartStats(Iterable<HeartDay> days)
    : count = days.fold(0, (a, d) => a + d.count),
      _sum = days.fold(0, (a, d) => a + d.sum),
      min = days.isEmpty ? null : days.map((d) => d.min).reduce(math.min),
      max = days.isEmpty ? null : days.map((d) => d.max).reduce(math.max),
      daysWithData = days.length,
      meanHours = days.isEmpty
          ? null
          : days.fold<int>(0, (a, d) => a + d.hours) / days.length;

  final int count;
  final int _sum;
  final int? min;
  final int? max;
  final int daysWithData;

  /// Mean number of hours per day with at least one sample.
  final double? meanHours;

  double? get mean => count == 0 ? null : _sum / count;
}

// ----- Workouts ------------------------------------------------------------------

/// Sessions of different sources overlapping on at least half of the shorter
/// one describe the same workout: one is kept (Health Sync first, then the
/// longer one).
({List<Workout> kept, int duplicates}) dedupeWorkouts(List<Workout> sessions) {
  int rank(Workout w) => w.source.origin.startsWith(healthSyncPackage) ? 0 : 1;
  final ordered = [...sessions]
    ..sort((a, b) {
      final r = rank(a) - rank(b);
      return r != 0 ? r : b.minutes - a.minutes;
    });
  final kept = <Workout>[];
  var duplicates = 0;
  for (final w in ordered) {
    final same = kept.any((k) {
      if (k.source.origin == w.source.origin) return false;
      final start = k.start.isAfter(w.start) ? k.start : w.start;
      final end = k.end.isBefore(w.end) ? k.end : w.end;
      final overlap = end.difference(start).inMinutes;
      return overlap > 0 && overlap * 2 >= math.min(k.minutes, w.minutes);
    });
    if (same) {
      duplicates++;
    } else {
      kept.add(w);
    }
  }
  kept.sort((a, b) => b.start.compareTo(a.start));
  return (kept: kept, duplicates: duplicates);
}

List<String> workoutSources(ExerciseData data) => [
  allSources,
  ...{for (final s in data.sessions) s.source.origin},
];

List<Workout> workoutsFor(ExerciseData data, String source, List<DayKey> days) {
  final inPeriod = days.toSet();
  final sessions = [
    for (final s in data.sessions)
      if (inPeriod.contains(s.date) &&
          (source == allSources || s.source.origin == source))
        s,
  ];
  if (source != allSources) {
    return sessions..sort((a, b) => b.start.compareTo(a.start));
  }
  return dedupeWorkouts(sessions).kept;
}

class WeekTotal {
  const WeekTotal(this.monday, this.sessions, this.minutes, this.partial);

  final DayKey monday;
  final int sessions;
  final int minutes;

  /// The week is not entirely inside the period.
  final bool partial;
}

/// Weeks from Monday, covering [days].
List<WeekTotal> weeklyWorkouts(List<Workout> sessions, List<DayKey> days) {
  if (days.isEmpty) return const [];
  final inPeriod = days.toSet();
  DayKey mondayOf(DayKey day) =>
      shiftDay(day, 1 - parseDay(day).weekday); // DateTime.monday == 1
  final weeks = <DayKey>[];
  for (final d in days) {
    final m = mondayOf(d);
    if (!weeks.contains(m)) weeks.add(m);
  }
  return [
    for (final m in weeks)
      WeekTotal(
        m,
        sessions.where((s) => mondayOf(s.date) == m).length,
        sessions
            .where((s) => mondayOf(s.date) == m)
            .fold(0, (a, s) => a + s.minutes),
        !List.generate(7, (i) => shiftDay(m, i)).every(inPeriod.contains),
      ),
  ];
}

// ----- Formatting ----------------------------------------------------------------

String hoursMinutes(num minutes) {
  final m = minutes.round();
  return m >= 60
      ? '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')}'
      : '$m min';
}

String percent(double ratio) {
  final value = (ratio * 100).round();
  return '${value > 0 ? '+' : ''}$value %';
}

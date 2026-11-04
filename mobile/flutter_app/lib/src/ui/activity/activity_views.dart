import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../../activity/activity_controller.dart';
import '../../activity/activity_models.dart';
import '../../activity/activity_stats.dart';
import '../../health/health_service.dart';
import '../../health/health_summary.dart';
import '../theme.dart';
import '../widgets/states.dart';
import 'activity_chart.dart';

final _number = NumberFormat.decimalPattern('fr_FR');
String n0(num value) => _number.format(value.round());

String periodLabel(List<DayKey> days) =>
    'du ${longDay(days.first)} au ${longDay(days.last)}';

IconData categoryIcon(HealthCategory category) => switch (category) {
  HealthCategory.steps => Icons.directions_walk_rounded,
  HealthCategory.sleep => Icons.bedtime_rounded,
  HealthCategory.heartRate => Icons.favorite_rounded,
  HealthCategory.exercise => Icons.fitness_center_rounded,
};

String sourceName(String source, RangeData data) {
  if (source == allSources) {
    return data is StepsData
        ? 'Toutes sources (total Health Connect)'
        : 'Toutes sources (sans doublon)';
  }
  final ref = switch (data) {
    StepsData(:final origins) =>
      origins.where((o) => o.source.origin == source).firstOrNull?.source,
    HeartData(:final origins) => origins[source]?.source,
    SleepData(:final sessions) => SourceRef(source, [
      for (final s in sessions)
        if (s.source.origin == source) ...s.source.devices,
    ]),
    ExerciseData(:final sessions) => SourceRef(source, [
      for (final s in sessions)
        if (s.source.origin == source) ...s.source.devices,
    ]),
    _ => null,
  };
  return (ref ?? SourceRef(source)).label;
}

/// Text of the issue of a category, for its card and its screen.
String? issueText(CategoryState state) => switch (state.issue) {
  Issue.notAuthorized => 'Lecture non autorisée',
  Issue.revoked =>
    'Autorisation retirée dans Health Connect : la copie locale a été effacée.',
  Issue.unavailable => 'Health Connect indisponible',
  Issue.failed =>
    'Lecture échouée (${state.code ?? 'erreur'})'
        '${state.data != null ? ' : chiffres de la dernière lecture réussie.' : '.'}',
  null => null,
};

class PeriodPicker extends StatelessWidget {
  const PeriodPicker({super.key, required this.days, required this.onChanged});

  final int days;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<int>(
    segments: const [
      ButtonSegment(value: 7, label: Text('7 jours')),
      ButtonSegment(value: 30, label: Text('30 jours')),
    ],
    selected: {days},
    onSelectionChanged: (s) => onChanged(s.single),
  );
}

class SourcePicker extends StatelessWidget {
  const SourcePicker({
    super.key,
    required this.sources,
    required this.selected,
    required this.data,
    required this.onChanged,
  });

  final List<String> sources;
  final String selected;
  final RangeData data;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    if (sources.length < 2) {
      return Text(
        'Source : ${sourceName(selected, data)}',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: selected,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Source'),
      items: [
        for (final s in sources)
          DropdownMenuItem(
            value: s,
            child: Text(sourceName(s, data), overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (s) => s == null ? null : onChanged(s),
    );
  }
}

class StatLine extends StatelessWidget {
  const StatLine(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        const SizedBox(width: Space.m),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class Section extends StatelessWidget {
  const Section({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: Space.l),
    child: Padding(
      padding: const EdgeInsets.all(Space.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Space.s),
          ...children,
        ],
      ),
    ),
  );
}

String comparisonText(Comparison c, String Function(num) format) => c.comparable
    ? '${percent(c.change!)} par rapport à la période précédente '
          '(moyenne ${format(c.previousMean!)})'
    : 'Comparaison non pertinente : ${c.reason}.';

String coverageText(PeriodStats s) => [
  '${s.complete} jour${s.complete > 1 ? 's' : ''} complet${s.complete > 1 ? 's' : ''} sur ${s.days}',
  if (s.partial > 0) '${s.partial} partiel${s.partial > 1 ? 's' : ''}',
  if (s.missing > 0) '${s.missing} sans donnée',
].join(', ');

// ----- Category detail -------------------------------------------------------------

/// Detail of one category: period, source, chart, figures and entries.
class CategoryScreen extends StatefulWidget {
  const CategoryScreen({
    super.key,
    required this.controller,
    required this.category,
  });

  final ActivityController controller;
  final HealthCategory category;

  @override
  State<CategoryScreen> createState() => _CategoryScreenState();
}

class _CategoryScreenState extends State<CategoryScreen> {
  int _days = 7;
  String? _source;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final state = c[widget.category];
      final data = state.data;
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.category.label),
          actions: [
            IconButton(
              tooltip: 'Actualiser',
              onPressed: state.busy ? null : () => c.refresh(widget.category),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(Space.l),
          children: [
            if (state.busy) const LinearProgressIndicator(),
            if (issueText(state) case final text?)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.m),
                child: NoticeBar(
                  tone: state.issue == Issue.failed ? 'warning' : 'error',
                  message: text,
                ),
              ),
            if (data == null)
              const MessageView(
                icon: Icons.hourglass_empty_rounded,
                title: 'Aucune donnée lue',
                body:
                    'Autorisez la lecture puis actualisez depuis l’onglet Activité.',
              )
            else ...[
              PeriodPicker(
                days: _days,
                onChanged: (d) => setState(() => _days = d),
              ),
              const SizedBox(height: Space.m),
              ...switch (data) {
                StepsData() => _steps(c, data),
                SleepData() => _sleep(c, data),
                HeartData() => _heart(c, data),
                ExerciseData() => _exercise(c, data),
                _ => const <Widget>[],
              },
              const SizedBox(height: Space.l),
              Text(
                'Dernière lecture réussie : ${longDay(keyOf(data.readAt))} à '
                '${data.readAt.hour.toString().padLeft(2, '0')}:'
                '${data.readAt.minute.toString().padLeft(2, '0')} · fuseau ${data.zone}'
                '${data.truncated ? ' · lecture partielle (trop d’entrées)' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      );
    },
  );

  Widget _sourcePicker(List<String> sources, String selected, RangeData data) =>
      SourcePicker(
        sources: sources,
        selected: selected,
        data: data,
        onChanged: (s) => setState(() => _source = s),
      );

  List<Widget> _steps(ActivityController c, StepsData data) {
    final sources = stepsSources(data);
    final source = sources.contains(_source)
        ? _source!
        : defaultStepsSource(data);
    final w = windows(c.yesterday, _days);
    final points = stepsSeries(data, source, w.current, c.today);
    final stats = PeriodStats(points);
    final previous = PeriodStats(
      stepsSeries(data, source, w.previous, c.today),
    );
    final comparison = compare(stats, previous);
    String fmt(num v) => '${n0(v)} pas';
    final overlap = source == allSources
        ? w.current.fold<int>(0, (a, d) => a + stepsOverlap(data, d))
        : 0;
    return [
      _sourcePicker(sources, source, data),
      Section(
        title: 'Pas par jour',
        children: [
          ActivityChart(
            points: points,
            unit: 'pas',
            format: fmt,
            summary: _summary('Pas par jour', points, stats, fmt),
          ),
          StatLine(
            'Moyenne des jours complets',
            stats.mean == null ? '—' : '${fmt(stats.mean!)} / jour',
          ),
          StatLine('Total de la période', fmt(stats.total)),
          StatLine('Couverture', coverageText(stats)),
          StatLine('Évolution', comparisonText(comparison, fmt)),
        ],
      ),
      Section(
        title: 'Sources',
        children: [
          if (source == allSources)
            Text(
              overlap > 0
                  ? 'Health Connect a retiré ${n0(overlap)} pas comptés par plusieurs '
                        'sources sur la période (téléphone et montre sur les mêmes heures, '
                        'par exemple). Les sources ne sont jamais additionnées.'
                  : 'Aucun chevauchement entre sources sur la période.',
            )
          else
            Text('Seules les entrées de ${appName(source)} sont comptées.'),
          for (final o in data.origins)
            StatLine(
              o.source.label,
              '${o.days.keys.where(w.current.contains).length} j · '
              '${n0(w.current.fold<int>(0, (a, d) => a + (o.days[d] ?? 0)))} pas',
            ),
        ],
      ),
      _DayList(points: points, format: fmt),
    ];
  }

  List<Widget> _sleep(ActivityController c, SleepData data) {
    final sources = sleepSources(data);
    final source = sources.contains(_source)
        ? _source!
        : defaultSleepSource(data);
    final byDay = nights(data, source);
    // A night belongs to its wake-up day: last night counts for today.
    final w = windows(c.today, _days);
    final points = sleepSeries(byDay, w.current)
        .map(
          (p) =>
              DayPoint(p.day, p.value == null ? null : p.value! / 60, p.state),
        )
        .toList();
    final stats = PeriodStats(points);
    final previous = PeriodStats(sleepSeries(byDay, w.previous));
    final comparison = compare(
      PeriodStats(sleepSeries(byDay, w.current)),
      previous,
    );
    String fmt(num hours) => hoursMinutes(hours * 60);
    return [
      _sourcePicker(sources, source, data),
      Section(
        title: 'Durée par nuit',
        children: [
          ActivityChart(
            points: points,
            unit: 'h',
            format: fmt,
            summary: _summary('Sommeil par nuit', points, stats, fmt),
          ),
          StatLine(
            'Moyenne des nuits renseignées',
            stats.mean == null ? '—' : fmt(stats.mean!),
          ),
          StatLine('Couverture', coverageText(stats)),
          StatLine(
            'Évolution',
            comparisonText(comparison, (m) => hoursMinutes(m)),
          ),
          const SizedBox(height: Space.s),
          Text(
            'Chaque nuit compte une fois, pour le jour du réveil (une nuit de 23:00 '
            'à 07:00 compte pour le second jour). Les périodes couvertes par '
            'plusieurs sessions ne sont comptées qu’une fois.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      Section(
        title: 'Nuits',
        children: [
          for (final day in w.current.reversed)
            if (byDay[day] case final night?)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${longDay(day)} · ${hoursMinutes(night.minutes)}'),
                subtitle: Text(
                  'Coucher ${night.bedtime} · lever ${night.wake}'
                  '${night.stages.isEmpty ? ' · sans phases' : '\n${[for (final s in night.stages.entries) '${sleepStageNames[s.key] ?? 'phase ${s.key}'} ${hoursMinutes(s.value)}'].join(' · ')}'}',
                ),
              )
            else
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(longDay(day)),
                subtitle: const Text('Aucune donnée'),
              ),
        ],
      ),
    ];
  }

  List<Widget> _heart(ActivityController c, HeartData data) {
    final sources = heartSources(data);
    final fallback = defaultHeartSource(data);
    if (fallback == null) {
      return const [Text('Aucune donnée disponible')];
    }
    final source = sources.contains(_source) ? _source! : fallback;
    final w = windows(c.yesterday, _days);
    final points = heartSeries(data, source, w.current, c.today);
    final stats = PeriodStats(points);
    final days = heartDays(data, source);
    final hs = HeartStats([for (final d in w.current) ?days[d]]);
    final comparison = compare(
      stats,
      PeriodStats(heartSeries(data, source, w.previous, c.today)),
    );
    String fmt(num v) => '${v.round()} bpm';
    return [
      _sourcePicker(sources, source, data),
      if (sources.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: Space.s),
          child: Text(
            'Une seule source à la fois : deux sources peuvent mesurer les mêmes moments.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      Section(
        title: 'Fréquence cardiaque par jour',
        children: [
          ActivityChart(
            points: points,
            kind: ChartKind.line,
            unit: 'bpm',
            format: fmt,
            summary: _summary(
              'Fréquence cardiaque moyenne par jour',
              points,
              stats,
              fmt,
            ),
          ),
          Text(
            'Point : moyenne du jour ; trait : minimum et maximum mesurés.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          StatLine(
            'Moyenne des mesures',
            hs.mean == null ? '—' : fmt(hs.mean!),
          ),
          StatLine(
            'Minimum / maximum',
            hs.min == null ? '—' : '${hs.min} / ${hs.max} bpm',
          ),
          StatLine('Nombre de mesures', n0(hs.count)),
          StatLine(
            'Jours avec mesures',
            '${hs.daysWithData} sur ${w.current.length}',
          ),
          StatLine(
            'Couverture horaire moyenne',
            hs.meanHours == null
                ? '—'
                : '${hs.meanHours!.toStringAsFixed(1)} h sur 24',
          ),
          StatLine(
            'Évolution (moyenne quotidienne)',
            comparisonText(comparison, fmt),
          ),
        ],
      ),
      _DayList(points: points, format: fmt),
    ];
  }

  List<Widget> _exercise(ActivityController c, ExerciseData data) {
    final sources = workoutSources(data);
    final source = sources.contains(_source) ? _source! : allSources;
    final w = windows(c.yesterday, _days);
    final sessions = workoutsFor(data, source, w.current);
    final weeks = weeklyWorkouts(sessions, w.current);
    final duplicates = source == allSources
        ? dedupeWorkouts([
            for (final s in data.sessions)
              if (w.current.contains(s.date)) s,
          ]).duplicates
        : 0;
    final points = [
      for (final week in weeks)
        DayPoint(
          week.monday,
          week.minutes,
          week.partial ? DayState.partial : DayState.complete,
        ),
    ];
    String fmt(num m) => hoursMinutes(m);
    return [
      _sourcePicker(sources, source, data),
      Section(
        title: 'Durée par semaine',
        children: [
          ActivityChart(
            points: points,
            unit: 'min',
            format: fmt,
            summary:
                'Entraînements par semaine, ${periodLabel(w.current)} : '
                '${[for (final week in weeks) 'semaine du ${longDay(week.monday)}, ${week.sessions} séance${week.sessions > 1 ? 's' : ''}, ${fmt(week.minutes)}${week.partial ? ' (semaine partielle)' : ''}'].join(' ; ')}.',
          ),
          Text(
            'Semaines du lundi au dimanche ; une semaine coupée par la période est partielle.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          StatLine('Séances', '${sessions.length}'),
          StatLine(
            'Durée totale',
            fmt(sessions.fold(0, (a, s) => a + s.minutes)),
          ),
          if (duplicates > 0)
            StatLine(
              'Doublons écartés',
              '$duplicates (même séance écrite par deux sources)',
            ),
          if (!data.distanceGranted)
            const StatLine('Distance', 'non autorisée dans Health Connect'),
        ],
      ),
      Section(
        title: 'Séances',
        children: [
          if (sessions.isEmpty) const Text('Aucune séance sur la période.'),
          for (final s in sessions)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '${exerciseName(s.type)} · ${hoursMinutes(s.minutes)}',
              ),
              subtitle: Text(
                '${longDay(s.date)} · ${s.startLocal.substring(11)}–${s.endLocal.substring(11)}'
                ' · ${s.distanceMeters == null ? 'distance non fournie' : '${(s.distanceMeters! / 1000).toStringAsFixed(2).replaceAll('.', ',')} km'}'
                '\n${s.source.label}',
              ),
            ),
        ],
      ),
    ];
  }
}

String _summary(
  String title,
  List<DayPoint> points,
  PeriodStats stats,
  String Function(num) fmt,
) {
  if (points.isEmpty) return '$title : aucune journée.';
  final best = points
      .where((p) => p.state == DayState.complete)
      .fold<DayPoint?>(
        null,
        (a, p) => a == null || p.value! > a.value! ? p : a,
      );
  return '$title, ${periodLabel([for (final p in points) p.day])} : '
      '${stats.mean == null ? 'aucune journée complète' : 'moyenne ${fmt(stats.mean!)}'}'
      ', ${coverageText(stats)}'
      '${best == null ? '' : ', maximum ${fmt(best.value!)} le ${longDay(best.day)}'}.';
}

class _DayList extends StatelessWidget {
  const _DayList({required this.points, required this.format});

  final List<DayPoint> points;
  final String Function(num) format;

  @override
  Widget build(BuildContext context) => Section(
    title: 'Jour par jour',
    children: [
      for (final p in points.reversed)
        StatLine(longDay(p.day), switch (p.state) {
          DayState.missing => 'aucune donnée',
          DayState.partial => '${format(p.value!)} (partielle)',
          DayState.complete => format(p.value!),
        }),
    ],
  );
}

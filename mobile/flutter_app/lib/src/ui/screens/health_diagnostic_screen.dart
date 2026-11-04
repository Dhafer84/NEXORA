import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../health/health_service.dart';
import '../../health/health_summary.dart';
import '../theme.dart';
import '../widgets/states.dart';

final _number = NumberFormat.decimalPattern('fr_FR');
String _n(int value) => _number.format(value);
String _day(DateTime day) =>
    DateFormat('EEEE d MMMM yyyy', 'fr_FR').format(day);
String _time(DateTime t) => DateFormat('HH:mm', 'fr_FR').format(t);
String _dayTime(DateTime t) => DateFormat('d MMM HH:mm', 'fr_FR').format(t);
String _duration(int minutes) => minutes >= 60
    ? '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')}'
    : '$minutes min';

/// Prototype of step 5: what Health Connect gives NEXORA on this phone, one
/// category and one finished day at a time. Read in memory for display only.
class HealthDiagnosticScreen extends StatefulWidget {
  const HealthDiagnosticScreen({super.key, required this.service, this.now});

  final HealthService service;

  /// Test hook: the current time.
  final DateTime Function()? now;

  @override
  State<HealthDiagnosticScreen> createState() => _HealthDiagnosticScreenState();
}

class _HealthDiagnosticScreenState extends State<HealthDiagnosticScreen> {
  HealthStatus? _status;
  late DateTime _day;
  final _readings = <HealthCategory, HealthReading>{};
  final _oldest = <HealthCategory, ({DateTime? start, int days})>{};
  final _busy = <HealthCategory>{};

  /// The other categories are tried once a steps read worked.
  bool _stepsWorked = false;

  DateTime get _now => (widget.now ?? DateTime.now)();
  DateTime get _latest => lastFinishedDay(_now);

  @override
  void initState() {
    super.initState();
    _day = _latest;
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final status = await widget.service.status();
    if (mounted) setState(() => _status = status);
  }

  void _setDay(DateTime day) {
    setState(() {
      _day = day;
      _readings.clear();
    });
  }

  Future<void> _authorize(HealthCategory category) async {
    setState(() => _busy.add(category));
    final granted = await widget.service.request(category);
    await _refreshStatus();
    if (!mounted) return;
    setState(() => _busy.remove(category));
    if (granted) {
      await _read(category);
    } else {
      setState(() => _readings[category] = const HealthDenied());
    }
  }

  Future<void> _read(HealthCategory category) async {
    setState(() => _busy.add(category));
    final reading = await widget.service.read(category, _day);
    if (!mounted) return;
    setState(() {
      _busy.remove(category);
      _readings[category] = reading;
      if (category == HealthCategory.steps && reading is HealthData) {
        _stepsWorked = true;
      }
    });
    if (reading is HealthDenied) await _refreshStatus();
  }

  Future<void> _findOldest(HealthCategory category) async {
    setState(() => _busy.add(category));
    DateTime? start;
    try {
      start = await widget.service.oldest(category);
    } catch (_) {
      start = null;
    }
    if (!mounted) return;
    setState(() {
      _busy.remove(category);
      _oldest[category] = (
        start: start,
        days: start == null ? 0 : _now.difference(start).inDays,
      );
    });
  }

  Future<void> _writeSamples() async {
    final messenger = ScaffoldMessenger.of(context);
    final written = await widget.service.writeSamples(_day);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          written < 0
              ? 'Autorisez l’écriture, puis appuyez de nouveau.'
              : '$written entrées d’essai écrites pour ${_day.day}/${_day.month}.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostic santé')),
      body: status == null
          ? const LoadingView(label: 'Recherche de Health Connect…')
          // A few cards only: all built, so a state is never lost on scroll.
          : SingleChildScrollView(
              padding: const EdgeInsets.all(Space.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const NoticeBar(
                    tone: 'neutral',
                    message:
                        'Prototype local : les données lues restent sur ce '
                        'téléphone. Elles ne sont ni enregistrées, ni envoyées '
                        'au serveur NEXORA ou à l’IA.',
                  ),
                  const SizedBox(height: Space.l),
                  if (status.sdk != HealthSdk.available)
                    _Unavailable(status: status, service: widget.service)
                  else ...[
                    _DayPicker(
                      day: _day,
                      latest: _latest,
                      zone: status.zone,
                      offset: status.offset,
                      onChanged: _setDay,
                    ),
                    for (final category in HealthCategory.values)
                      _CategoryCard(
                        category: category,
                        granted: status.granted.contains(category),
                        locked:
                            category != HealthCategory.steps && !_stepsWorked,
                        busy: _busy.contains(category),
                        reading: _readings[category],
                        oldest: _oldest[category],
                        historyGranted: status.historyGranted,
                        onAuthorize: () => _authorize(category),
                        onRead: () => _read(category),
                        onOldest: () => _findOldest(category),
                        onSettings: widget.service.openSettings,
                      ),
                    if (status.debugSamples) ...[
                      const SizedBox(height: Space.l),
                      OutlinedButton.icon(
                        onPressed: _writeSamples,
                        icon: const Icon(Icons.science_rounded),
                        label: const Text(
                          'Écrire des données d’essai (débogage)',
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.status, required this.service});

  final HealthStatus status;
  final HealthService service;

  @override
  Widget build(BuildContext context) {
    final update = status.sdk == HealthSdk.updateRequired;
    return MessageView(
      icon: Icons.health_and_safety_rounded,
      title: update
          ? 'Health Connect doit être mis à jour'
          : 'Health Connect indisponible',
      body: update
          ? 'Mettez à jour Health Connect, puis revenez sur cet écran.'
          : 'Health Connect n’est pas installé ou pas pris en charge sur ce '
                'téléphone. Il est intégré à Android 14 et plus ; avant, il '
                's’installe depuis le Play Store.',
      action: update
          ? FilledButton(
              onPressed: service.openSettings,
              child: const Text('Mettre à jour'),
            )
          : null,
    );
  }
}

class _DayPicker extends StatelessWidget {
  const _DayPicker({
    required this.day,
    required this.latest,
    required this.zone,
    required this.offset,
    required this.onChanged,
  });

  final DateTime day;
  final DateTime latest;
  final String zone;
  final String offset;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLatest = !day.isBefore(latest);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Jour précédent',
                  onPressed: () =>
                      onChanged(DateTime(day.year, day.month, day.day - 1)),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Expanded(
                  child: Text(
                    _day(day),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Jour suivant',
                  // Only finished days: today is still being counted.
                  onPressed: isLatest
                      ? null
                      : () => onChanged(
                          DateTime(day.year, day.month, day.day + 1),
                        ),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.m),
              child: Text(
                'Journée terminée, de 00:00 à 24:00 · fuseau $zone '
                '(UTC$offset)',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.category,
    required this.granted,
    required this.locked,
    required this.busy,
    required this.reading,
    required this.oldest,
    required this.historyGranted,
    required this.onAuthorize,
    required this.onRead,
    required this.onOldest,
    required this.onSettings,
  });

  final HealthCategory category;
  final bool granted;
  final bool locked;
  final bool busy;
  final HealthReading? reading;
  final ({DateTime? start, int days})? oldest;
  final bool historyGranted;
  final VoidCallback onAuthorize;
  final VoidCallback onRead;
  final VoidCallback onOldest;
  final VoidCallback onSettings;

  IconData get _icon => switch (category) {
    HealthCategory.steps => Icons.directions_walk_rounded,
    HealthCategory.sleep => Icons.bedtime_rounded,
    HealthCategory.heartRate => Icons.favorite_rounded,
    HealthCategory.exercise => Icons.fitness_center_rounded,
  };

  (String, String) get _state => switch (reading) {
    HealthData(isEmpty: true) => ('Aucune donnée', 'neutral'),
    HealthData() => ('Données lues', 'ok'),
    HealthDenied() => ('Permission refusée', 'error'),
    HealthUnavailable() => ('Indisponible', 'error'),
    HealthFailed() || HealthRangeRaw() => ('Erreur de lecture', 'error'),
    null when !granted => ('Non autorisée', 'neutral'),
    null => ('Autorisée', 'neutral'),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (stateLabel, tone) = _state;
    final reading = this.reading;
    return Card(
      margin: const EdgeInsets.only(top: Space.l),
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_icon, color: theme.colorScheme.primary),
                const SizedBox(width: Space.m),
                Expanded(
                  child: Text(
                    category.label,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                StatusChip(label: stateLabel, tone: tone),
              ],
            ),
            const SizedBox(height: Space.m),
            if (locked)
              Text(
                'À tester après une lecture des pas réussie.',
                style: theme.textTheme.bodyMedium,
              )
            else ...[
              if (reading != null) ...[
                _ReadingView(reading: reading, onSettings: onSettings),
                const SizedBox(height: Space.m),
              ],
              if (busy)
                const LinearProgressIndicator()
              else
                Wrap(
                  spacing: Space.s,
                  runSpacing: Space.s,
                  children: [
                    if (!granted)
                      FilledButton.icon(
                        onPressed: onAuthorize,
                        icon: const Icon(Icons.lock_open_rounded),
                        label: Text(
                          'Autoriser la lecture : ${category.label.toLowerCase()}',
                        ),
                      )
                    else ...[
                      FilledButton.icon(
                        onPressed: onRead,
                        icon: const Icon(Icons.download_rounded),
                        label: Text(
                          reading == null ? 'Lire la journée' : 'Relire',
                        ),
                      ),
                      OutlinedButton(
                        onPressed: onOldest,
                        child: const Text('Historique accessible'),
                      ),
                    ],
                  ],
                ),
              if (oldest != null) ...[
                const SizedBox(height: Space.m),
                _OldestView(
                  start: oldest!.start,
                  days: oldest!.days,
                  historyGranted: historyGranted,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _OldestView extends StatelessWidget {
  const _OldestView({
    required this.start,
    required this.days,
    required this.historyGranted,
  });

  final DateTime? start;
  final int days;
  final bool historyGranted;

  @override
  Widget build(BuildContext context) {
    final start = this.start;
    final text = start == null
        ? 'Aucune entrée lisible dans l’historique.'
        : 'Plus ancienne entrée lisible : ${DateFormat('d MMMM yyyy', 'fr_FR').format(start)} '
              '(il y a ${days < 1
                  ? 'moins d’un jour'
                  : days == 1
                  ? '1 jour'
                  : '$days jours'}). '
              '${historyGranted ? '' : 'Sans l’autorisation « historique », Health Connect limite la lecture aux 30 jours précédant la première autorisation.'}';
    return Text(text.trim(), style: Theme.of(context).textTheme.bodySmall);
  }
}

class _ReadingView extends StatelessWidget {
  const _ReadingView({required this.reading, required this.onSettings});

  final HealthReading reading;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => switch (reading) {
    HealthDenied() => NoticeBar(
      tone: 'error',
      message:
          'Lecture refusée. Health Connect ne redemande plus après deux refus : '
          'autorisez NEXORA dans Health Connect, puis revenez.',
      actionLabel: 'Ouvrir Health Connect',
      onAction: onSettings,
    ),
    HealthUnavailable() => const NoticeBar(
      tone: 'error',
      message: 'Health Connect ne répond pas. Réessayez plus tard.',
    ),
    HealthRangeRaw() => const SizedBox.shrink(),
    HealthFailed(:final code) => NoticeBar(
      tone: 'error',
      message: 'La lecture a échoué ($code). Aucune donnée n’a été conservée.',
    ),
    final HealthData data when data.isEmpty => Text(
      'Aucune donnée disponible',
      style: Theme.of(context).textTheme.titleMedium,
    ),
    final HealthData data => switch (data.category) {
      HealthCategory.steps => _StepsView(data: data),
      HealthCategory.sleep => _SleepView(data: data),
      HealthCategory.heartRate => _HeartView(data: data),
      HealthCategory.exercise => _ExerciseView(data: data),
    },
  };
}

/// Source lines shared by all categories.
class _Sources extends StatelessWidget {
  const _Sources({required this.summary, required this.unit});

  final SourceSummary summary;
  final String Function(SourceGroup) unit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Sources des entrées', style: theme.textTheme.labelLarge),
        for (final g in summary.groups)
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(g.label, style: theme.textTheme.bodyMedium),
                      Text(
                        '${_kind(g.kind)} · ${g.entries} entrée${g.entries > 1 ? 's' : ''} '
                        '· ${_time(g.first)}–${_time(g.last)}',
                        style: theme.textTheme.bodySmall,
                      ),
                      // The package, to check which app really wrote it.
                      if (g.origin != g.app)
                        Text(g.origin, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                Text(unit(g), style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
      ],
    );
  }

  static String _kind(SourceKind kind) => switch (kind) {
    // The app that wrote the entry; the device is named only by the entry's
    // own metadata (see SourceGroup.label).
    SourceKind.healthSync => 'Health Sync',
    SourceKind.phone => 'Téléphone',
    SourceKind.nexora => 'Essai NEXORA',
    SourceKind.otherApp => 'Autre application',
  };
}

class _Overlaps extends StatelessWidget {
  const _Overlaps({required this.summary, required this.what});

  final SourceSummary summary;
  final String what;

  @override
  Widget build(BuildContext context) {
    if (summary.overlaps.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Space.m),
      child: NoticeBar(
        tone: 'warning',
        message:
            '${summary.overlaps.map((o) => '${o.a.label} et ${o.b.label} '
                'couvrent les mêmes ${_duration(o.minutes)}').join(' ; ')} : ne pas '
            'additionner les $what de ces sources.',
      ),
    );
  }
}

class _StepsView extends StatelessWidget {
  const _StepsView({required this.data});

  final HealthData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = SourceSummary.of(data.entries);
    final sync = summary.healthSyncTotal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          sync != null
              ? '${_n(sync)} pas'
              : '${_n(data.total ?? summary.sum)} pas',
          style: theme.textTheme.headlineMedium,
        ),
        Text(
          sync != null
              ? 'Entrées de Health Sync : le chiffre à comparer avec Huawei Health.'
              : 'Aucune entrée de Health Sync pour cette journée.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: Space.m),
        _Line('Date', '${_day(data.day)} · fuseau ${data.zone}'),
        if (data.total != null)
          _Line(
            'Total Health Connect',
            '${_n(data.total!)} pas (doublons retirés selon l’ordre de priorité '
                'des applications)',
          ),
        if (summary.groups.length > 1)
          _Line('Somme brute des sources', '${_n(summary.sum)} pas'),
        if (data.truncated)
          const _Line(
            'Attention',
            'plus de 20 000 entrées : lecture partielle',
          ),
        const SizedBox(height: Space.m),
        _Sources(summary: summary, unit: (g) => '${_n(g.total)} pas'),
        _Overlaps(summary: summary, what: 'pas'),
      ],
    );
  }
}

class _SleepView extends StatelessWidget {
  const _SleepView({required this.data});

  final HealthData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = SourceSummary.of(data.entries);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Nuit se terminant le ${_day(data.day)}',
          style: theme.textTheme.bodySmall,
        ),
        for (final e in data.entries)
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_dayTime(e.start)} → ${_time(e.end)} · ${_duration(e.value)}',
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  e.stages.isEmpty
                      ? 'Sans phases'
                      : [
                          for (final s in e.stages.entries)
                            '${sleepStageNames[s.key] ?? 'phase ${s.key}'} ${_duration(s.value)}',
                        ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        const SizedBox(height: Space.m),
        _Sources(summary: summary, unit: (g) => _duration(g.total)),
        _Overlaps(summary: summary, what: 'durées'),
      ],
    );
  }
}

class _HeartView extends StatelessWidget {
  const _HeartView({required this.data});

  final HealthData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = SourceSummary.of(data.entries);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (data.avg != null)
          Text(
            '${data.avg} bpm en moyenne',
            style: theme.textTheme.headlineSmall,
          ),
        _Line(
          'Minimum / maximum',
          '${data.min ?? '–'} / ${data.max ?? '–'} bpm',
        ),
        _Line('Mesures', _n(data.samples ?? summary.sum)),
        _Line('Date', '${_day(data.day)} · fuseau ${data.zone}'),
        const SizedBox(height: Space.m),
        _Sources(summary: summary, unit: (g) => '${_n(g.total)} mesures'),
      ],
    );
  }
}

class _ExerciseView extends StatelessWidget {
  const _ExerciseView({required this.data});

  final HealthData data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = SourceSummary.of(data.entries);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in data.entries)
          Padding(
            padding: const EdgeInsets.only(top: Space.s),
            child: Text(
              '${exerciseName(e.exerciseType)} · ${_time(e.start)}–${_time(e.end)} '
              '· ${_duration(e.value)}',
              style: theme.textTheme.bodyLarge,
            ),
          ),
        const SizedBox(height: Space.m),
        _Sources(summary: summary, unit: (g) => _duration(g.total)),
        _Overlaps(summary: summary, what: 'entraînements'),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.xs),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label : ',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(text: value),
        ],
      ),
    ),
  );
}

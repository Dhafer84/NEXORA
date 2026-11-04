import 'package:flutter/material.dart';

import '../../activity/activity_controller.dart';
import '../../activity/activity_models.dart';
import '../../activity/activity_stats.dart';
import '../../activity/activity_store.dart';
import '../../health/health_service.dart';
import '../../state/app_state.dart';
import '../screens/health_diagnostic_screen.dart';
import '../theme.dart';
import '../widgets/header.dart';
import '../widgets/states.dart';
import 'activity_chart.dart';
import 'activity_views.dart';
import 'analysis_screen.dart';
import 'export_screen.dart';

/// Activité tab: steps, sleep, heart rate and workouts read from Health
/// Connect, each with its own permission. Figures are computed and kept on
/// the phone; nothing goes to the server unless « Analyser avec l’IA » is
/// confirmed.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key, this.now});

  /// Test hook: the current time.
  final DateTime Function()? now;

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  ActivityController? _controller;
  bool _loaded = false;

  /// Reading again on opening the tab when the copy is older than this.
  static const _stale = Duration(minutes: 30);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final state = AppScope.read(context);
    final controller = _controller = ActivityController(
      service: state.health!,
      store: state.activityStore ?? MemoryActivityStore(),
      now: widget.now,
    );
    controller.load().then((_) async {
      if (!mounted) return;
      setState(() => _loaded = true);
      final last = controller.lastRead;
      final now = (widget.now ?? DateTime.now)();
      final granted = controller.status?.granted.isNotEmpty ?? false;
      // Foreground read only, of categories already allowed.
      if (granted && (last == null || now.difference(last) > _stale)) {
        await controller.refreshAll();
      }
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _clear() async {
    final controller = _controller!;
    final files = AppScope.read(context).files;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Effacer les données de NEXORA ?'),
        content: const Text(
          'NEXORA oublie les chiffres qu’il a gardés sur ce téléphone (dernières '
          'lectures). Les données de Health Connect, de Health Sync et de Huawei '
          'Health ne sont pas touchées, et les autorisations restent telles '
          'quelles (à retirer dans Health Connect si vous le souhaitez).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Effacer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await controller.clearLocal();
    // The temporary copy of a shared export goes too.
    try {
      await files?.purgeExports();
    } on Exception {
      // Nothing to remove.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Données locales de NEXORA effacées. Health Connect est inchangé.',
        ),
      ),
    );
  }

  void _open(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    final health = AppScope.read(context).health!;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final busy = HealthCategory.values.any((c) => controller[c].busy);
        final hasData = HealthCategory.values.any(
          (c) => controller[c].data != null,
        );
        return Scaffold(
          appBar: AppBar(
            title: const Text('Activité'),
            actions: headerActions(
              extra: [
                IconButton(
                  tooltip: 'Actualiser',
                  onPressed: busy || !_loaded ? null : controller.refreshAll,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Plus d’options',
                  onSelected: (value) => switch (value) {
                    'export' => _open(ExportScreen(controller: controller)),
                    'diagnostic' => _open(
                      HealthDiagnosticScreen(service: health),
                    ),
                    'clear' => _clear(),
                    _ => null,
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'export',
                      enabled: hasData,
                      child: const Text('Exporter (CSV ou JSON)'),
                    ),
                    const PopupMenuItem(
                      value: 'diagnostic',
                      child: Text('Diagnostic et sources'),
                    ),
                    const PopupMenuItem(
                      value: 'clear',
                      child: Text('Effacer les données de NEXORA'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          body: !_loaded
              ? const LoadingView(
                  label: 'Lecture des données gardées sur ce téléphone…',
                )
              : !controller.available
              ? MessageView(
                  icon: Icons.health_and_safety_rounded,
                  title: 'Health Connect indisponible',
                  body:
                      'Installez ou mettez à jour Health Connect, puis revenez. Le '
                      'diagnostic donne le détail.',
                  action: OutlinedButton(
                    onPressed: () =>
                        _open(HealthDiagnosticScreen(service: health)),
                    child: const Text('Ouvrir le diagnostic'),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: controller.refreshAll,
                  child: ListView(
                    padding: const EdgeInsets.all(Space.l),
                    children: [
                      if (busy) const LinearProgressIndicator(),
                      _Header(controller: controller),
                      for (final category in HealthCategory.values)
                        _CategoryCard(
                          controller: controller,
                          category: category,
                          onOpen: () => _open(
                            CategoryScreen(
                              controller: controller,
                              category: category,
                            ),
                          ),
                        ),
                      const SizedBox(height: Space.l),
                      FilledButton.icon(
                        onPressed: hasData
                            ? () =>
                                  _open(AnalysisScreen(controller: controller))
                            : null,
                        icon: const Icon(Icons.auto_awesome_rounded),
                        label: const Text('Analyser avec l’IA'),
                      ),
                      const SizedBox(height: Space.s),
                      OutlinedButton.icon(
                        onPressed: hasData
                            ? () => _open(ExportScreen(controller: controller))
                            : null,
                        icon: const Icon(Icons.ios_share_rounded),
                        label: const Text('Exporter pour ChatGPT'),
                      ),
                      if (controller.status?.debugSamples ?? false) ...[
                        const SizedBox(height: Space.s),
                        TextButton.icon(
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.of(context);
                            final written = await health.writeHistory(45);
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  written < 0
                                      ? 'Autorisez l’écriture, puis appuyez de nouveau.'
                                      : '$written entrées d’essai écrites (45 jours).',
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.science_rounded),
                          label: const Text('Historique d’essai (débogage)'),
                        ),
                      ],
                    ],
                  ),
                ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final ActivityController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = controller.lastRead;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              last == null
                  ? 'Aucune lecture réussie pour l’instant'
                  : 'Dernière lecture réussie : ${longDay(keyOf(last))} à '
                        '${last.hour.toString().padLeft(2, '0')}:${last.minute.toString().padLeft(2, '0')}',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: Space.xs),
            Text(
              'Chaque actualisation relit les $windowDays derniers jours (fuseau '
              '${controller.status?.zone ?? '—'}). Health Connect donne accès aux 30 jours '
              'précédant la première autorisation, puis à tout ce qui suit. Les chiffres '
              'restent sur ce téléphone.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.controller,
    required this.category,
    required this.onOpen,
  });

  final ActivityController controller;
  final HealthCategory category;
  final VoidCallback onOpen;

  (String, String) _chip(CategoryState state) => switch (state.issue) {
    Issue.notAuthorized => ('Non autorisée', 'neutral'),
    Issue.revoked => ('Autorisation retirée', 'error'),
    Issue.unavailable => ('Indisponible', 'error'),
    Issue.failed => ('Erreur de lecture', 'warning'),
    null when state.data == null => ('À lire', 'neutral'),
    null => ('Données lues', 'ok'),
  };

  /// Headline and the last 7 days, for the card.
  (String, List<DayPoint>?) _headline() {
    final data = controller[category].data;
    final w = windows(controller.yesterday, 7).current;
    switch (data) {
      case StepsData():
        final points = stepsSeries(
          data,
          defaultStepsSource(data),
          w,
          controller.today,
        );
        final mean = PeriodStats(points).mean;
        return (
          mean == null
              ? 'Aucune journée complète sur 7 jours'
              : '${n0(mean)} pas / jour en moyenne (7 jours)',
          points,
        );
      case SleepData():
        final byDay = nights(data, defaultSleepSource(data));
        final last = byDay[controller.today] ?? byDay[controller.yesterday];
        final points = sleepSeries(byDay, windows(controller.today, 7).current)
            .map(
              (p) => DayPoint(
                p.day,
                p.value == null ? null : p.value! / 60,
                p.state,
              ),
            )
            .toList();
        return (
          last == null
              ? 'Pas de nuit récente'
              : 'Dernière nuit : ${hoursMinutes(last.minutes)} (${last.bedtime}–${last.wake})',
          points,
        );
      case HeartData():
        final source = defaultHeartSource(data);
        if (source == null) return ('Aucune mesure', null);
        final days = heartDays(data, source);
        final stats = HeartStats([for (final d in w) ?days[d]]);
        return (
          stats.mean == null
              ? 'Aucune mesure sur 7 jours'
              : '${stats.mean!.round()} bpm en moyenne (7 jours, ${n0(stats.count)} mesures)',
          heartSeries(data, source, w, controller.today),
        );
      case ExerciseData():
        final sessions = workoutsFor(data, allSources, w);
        return (
          '${sessions.length} séance${sessions.length > 1 ? 's' : ''} sur 7 jours · '
              '${hoursMinutes(sessions.fold(0, (a, s) => a + s.minutes))}',
          null,
        );
      default:
        return ('', null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = controller[category];
    final (label, tone) = _chip(state);
    final (headline, points) = state.data == null ? ('', null) : _headline();
    final issue = issueText(state);
    return Card(
      margin: const EdgeInsets.only(top: Space.l),
      child: InkWell(
        onTap: state.data == null ? null : onOpen,
        borderRadius: BorderRadius.circular(Radii.l),
        child: Padding(
          padding: const EdgeInsets.all(Space.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    categoryIcon(category),
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: Space.m),
                  Expanded(
                    child: Text(
                      category.label,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  StatusChip(label: label, tone: tone),
                ],
              ),
              if (headline.isNotEmpty) ...[
                const SizedBox(height: Space.s),
                Text(headline, style: theme.textTheme.bodyLarge),
              ],
              if (points != null && points.isNotEmpty) ...[
                const SizedBox(height: Space.s),
                ActivityChart(
                  points: points,
                  height: 90,
                  kind: category == HealthCategory.heartRate
                      ? ChartKind.line
                      : ChartKind.bars,
                  unit: switch (category) {
                    HealthCategory.steps => 'pas',
                    HealthCategory.sleep => 'h',
                    _ => 'bpm',
                  },
                  format: switch (category) {
                    HealthCategory.steps => (v) => '${n0(v)} pas',
                    HealthCategory.sleep => (v) => hoursMinutes(v * 60),
                    _ => (v) => '${v.round()} bpm',
                  },
                  summary: '${category.label}, 7 derniers jours : $headline.',
                ),
              ],
              if (issue != null && state.issue != Issue.notAuthorized) ...[
                const SizedBox(height: Space.s),
                Text(issue, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: Space.s),
              Wrap(
                spacing: Space.s,
                children: [
                  if (state.issue == Issue.notAuthorized ||
                      state.issue == Issue.revoked)
                    FilledButton.icon(
                      onPressed: state.busy
                          ? null
                          : () => controller.authorize(category),
                      icon: const Icon(Icons.lock_open_rounded),
                      label: Text(
                        'Autoriser : ${category.label.toLowerCase()}',
                      ),
                    ),
                  if (state.data != null)
                    TextButton(
                      onPressed: onOpen,
                      child: const Text('Voir le détail'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

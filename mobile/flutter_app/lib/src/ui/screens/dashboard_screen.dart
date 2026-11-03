import 'package:flutter/material.dart';

import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../format.dart';
import '../widgets/states.dart';

/// Each probe is loaded and reported independently: one refusal or failure
/// never hides the others.
class _Probe<T> {
  T? value;
  ApiError? error;
  bool loading = true;
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _live = _Probe<bool>();
  final _ready = _Probe<bool>();
  final _metrics = _Probe<ServerMetrics>();
  final _ai = _Probe<AiStatus>();
  final _github = _Probe<GitHubReport>();
  DateTime? _checkedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _probe<T>(_Probe<T> probe, Future<T> Function() call) async {
    setState(() => probe.loading = true);
    T? value;
    ApiError? failure;
    try {
      value = await call();
    } on ApiError catch (error) {
      failure = error;
    }
    if (!mounted) return;
    setState(() {
      probe
        ..value = value
        ..error = failure
        ..loading = false;
    });
  }

  Future<void> _load() async {
    final api = AppScope.read(context).api;
    await Future.wait([
      _probe(_live, () async {
        await api.live();
        return true;
      }),
      _probe(_ready, () async {
        await api.ready();
        return true;
      }),
      _probe(_metrics, api.metrics),
      _probe(_ai, api.aiStatus),
      _probe(_github, api.github),
    ]);
    if (mounted) setState(() => _checkedAt = DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    final metrics = _metrics.value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tableau de bord'),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _StatusTile(
              icon: Icons.cloud_done_outlined,
              title: 'Serveur NEXORA',
              probe: _live,
              okText: 'Disponible',
            ),
            const SizedBox(height: 8),
            _StatusTile(
              icon: Icons.storage_outlined,
              title: 'Base PostgreSQL',
              probe: _ready,
              okText: 'Disponible',
            ),
            const SizedBox(height: 8),
            _Section(
              title: 'Ressources du serveur',
              icon: Icons.speed,
              loading: _metrics.loading && metrics == null,
              error: _metrics.error,
              child: metrics == null
                  ? null
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Gauge(
                          label: 'Processeur',
                          percent: metrics.cpuPercent,
                        ),
                        _Gauge(
                          label: 'Mémoire',
                          percent: metrics.memory.usedPercent,
                          detail:
                              '${formatBytes(metrics.memory.usedBytes)} utilisés sur '
                              '${formatBytes(metrics.memory.totalBytes)}',
                        ),
                        _Gauge(
                          label: 'Disque',
                          percent: metrics.disk.usedPercent,
                          detail:
                              '${formatBytes(metrics.disk.availableBytes)} libres sur '
                              '${formatBytes(metrics.disk.totalBytes)}',
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Mesuré ${formatShort(metrics.observedAt)} · '
                          '${metrics.scope == 'host' ? 'serveur Ubuntu' : 'environnement du conteneur'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 8),
            _Section(
              title: 'Assistant IA',
              icon: Icons.smart_toy_outlined,
              loading: _ai.loading && _ai.value == null,
              error: _ai.error,
              child: _ai.value == null ? null : _AiDetails(status: _ai.value!),
            ),
            const SizedBox(height: 8),
            _Section(
              title: 'Projets GitHub',
              icon: Icons.code,
              loading: _github.loading && _github.value == null,
              error: _github.error,
              child: _github.value == null
                  ? null
                  : _GitHubDetails(report: _github.value!),
            ),
            if (_checkedAt != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Dernière vérification ${formatShort(_checkedAt!)}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.icon,
    required this.title,
    required this.probe,
    required this.okText,
  });

  final IconData icon;
  final String title;
  final _Probe<bool> probe;
  final String okText;

  @override
  Widget build(BuildContext context) {
    final error = probe.error;
    final (label, tone) = probe.loading && probe.value == null && error == null
        ? ('Vérification…', 'neutral')
        : error == null
        ? (okText, 'ok')
        : switch (error.kind) {
            ApiErrorKind.forbidden => ('Accès refusé', 'warning'),
            ApiErrorKind.unavailable => ('Indisponible', 'error'),
            _ => ('Injoignable', 'error'),
          };
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: error == null ? null : Text(error.message),
        trailing: StatusChip(label: label, tone: tone),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.loading,
    this.error,
    this.child,
  });

  final String title;
  final IconData icon;
  final bool loading;
  final ApiError? error;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (loading)
            const LinearProgressIndicator()
          else if (error != null)
            NoticeBar(
              tone: error!.kind == ApiErrorKind.forbidden ? 'warning' : 'error',
              message: error!.message,
            )
          else
            ?child,
        ],
      ),
    ),
  );
}

class _Gauge extends StatelessWidget {
  const _Gauge({required this.label, required this.percent, this.detail});

  final String label;
  final double percent;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final high = percent >= 90;
    return Semantics(
      label: '$label : ${formatPercent(percent)}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(label)),
                Text(
                  formatPercent(percent),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: high ? scheme.error : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (percent / 100).clamp(0, 1),
                minHeight: 8,
                color: high ? scheme.error : scheme.primary,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            if (detail != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  detail!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AiDetails extends StatelessWidget {
  const _AiDetails({required this.status});

  final AiStatus status;

  @override
  Widget build(BuildContext context) {
    final provider = status.provider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            StatusChip(
              label: provider == null
                  ? 'Aucun fournisseur'
                  : status.configured
                  ? 'Configuré'
                  : 'Clé absente',
              tone: provider != null && status.configured ? 'ok' : 'warning',
            ),
            if (provider != null && !provider.real)
              const StatusChip(
                label: 'Simulation — pas une IA réelle',
                tone: 'warning',
              ),
          ],
        ),
        if (provider != null) ...[
          const SizedBox(height: 8),
          Text('Modèle : ${provider.model}'),
        ],
        const SizedBox(height: 4),
        Text(status.detail),
        const SizedBox(height: 8),
        Text(
          'Une clé présente sur le serveur ne garantit pas qu’elle soit valide : '
          'seule une conversation le confirme.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _GitHubDetails extends StatelessWidget {
  const _GitHubDetails({required this.report});

  final GitHubReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!report.configured) {
      return const Text(
        'Aucun dépôt autorisé sur le serveur (NEXORA_GITHUB_REPOS). '
        'Lecture seule : NEXORA ne modifie jamais GitHub.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final repo in report.repos)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(repo.repo, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                if (!repo.available)
                  NoticeBar(
                    tone: 'warning',
                    message: repo.error ?? 'Indisponible',
                  )
                else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (repo.runs.isNotEmpty) _runChip(repo.runs.first),
                      StatusChip(
                        label: '${repo.openIssues ?? 0} issue(s) ouverte(s)',
                        icon: Icons.bug_report_outlined,
                      ),
                    ],
                  ),
                  if (repo.commits.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Dernier commit ${repo.commits.first.date == null ? '' : formatShort(repo.commits.first.date!)} : '
                      '${repo.commits.first.message}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ],
            ),
          ),
      ],
    );
  }

  static Widget _runChip(GitHubRun run) {
    final name = run.name ?? 'GitHub Actions';
    return switch (run.conclusion) {
      'success' => StatusChip(
        label: '$name : réussi',
        tone: 'ok',
        icon: Icons.check,
      ),
      null => StatusChip(label: '$name : en cours', icon: Icons.timelapse),
      _ => StatusChip(
        label:
            '$name : ${run.conclusion == 'failure' ? 'échec' : run.conclusion}',
        tone: 'error',
        icon: Icons.close,
      ),
    };
  }
}

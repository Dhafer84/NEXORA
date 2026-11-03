import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../alerts/background_alerts.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/states.dart';
import 'files_screen.dart';

String intervalLabel(int minutes) => switch (minutes) {
  60 => 'toutes les heures',
  1440 => 'une fois par jour, à minuit',
  < 60 => 'toutes les $minutes min',
  _ => 'toutes les ${minutes ~/ 60} h',
};

String thresholdLabel(double value) =>
    '${NumberFormat('0.##', 'fr_FR').format(value)}\u00a0%';

String runStatusLabel(String status) => switch (status) {
  'ok' => 'Sous le seuil',
  'alert' => 'Seuil atteint',
  'failed' => 'Échec',
  _ => status,
};

String runTone(String status) => switch (status) {
  'ok' => 'ok',
  'alert' => 'warning',
  'failed' => 'error',
  _ => 'neutral',
};

/// Scheduled checks and phone alerts.
class AutomationsScreen extends StatefulWidget {
  const AutomationsScreen({super.key});

  @override
  State<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends State<AutomationsScreen> {
  List<Automation>? _items;
  ApiError? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await AppScope.read(context).api.automations();
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
        _loading = false;
      });
    } on ApiError catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    final created = await Navigator.of(context).push<Automation>(
      MaterialPageRoute(builder: (_) => const AutomationFormScreen()),
    );
    await _load();
    if (created != null && mounted) await _open(created.id);
  }

  Future<void> _open(String id) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => AutomationDetailScreen(id: id)),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final Widget list;
    if (items == null && _loading) {
      list = const LoadingView();
    } else if (items == null) {
      list = ErrorView(error: _error!, onRetry: _load);
    } else {
      list = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
          children: [
            const PhoneAlertsCard(),
            const SizedBox(height: 8),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: NoticeBar(tone: 'error', message: _error!.message),
              ),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: MessageView(
                  icon: Icons.schedule,
                  title: 'Aucune automatisation',
                  body:
                      'Programmez une vérification de l’espace disque du '
                      'serveur et recevez une alerte au-delà d’un seuil.',
                  action: FilledButton.icon(
                    onPressed: _create,
                    icon: const Icon(Icons.add),
                    label: const Text('Programmer la vérification'),
                  ),
                ),
              ),
            for (final item in items)
              _AutomationCard(automation: item, onTap: () => _open(item.id)),
            if (AppScope.of(context).files != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.drive_file_move_outline),
                  title: const Text('Classer des fichiers du téléphone'),
                  subtitle: const Text(
                    'Propositions de rangement, chacune validée par vous.',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(builder: (_) => const FilesScreen()),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Automatisations'),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: list,
      floatingActionButton: items == null || items.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('Nouvelle'),
            ),
    );
  }
}

class _AutomationCard extends StatelessWidget {
  const _AutomationCard({required this.automation, required this.onTap});

  final Automation automation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = automation.lastRun;
    final next = automation.nextRunAt;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.storage_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      automation.name,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: _chips(automation)),
              const SizedBox(height: 8),
              Text(
                'Seuil ${thresholdLabel(automation.thresholdPercent)}, '
                '${intervalLabel(automation.intervalMinutes)}',
              ),
              Text(
                next == null
                    ? 'Suspendue : aucune vérification programmée'
                    : 'Prochaine vérification ${formatShort(next)}',
              ),
              if (last != null)
                Text(
                  'Dernière : ${last.measuredPercent == null ? runStatusLabel(last.status) : formatPercent(last.measuredPercent!)}'
                  ' ${formatShort(last.startedAt)}',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

List<Widget> _chips(Automation automation) => [
  automation.enabled
      ? const StatusChip(label: 'Active', tone: 'ok', icon: Icons.schedule)
      : const StatusChip(
          label: 'Suspendue',
          tone: 'neutral',
          icon: Icons.pause_circle_outline,
        ),
  if (automation.alertActive)
    const StatusChip(
      label: 'Au-dessus du seuil',
      tone: 'warning',
      icon: Icons.warning_amber,
    ),
  if (automation.failing)
    const StatusChip(
      label: 'Mesure impossible',
      tone: 'error',
      icon: Icons.error_outline,
    ),
];

/// Turns phone alerts on or off and explains what they depend on.
class PhoneAlertsCard extends StatefulWidget {
  const PhoneAlertsCard({super.key});

  @override
  State<PhoneAlertsCard> createState() => _PhoneAlertsCardState();
}

class _PhoneAlertsCardState extends State<PhoneAlertsCard> {
  AlertsStatus? _status;
  String? _problem;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final alerts = AppScope.read(context).alerts;
    if (alerts == null) return;
    final status = await alerts.status();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _toggle(bool on) async {
    final alerts = AppScope.read(context).alerts;
    if (alerts == null) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    String? problem;
    try {
      if (on) {
        problem = await alerts.enable();
      } else {
        await alerts.disable();
      }
    } on Object {
      problem = 'Réglage des alertes impossible. Réessayez.';
    }
    final status = await alerts.status();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _problem = problem;
      _status = status;
    });
  }

  @override
  Widget build(BuildContext context) {
    final alerts = AppScope.of(context).alerts;
    final status = _status;
    final theme = Theme.of(context);
    final String subtitle;
    if (alerts == null) {
      subtitle = 'Indisponible sur cet appareil.';
    } else if (status == null) {
      subtitle = 'Lecture du réglage…';
    } else if (status.enabled && !status.permitted) {
      subtitle =
          'Activées dans NEXORA mais bloquées par Android : autorisez les '
          'notifications de NEXORA dans les paramètres du téléphone.';
    } else if (status.enabled) {
      subtitle =
          'Activées : le téléphone interroge le serveur environ toutes les '
          '15 minutes, même application fermée.';
    } else {
      subtitle =
          'Désactivées : les alertes restent visibles dans l’historique.';
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.notifications_active_outlined),
              title: const Text('Alertes sur ce téléphone'),
              subtitle: Text(subtitle),
              value: status?.enabled ?? false,
              onChanged: alerts == null || status == null || _busy
                  ? null
                  : _toggle,
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: NoticeBar(tone: 'error', message: _problem!),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                'Le délai peut atteindre 15 à 30 minutes, davantage en économie '
                'd’énergie. Tailscale doit rester connecté. Sur Huawei, réglez '
                'NEXORA en « Gestion manuelle » dans Lancement des applications. '
                'Un arrêt forcé de NEXORA suspend les alertes jusqu’à sa réouverture.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One automation: summary, manual check, history and actions.
class AutomationDetailScreen extends StatefulWidget {
  const AutomationDetailScreen({super.key, required this.id});

  final String id;

  @override
  State<AutomationDetailScreen> createState() => _AutomationDetailScreenState();
}

class _AutomationDetailScreenState extends State<AutomationDetailScreen> {
  Automation? _automation;
  List<AutomationRun> _runs = const [];
  ApiError? _error;
  bool _busy = false;
  ({String tone, String message})? _notice;
  String? _tone;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final api = AppScope.read(context).api;
    try {
      final results = await Future.wait([
        api.automation(widget.id),
        api.automationRuns(widget.id),
      ]);
      if (!mounted) return;
      setState(() {
        _automation = results[0] as Automation;
        _runs = results[1] as List<AutomationRun>;
        _error = null;
      });
    } on ApiError catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _act(
    Future<String> Function() action, {
    String failure = 'Action impossible',
    String tone = 'ok',
  }) async {
    setState(() {
      _busy = true;
      _notice = null;
    });
    ({String tone, String message}) notice;
    try {
      final message = await action();
      notice = (tone: _tone ?? tone, message: message);
      _tone = null;
    } on ApiError catch (error) {
      // Never retried automatically; the reloaded history tells what happened.
      notice = (
        tone: 'error',
        message: error.outcomeUnknown
            ? '${error.message} Consultez l’historique ci-dessous.'
            : '$failure : ${error.message}',
      );
    }
    await _load();
    if (mounted) {
      setState(() {
        _busy = false;
        _notice = notice;
      });
    }
  }

  Future<void> _runNow() => _act(() async {
    final run = await AppScope.read(context).api.runAutomation(widget.id);
    final value = run.measuredPercent == null
        ? ''
        : ' : ${formatPercent(run.measuredPercent!)}';
    final alert = run.notified ? ' Notification envoyée.' : '';
    _tone = runTone(run.status);
    return 'Vérification terminée — ${runStatusLabel(run.status)}$value.$alert';
  }, failure: 'Vérification impossible');

  Future<void> _setEnabled(bool enabled) => _act(() async {
    await AppScope.read(
      context,
    ).api.updateAutomation(widget.id, enabled: enabled);
    return enabled
        ? 'Vérifications reprises à partir du prochain créneau.'
        : 'Vérifications suspendues.';
  });

  Future<void> _edit() async {
    final automation = _automation;
    if (automation == null) return;
    final saved = await Navigator.of(context).push<Automation>(
      MaterialPageRoute(
        builder: (_) => AutomationFormScreen(existing: automation),
      ),
    );
    if (saved != null) {
      await _load();
      if (mounted) {
        setState(
          () => _notice = (tone: 'ok', message: 'Modifications enregistrées.'),
        );
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette automatisation ?'),
        content: const Text(
          'Les vérifications programmées et leur historique seront supprimés. '
          'Les notifications déjà reçues restent.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await AppScope.read(context).api.deleteAutomation(widget.id);
      if (mounted) Navigator.of(context).pop();
    } on ApiError catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = (tone: 'error', message: error.message);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final automation = _automation;
    final theme = Theme.of(context);
    if (automation == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Automatisation')),
        body: _error == null
            ? const LoadingView()
            : ErrorView(error: _error!, onRetry: _load),
      );
    }
    final next = automation.nextRunAt;
    return Scaffold(
      appBar: AppBar(
        title: Text(automation.name),
        actions: [
          IconButton(
            tooltip: 'Modifier',
            onPressed: _busy ? null : _edit,
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: 'Supprimer',
            onPressed: _busy ? null : _delete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: NoticeBar(
                  tone: _notice!.tone,
                  message: _notice!.message,
                  onClose: () => setState(() => _notice = null),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: NoticeBar(tone: 'error', message: _error!.message),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _chips(automation),
                    ),
                    const SizedBox(height: 12),
                    _Line(
                      label: 'Seuil d’alerte',
                      value: thresholdLabel(automation.thresholdPercent),
                    ),
                    _Line(
                      label: 'Fréquence',
                      value: intervalLabel(automation.intervalMinutes),
                    ),
                    _Line(
                      label: 'Prochaine vérification',
                      value: next == null
                          ? 'aucune (suspendue)'
                          : formatShort(next),
                    ),
                    _Line(label: 'Fuseau horaire', value: automation.timezone),
                    const SizedBox(height: 12),
                    Text(
                      'Une alerte est envoyée quand le seuil est atteint, puis plus '
                      'aucune tant que le disque reste au-dessus. Le retour sous le '
                      'seuil est signalé une fois.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton.icon(
                          onPressed: _busy ? null : _runNow,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Vérifier maintenant'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _setEnabled(!automation.enabled),
                          icon: Icon(
                            automation.enabled
                                ? Icons.pause
                                : Icons.play_circle_outline,
                          ),
                          label: Text(
                            automation.enabled ? 'Suspendre' : 'Reprendre',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('Historique', style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: 8),
            if (_runs.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Aucune vérification pour l’instant.'),
              ),
            for (final run in _runs) _RunTile(run: run),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
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

class _RunTile extends StatelessWidget {
  const _RunTile({required this.run});

  final AutomationRun run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final details = [
      run.trigger == 'manual' ? 'manuelle' : 'programmée',
      formatShort(run.startedAt),
      if (run.missedSlots > 0)
        '${run.missedSlots} créneau(x) manqué(s) pendant un arrêt',
      if (run.notified) 'notification envoyée',
    ].join(' · ');
    return Card(
      child: ListTile(
        leading: Icon(
          switch (run.status) {
            'ok' => Icons.check_circle_outline,
            'alert' => Icons.warning_amber,
            _ => Icons.error_outline,
          },
          color: toneColors(theme.colorScheme, runTone(run.status)).foreground,
        ),
        title: Text(run.message),
        subtitle: Text(details),
        isThreeLine: true,
      ),
    );
  }
}

/// Creates or edits a disk check.
class AutomationFormScreen extends StatefulWidget {
  const AutomationFormScreen({super.key, this.existing});

  final Automation? existing;

  @override
  State<AutomationFormScreen> createState() => _AutomationFormScreenState();
}

class _AutomationFormScreenState extends State<AutomationFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _threshold;
  late int _interval;
  late bool _enabled;
  bool _busy = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(
      text: existing?.name ?? 'Vérification du disque',
    );
    _threshold = TextEditingController(
      text: existing == null
          ? '85'
          : NumberFormat('0.##', 'fr_FR').format(existing.thresholdPercent),
    );
    _interval = existing?.intervalMinutes ?? 60;
    _enabled = existing?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _threshold.dispose();
    super.dispose();
  }

  static double? _parseThreshold(String text) =>
      double.tryParse(text.trim().replaceAll(',', '.'));

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final state = AppScope.read(context);
    final threshold = _parseThreshold(_threshold.text)!;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final existing = widget.existing;
      final Automation saved;
      if (existing == null) {
        saved = await state.api.createAutomation(
          name: _name.text.trim(),
          thresholdPercent: threshold,
          intervalMinutes: _interval,
          timezone: await state.timezone(),
          enabled: _enabled,
        );
      } else {
        saved = await state.api.updateAutomation(
          existing.id,
          name: _name.text.trim(),
          thresholdPercent: threshold,
          intervalMinutes: _interval,
          // The schedule follows the phone's current time zone.
          timezone: await state.timezone(),
        );
      }
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiError catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = error.outcomeUnknown && widget.existing == null
            ? '${error.message} Vérifiez la liste avant de recommencer.'
            : error.message;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = 'Fuseau horaire du téléphone illisible.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.existing == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(creating ? 'Nouvelle vérification' : 'Modifier'),
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _name,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: 'Nom',
                  prefixIcon: Icon(Icons.label_outline),
                ),
                validator: (value) =>
                    (value ?? '').trim().isEmpty ? 'Indiquez un nom.' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _threshold,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Seuil d’alerte (% du disque utilisé)',
                  helperText:
                      'Exemple : 85. Pour un essai, un seuil bas (1) déclenche '
                      'une alerte sans remplir le disque.',
                  helperMaxLines: 3,
                  errorMaxLines: 3,
                  suffixText: '%',
                  prefixIcon: Icon(Icons.warning_amber),
                ),
                validator: (value) {
                  final number = _parseThreshold(value ?? '');
                  if (number == null || number <= 0 || number >= 100) {
                    return 'Un nombre entre 0 et 100, exclus.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: _interval,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Fréquence',
                  prefixIcon: Icon(Icons.schedule),
                ),
                items: [
                  for (final minutes in automationIntervals)
                    DropdownMenuItem(
                      value: minutes,
                      child: Text(
                        intervalLabel(minutes),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _interval = value!),
              ),
              if (creating)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Activer tout de suite'),
                  value: _enabled,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _enabled = value),
                ),
              const SizedBox(height: 8),
              Text(
                'Les heures suivent le fuseau horaire du téléphone. La mesure est '
                'faite sur le serveur, sans l’IA : elle fonctionne même si le '
                'fournisseur IA est indisponible.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              if (_busy) const LinearProgressIndicator(),
              if (_problem != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: NoticeBar(tone: 'error', message: _problem!),
                ),
              FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: Text(creating ? 'Programmer' : 'Enregistrer'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

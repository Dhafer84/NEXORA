import 'package:flutter/material.dart';

import '../../activity/activity_controller.dart';
import '../../activity/activity_models.dart';
import '../../activity/activity_report.dart';
import '../../files/file_access.dart';
import '../../health/health_service.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/states.dart';
import 'activity_chart.dart';
import 'activity_views.dart';

/// Export of the local copy as CSV or JSON, e.g. to give it to ChatGPT. The
/// file holds exactly what is chosen here and shown in the preview: daily
/// aggregates by default, entries and devices only as a distinct choice.
/// Nothing goes through the NEXORA server.
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key, required this.controller, this.now});

  final ActivityController controller;

  /// Test hook: generation time written in the file.
  final DateTime Function()? now;

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  late DayKey _to = widget.controller.yesterday;
  late DayKey _from = shiftDay(_to, -6);
  late final Set<HealthCategory> _categories = {
    for (final c in HealthCategory.values)
      if (widget.controller[c].data != null) c,
  };
  ExportFormat _format = ExportFormat.csv;
  bool _detailed = false;
  bool _busy = false;
  String? _message;

  /// Generation time, fixed while the selection does not change so that the
  /// file saved is the one previewed.
  DateTime? _generatedAt;

  ActivityController get _c => widget.controller;

  /// First day of the local copy.
  DayKey get _first => shiftDay(_c.today, 1 - windowDays);

  void _select(VoidCallback change) => setState(() {
    change();
    _generatedAt = null;
    _message = null;
  });

  ExportFile _file() => buildExport(
    data: {for (final cat in HealthCategory.values) cat: _c[cat].data},
    categories: _categories,
    from: _from,
    to: _to,
    today: _c.today,
    zone: _c.status?.zone ?? 'inconnu',
    format: _format,
    detailed: _detailed,
    generatedAt: _generatedAt ??= (widget.now ?? DateTime.now)(),
  );

  Future<void> _pickDates() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: parseDay(_first),
      lastDate: parseDay(_c.today),
      initialDateRange: DateTimeRange(
        start: parseDay(_from),
        end: parseDay(_to),
      ),
      helpText: 'Période exportée',
    );
    if (range == null) return;
    _select(() {
      _from = keyOf(range.start);
      _to = keyOf(range.end);
    });
  }

  void _preset(int days) => _select(() {
    _to = _c.yesterday;
    _from = shiftDay(_to, 1 - days);
  });

  Future<void> _save(FileAccess files, ExportFile file) async {
    setState(() => _busy = true);
    try {
      final saved = await files.saveExport(file.name, file.mime, file.content);
      if (mounted) {
        setState(
          () => _message = saved == null
              ? 'Enregistrement annulé.'
              : 'Fichier enregistré : $saved.',
        );
      }
    } on FileOperationError catch (error) {
      if (mounted) setState(() => _message = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(FileAccess files, ExportFile file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Partager cet export ?'),
        content: const Text(
          'L’application que vous choisirez (ChatGPT, messagerie…) recevra ce fichier '
          'tel qu’affiché dans l’aperçu. Ce qu’elle en fait relève de ses propres '
          'règles. NEXORA n’en garde qu’une copie temporaire, effacée au prochain '
          'partage.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Partager'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await files.shareExport(file.name, file.mime, file.content);
    } on FileOperationError catch (error) {
      if (mounted) setState(() => _message = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final files = AppScope.read(context).files;
    final file = _categories.isEmpty ? null : _file();
    final days = daysBetween(_from, _to).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Exporter pour ChatGPT')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Le fichier est préparé sur le téléphone à partir des dernières lectures. Il '
              'contient la période, le fuseau, les unités, les sources et les jours sans '
              'donnée, rien d’autre que la sélection ci-dessous.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Space.l),
            Text('Période', style: theme.textTheme.titleSmall),
            Wrap(
              spacing: Space.s,
              children: [
                for (final n in const [7, 30])
                  ChoiceChip(
                    label: Text('$n derniers jours'),
                    selected: _to == _c.yesterday && days == n,
                    onSelected: (_) => _preset(n),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.date_range_rounded, size: 18),
                  label: const Text('Autres dates…'),
                  onPressed: _pickDates,
                ),
              ],
            ),
            Text(
              '${periodLabel([_from, _to])} ($days jour${days > 1 ? 's' : ''})',
              key: const Key('export-period'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: Space.m),
            Text('Catégories', style: theme.textTheme.titleSmall),
            Wrap(
              spacing: Space.s,
              children: [
                for (final cat in HealthCategory.values)
                  FilterChip(
                    label: Text(cat.label),
                    avatar: Icon(categoryIcon(cat), size: 18),
                    selected: _categories.contains(cat),
                    onSelected: _c[cat].data == null
                        ? null
                        : (on) => _select(
                            () => on
                                ? _categories.add(cat)
                                : _categories.remove(cat),
                          ),
                  ),
              ],
            ),
            const SizedBox(height: Space.m),
            Text('Format', style: theme.textTheme.titleSmall),
            const SizedBox(height: Space.xs),
            SegmentedButton<ExportFormat>(
              segments: const [
                ButtonSegment(value: ExportFormat.csv, label: Text('CSV')),
                ButtonSegment(value: ExportFormat.json, label: Text('JSON')),
              ],
              selected: {_format},
              onSelectionChanged: (s) => _select(() => _format = s.single),
            ),
            const SizedBox(height: Space.m),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Agrégats par jour')),
                ButtonSegment(value: true, label: Text('Détail des entrées')),
              ],
              selected: {_detailed},
              onSelectionChanged: (s) => _select(() => _detailed = s.single),
            ),
            if (_detailed)
              const Padding(
                padding: EdgeInsets.only(top: Space.s),
                child: NoticeBar(
                  tone: 'warning',
                  message:
                      'Le détail ajoute chaque séance et nuit avec ses horaires, chaque '
                      'source et le modèle d’appareil quand il est connu.',
                ),
              ),
            Section(
              title: file == null ? 'Aperçu' : 'Aperçu : ${file.name}',
              children: [
                if (file == null)
                  const Text('Choisissez au moins une catégorie.')
                else ...[
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        file.content,
                        key: const Key('export-preview'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.s),
                  Text(
                    '${file.content.split('\n').length} lignes · ${file.content.length} caractères · '
                    'dernière lecture ${longDay(keyOf(_c.lastRead ?? DateTime.now()))}',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ],
            ),
            const SizedBox(height: Space.l),
            if (files == null)
              const Text(
                'Enregistrement et partage indisponibles sur cet appareil.',
              )
            else
              Wrap(
                spacing: Space.s,
                runSpacing: Space.s,
                children: [
                  FilledButton.icon(
                    onPressed: file == null || _busy
                        ? null
                        : () => _save(files, file),
                    icon: const Icon(Icons.save_alt_rounded),
                    label: const Text('Enregistrer'),
                  ),
                  OutlinedButton.icon(
                    onPressed: file == null || _busy
                        ? null
                        : () => _share(files, file),
                    icon: const Icon(Icons.share_rounded),
                    label: const Text('Partager'),
                  ),
                ],
              ),
            if (_message case final text?) ...[
              const SizedBox(height: Space.m),
              Text(text, key: const Key('export-message')),
            ],
          ],
        ),
      ),
    );
  }
}

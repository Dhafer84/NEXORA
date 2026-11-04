import 'package:flutter/material.dart';

import '../../activity/activity_controller.dart';
import '../../activity/activity_report.dart';
import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../health/health_service.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/states.dart';
import 'activity_views.dart';

/// « Analyser avec l’IA »: the summary is computed here, shown word for word
/// with its recipient, and sent only after the user confirms that exact
/// pair. Any change of period, categories, data or recipient cancels the
/// confirmation. Nothing is sent automatically, nothing is retried, and the
/// answer lives in this screen only.
class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key, required this.controller});

  final ActivityController controller;

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  int _days = 7;
  late final Set<HealthCategory> _categories = {
    for (final c in HealthCategory.values)
      if (widget.controller[c].data != null) c,
  };

  AnalysisRecipient? _recipient;
  ApiError? _recipientError;
  bool _loadingRecipient = true;

  /// Summary and recipient the user agreed to, as one string.
  String? _confirmed;
  bool _sending = false;
  AnalysisResult? _result;
  String? _failure;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onData);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadingRecipient && _recipient == null && _recipientError == null) {
      _loadRecipient();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onData);
    super.dispose();
  }

  void _onData() => setState(() {});

  /// Asking who would receive the analysis sends no health data.
  Future<void> _loadRecipient() async {
    final state = AppScope.read(context);
    setState(() {
      _loadingRecipient = true;
      _recipientError = null;
    });
    if (!state.configured) {
      setState(() {
        _loadingRecipient = false;
        _recipientError = const ApiError(
          ApiErrorKind.unavailable,
          'Serveur NEXORA non configuré.',
        );
      });
      return;
    }
    try {
      final recipient = await state.api.analysisRecipient();
      if (mounted) setState(() => _recipient = recipient);
    } on ApiError catch (error) {
      if (mounted) setState(() => _recipientError = error);
    } finally {
      if (mounted) setState(() => _loadingRecipient = false);
    }
  }

  String get _summary {
    final c = widget.controller;
    return analysisSummary(
      data: {for (final cat in HealthCategory.values) cat: c[cat].data},
      categories: _categories,
      end: c.yesterday,
      today: c.today,
      days: _days,
      zone: c.status?.zone ?? 'inconnu',
    );
  }

  String _bound(String summary, AnalysisRecipient recipient) =>
      '${recipient.key}\n$summary';

  Future<void> _send(String summary, AnalysisRecipient recipient) async {
    // Last check: the text and recipient on screen are those confirmed.
    if (_confirmed != _bound(summary, recipient) ||
        recipient.provider == null) {
      return;
    }
    setState(() {
      _sending = true;
      _failure = null;
      _result = null;
    });
    try {
      final result = await AppScope.read(
        context,
      ).api.analyseActivity(summary, recipient.provider!);
      if (mounted) setState(() => _result = result);
    } on ApiError catch (error) {
      if (!mounted) return;
      setState(() {
        _confirmed = null;
        _failure = switch (error) {
          ApiError(code: 'recipient_changed') =>
            'Le fournisseur IA du serveur a changé. Vérifiez le nouveau destinataire et '
                'confirmez de nouveau : rien n’a été envoyé à l’IA.',
          ApiError(kind: ApiErrorKind.notFound) =>
            'Le serveur NEXORA ne propose pas encore l’analyse : il doit être mis à jour. '
                'Rien n’a été analysé ; les courbes restent disponibles.',
          ApiError(kind: ApiErrorKind.unavailable) =>
            '${error.message}. L’analyse n’a pas abouti ; les courbes restent disponibles. '
                'Vous pouvez réessayer plus tard (nouvelle confirmation).',
          ApiError(outcomeUnknown: true) =>
            'Pas de réponse à temps : le résumé a peut-être été transmis. Aucun nouvel envoi '
                'automatique ; vous pouvez réessayer (nouvelle confirmation).',
          _ => error.message,
        };
      });
      if (error.code == 'recipient_changed') await _loadRecipient();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.controller;
    final summary = _summary;
    final recipient = _recipient;
    final bound = recipient == null ? null : _bound(summary, recipient);
    final confirmed = bound != null && _confirmed == bound;
    final canConfirm =
        recipient != null &&
        recipient.configured &&
        recipient.provider != null &&
        _categories.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Analyser avec l’IA')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'NEXORA calcule ce résumé sur le téléphone. Rien n’est envoyé tant que vous '
              'n’avez pas confirmé ; seul le texte ci-dessous part, sans vos relevés '
              'individuels ni l’identité de vos appareils.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Space.l),
            Text('Période', style: theme.textTheme.titleSmall),
            const SizedBox(height: Space.xs),
            PeriodPicker(
              days: _days,
              onChanged: _sending ? (_) {} : (d) => setState(() => _days = d),
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
                    onSelected: _sending || c[cat].data == null
                        ? null
                        : (on) => setState(
                            () => on
                                ? _categories.add(cat)
                                : _categories.remove(cat),
                          ),
                  ),
              ],
            ),
            Section(
              title: 'Aperçu exact du texte envoyé',
              children: [
                SelectableText(
                  _categories.isEmpty
                      ? 'Choisissez au moins une catégorie.'
                      : summary,
                  key: const Key('analysis-summary'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: Space.s),
                Text(
                  '${summary.length} caractères',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            Section(
              title: 'Destinataire',
              children: [
                if (_loadingRecipient)
                  const LinearProgressIndicator()
                else if (_recipientError case final error?) ...[
                  Text(
                    error.kind == ApiErrorKind.notFound
                        ? 'Le serveur NEXORA ne propose pas encore l’analyse : il doit être mis à jour.'
                        : error.message,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _loadRecipient,
                      child: const Text('Réessayer'),
                    ),
                  ),
                ] else if (recipient != null) ...[
                  Text(
                    recipient.label,
                    key: const Key('analysis-recipient'),
                    style: theme.textTheme.titleSmall,
                  ),
                  if (recipient.destination case final host?)
                    Text(
                      'Envoyé par votre serveur NEXORA à $host.',
                      style: theme.textTheme.bodySmall,
                    ),
                  Text(
                    'Requête isolée : aucun historique de discussion, aucun outil, rien n’est '
                    'enregistré dans vos conversations.',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (!recipient.configured)
                    const Padding(
                      padding: EdgeInsets.only(top: Space.s),
                      child: NoticeBar(
                        tone: 'warning',
                        message:
                            'Aucun fournisseur IA n’est configuré sur le serveur.',
                      ),
                    ),
                ],
              ],
            ),
            const SizedBox(height: Space.l),
            CheckboxListTile(
              key: const Key('analysis-consent'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: confirmed,
              onChanged: !canConfirm || _sending
                  ? null
                  : (on) =>
                        setState(() => _confirmed = on == true ? bound : null),
              title: Text(
                recipient == null
                    ? 'J’accepte d’envoyer exactement ce résumé'
                    : 'J’accepte d’envoyer exactement ce résumé à ${recipient.label}',
              ),
              subtitle: const Text(
                'Toute modification de la sélection annule cet accord.',
              ),
            ),
            FilledButton.icon(
              onPressed: confirmed && !_sending
                  ? () => _send(summary, recipient!)
                  : null,
              icon: _sending
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded),
              label: Text(_sending ? 'Analyse en cours…' : 'Envoyer ce résumé'),
            ),
            if (_failure case final text?) ...[
              const SizedBox(height: Space.m),
              NoticeBar(tone: 'warning', message: text),
            ],
            if (_result case final result?)
              Section(
                title: result.simulated
                    ? 'Réponse (fournisseur simulé)'
                    : 'Réponse de l’IA',
                children: [
                  SelectableText(
                    result.text,
                    key: const Key('analysis-result'),
                  ),
                  const SizedBox(height: Space.s),
                  Text(
                    'Lecture descriptive, pas un avis médical. Cette réponse n’est pas '
                    'enregistrée : elle disparaît en quittant cet écran.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

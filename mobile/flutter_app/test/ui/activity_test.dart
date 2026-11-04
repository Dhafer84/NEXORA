import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora/src/activity/activity_controller.dart';
import 'package:nexora/src/activity/activity_store.dart';
import 'package:nexora/src/health/health_service.dart';
import 'package:nexora/src/state/app_state.dart';
import 'package:nexora/src/ui/activity/analysis_screen.dart';
import 'package:nexora/src/ui/activity/export_screen.dart';

import '../support/activity_samples.dart';
import '../support/app_harness.dart';
import '../support/fake_backend.dart';
import '../support/fake_files.dart';
import '../support/fake_health.dart';

const _recipientPath = '/api/v1/analysis/recipient';
const _analysisPath = '/api/v1/analysis/activity';

Map<String, Object?> _recipient({String model = 'llama-test'}) => {
  'provider': {'name': 'nvidia', 'model': model, 'real': true},
  'configured': true,
  'destination': 'integrate.api.nvidia.com',
  'label': 'NVIDIA — modèle $model',
  'stored': false,
};

/// Activité data read from synthetic Health Connect answers, then [screen].
Future<ActivityController> _pump(
  WidgetTester tester,
  FakeBackend backend,
  Widget Function(ActivityController) screen, {
  FakeFiles? files,
}) async {
  final health = FakeHealth(
    granted: {HealthCategory.steps, HealthCategory.heartRate},
    ranges: {
      HealthCategory.steps: stepsRaw(gaps: {'2026-10-30'}),
      HealthCategory.heartRate: heartRaw([
        heartDay('2026-11-02', 100, 7000, 50, 120),
      ]),
    },
  );
  final state = await startState(backend, health: health, files: files);
  await state.load();
  final controller = ActivityController(
    service: health,
    store: MemoryActivityStore(),
    now: () => sampleNow,
  );
  await controller.load();
  await controller.refreshAll();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    AppScope(
      state: state,
      child: MaterialApp(home: screen(controller)),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

List<String> _paths(FakeBackend backend) => [
  for (final r in backend.requests) r.url.path,
];

void main() {
  testApp('analyse IA : rien ne part avant la confirmation exacte', (
    tester,
  ) async {
    final backend = FakeBackend();
    final sent = <Map<String, dynamic>>[];
    backend.override = (request) {
      if (request.url.path == _recipientPath) return jsonResponse(_recipient());
      if (request.url.path == _analysisPath) {
        sent.add(jsonDecode(request.body) as Map<String, dynamic>);
        return jsonResponse({
          'text': 'Sur la période, la moyenne est stable.',
          'provider': {'name': 'nvidia', 'model': 'llama-test', 'real': true},
          'destination': 'integrate.api.nvidia.com',
          'simulated': false,
        });
      }
      return null;
    };
    await _pump(tester, backend, (c) => AnalysisScreen(controller: c));

    expect(find.text('NVIDIA — modèle llama-test'), findsOneWidget);
    final preview = tester.widget<SelectableText>(
      find.byKey(const Key('analysis-summary')),
    );
    expect(preview.data, contains('Pas (source : Health Sync)'));
    expect(preview.data, isNot(contains('WATCH')));
    expect(_paths(backend), isNot(contains(_analysisPath)));

    // The send button waits for the consent.
    final send = find.widgetWithText(FilledButton, 'Envoyer ce résumé');
    await tester.ensureVisible(send);
    expect(tester.widget<FilledButton>(send).onPressed, isNull);

    // Consent, then a change of period: the consent is cancelled.
    await _tap(tester, find.byKey(const Key('analysis-consent')));
    expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
    await _tap(tester, find.text('30 jours'));
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const Key('analysis-consent')))
          .value,
      isFalse,
    );
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    expect(_paths(backend), isNot(contains(_analysisPath)));

    // Confirmed: exactly the text shown, to the recipient shown.
    await _tap(tester, find.byKey(const Key('analysis-consent')));
    final shown = tester
        .widget<SelectableText>(find.byKey(const Key('analysis-summary')))
        .data;
    await _tap(tester, send);
    expect(sent, hasLength(1));
    expect(sent.single['summary'], shown);
    expect(sent.single['recipient'], {'name': 'nvidia', 'model': 'llama-test'});
    expect(sent.single.keys, unorderedEquals(['summary', 'recipient']));
    expect(find.text('Sur la période, la moyenne est stable.'), findsOneWidget);
    // No new conversation, nothing else sent.
    expect(_paths(backend).where((p) => p.contains('conversations')), isEmpty);
  });

  testApp('analyse IA : destinataire changé, nouvelle confirmation', (
    tester,
  ) async {
    final backend = FakeBackend();
    var model = 'llama-test';
    var posts = 0;
    backend.override = (request) {
      if (request.url.path == _recipientPath) {
        return jsonResponse(_recipient(model: model));
      }
      if (request.url.path == _analysisPath) {
        posts++;
        model = 'autre-modele';
        return errorResponse(409, 'recipient_changed', 'Fournisseur changé');
      }
      return null;
    };
    await _pump(tester, backend, (c) => AnalysisScreen(controller: c));
    await _tap(tester, find.byKey(const Key('analysis-consent')));
    await _tap(tester, find.widgetWithText(FilledButton, 'Envoyer ce résumé'));
    expect(posts, 1, reason: 'aucun renvoi automatique');
    expect(find.textContaining('confirmez de nouveau'), findsOneWidget);
    expect(find.text('NVIDIA — modèle autre-modele'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const Key('analysis-consent')))
          .value,
      isFalse,
    );
  });

  testApp('analyse IA : serveur pas encore mis à jour (404)', (tester) async {
    final backend = FakeBackend();
    backend.override = (request) =>
        request.url.path.startsWith('/api/v1/analysis')
        ? errorResponse(404, 'not_found', 'Not Found')
        : null;
    await _pump(tester, backend, (c) => AnalysisScreen(controller: c));
    expect(find.textContaining('doit être mis à jour'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const Key('analysis-consent')))
          .onChanged,
      isNull,
    );
    expect(_paths(backend), isNot(contains(_analysisPath)));
  });

  testApp('export : aperçu exact, enregistré et partagé tel quel', (
    tester,
  ) async {
    final files = FakeFiles([]);
    final backend = FakeBackend();
    await _pump(
      tester,
      backend,
      (c) => ExportScreen(controller: c, now: () => sampleNow),
      files: files,
    );
    // Heart rate unticked: only steps remain.
    await _tap(tester, find.widgetWithText(FilterChip, 'Fréquence cardiaque'));
    await _tap(tester, find.text('JSON'));
    final preview = tester
        .widget<SelectableText>(find.byKey(const Key('export-preview')))
        .data!;
    final json = jsonDecode(preview) as Map<String, dynamic>;
    expect((json['categories'] as List).map((c) => c['categorie']), ['steps']);
    expect(json['periode'], {
      'du': '2026-10-27',
      'au': '2026-11-02',
      'jours': 7,
    });

    await _tap(tester, find.text('Enregistrer'));
    expect(files.exports.single.content, preview);
    expect(
      files.exports.single.name,
      'nexora-activite-2026-10-27-2026-11-02.json',
    );

    await _tap(tester, find.text('Partager'));
    expect(find.text('Partager cet export ?'), findsOneWidget);
    await _tap(tester, find.widgetWithText(FilledButton, 'Partager').last);
    expect(files.exports.last.action, 'share');
    expect(files.exports.last.content, preview);
    // Never through the NEXORA server.
    expect(_paths(backend).where((p) => p.contains('analysis')), isEmpty);
  });

  testApp('onglet Activité : autorisation catégorie par catégorie', (
    tester,
  ) async {
    final health = FakeHealth(refuse: {HealthCategory.sleep});
    await pumpApp(tester, FakeBackend(), health: health);
    await tester.tap(find.text('Activité'));
    await tester.pumpAndSettle();
    expect(find.text('Non autorisée'), findsNWidgets(4));
    expect(health.calls.where((c) => c.startsWith('range')), isEmpty);

    await _tap(tester, find.text('Autoriser : pas'));
    expect(health.calls, contains('request:steps'));
    expect(
      health.calls.where((c) => c.startsWith('range')).single,
      startsWith('range:steps:'),
    );
    expect(find.text('Non autorisée'), findsNWidgets(3));

    await _tap(tester, find.text('Autoriser : sommeil'));
    expect(health.calls, contains('request:sleep'));
    expect(health.calls.where((c) => c.startsWith('range:sleep')), isEmpty);
    expect(find.text('Non autorisée'), findsNWidgets(3));
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:nexora/src/health/health_service.dart';
import 'package:nexora/src/health/health_summary.dart';
import 'package:nexora/src/ui/screens/health_diagnostic_screen.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';
import '../support/fake_health.dart';

/// 3 November 2026, 10:00: the last finished day is 2 November.
final _now = DateTime(2026, 11, 3, 10);

DateTime _at(int day, int hour, [int minute = 0]) =>
    DateTime(2026, 11, day, hour, minute);

HealthEntry _steps(
  String origin,
  int day,
  int from,
  int to,
  int count, {
  int? deviceType,
  String? model,
}) => HealthEntry(
  origin: origin,
  start: _at(day, from),
  end: _at(day, to),
  value: count,
  deviceType: deviceType,
  manufacturer: model == null ? null : 'HUAWEI',
  model: model,
);

/// The watch through Health Sync, and the phone's own counter over the same
/// morning hour.
List<HealthEntry> _watchAndPhone() => [
  _steps(
    healthSyncPackage,
    2,
    8,
    9,
    1350,
    deviceType: 1,
    model: 'WATCH GT 5 Pro',
  ),
  _steps(
    healthSyncPackage,
    2,
    18,
    19,
    2650,
    deviceType: 1,
    model: 'WATCH GT 5 Pro',
  ),
  _steps('com.google.android.apps.fitness', 2, 8, 9, 1200, deviceType: 2),
];

Future<FakeHealth> _pump(WidgetTester tester, FakeHealth health) async {
  await initializeDateFormatting('fr_FR');
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: HealthDiagnosticScreen(service: health, now: () => _now),
    ),
  );
  await tester.pumpAndSettle();
  return health;
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _authorize(String label) =>
    find.text('Autoriser la lecture : ${label.toLowerCase()}');

void main() {
  group('sources', () {
    test('Health Sync, téléphone et autres applications sont distingués', () {
      expect(classify(_watchAndPhone()[0]), SourceKind.healthSync);
      expect(classify(_watchAndPhone()[2]), SourceKind.phone);
      expect(
        classify(_steps('com.huawei.health', 2, 8, 9, 10)),
        SourceKind.otherApp,
      );
      expect(
        classify(_steps('android', 2, 8, 9, 10)),
        SourceKind.phone,
        reason: 'compteur du téléphone écrit par Android',
      );
      // Health Sync stays Health Sync even when it reports the phone.
      expect(
        classify(_steps(healthSyncPackage, 2, 8, 9, 10, deviceType: 2)),
        SourceKind.healthSync,
      );
    });

    test('total Health Sync et chevauchement avec le téléphone', () {
      final summary = SourceSummary.of(_watchAndPhone());
      expect(summary.groups, hasLength(2));
      expect(summary.healthSyncTotal, 4000);
      expect(summary.sum, 5200);
      expect(summary.overlaps, hasLength(1));
      expect(summary.overlaps.single.minutes, 60);
    });

    test('pas de chevauchement entre périodes différentes', () {
      final summary = SourceSummary.of([
        _steps(healthSyncPackage, 2, 8, 9, 100),
        _steps('android', 2, 10, 11, 200, deviceType: 2),
      ]);
      expect(summary.overlaps, isEmpty);
      expect(SourceSummary.of(const []).healthSyncTotal, isNull);
    });

    test('dernière journée terminée : la veille', () {
      expect(lastFinishedDay(_now), DateTime(2026, 11, 2));
      expect(
        lastFinishedDay(DateTime(2026, 3, 1, 0, 5)),
        DateTime(2026, 2, 28),
      );
    });
  });

  group('écran', () {
    testWidgets('pas : autorisation, total, date, fuseau et sources', (
      tester,
    ) async {
      final health = await _pump(
        tester,
        FakeHealth(entries: {HealthCategory.steps: _watchAndPhone()})
          ..stepsTotal = 4000,
      );
      expect(find.textContaining('lundi 2 novembre 2026'), findsWidgets);
      expect(find.textContaining('Africa/Tunis (UTC+01:00)'), findsOneWidget);
      expect(health.calls, isEmpty, reason: 'rien n’est lu sans geste');

      await _tap(tester, _authorize('Pas'));
      expect(health.calls, ['request:steps', 'read:steps']);
      expect(health.days.single, DateTime(2026, 11, 2));
      expect(
        find.text('${NumberFormat.decimalPattern('fr_FR').format(4000)} pas'),
        findsWidgets,
      );
      expect(
        find.textContaining('comparer avec Huawei Health'),
        findsOneWidget,
      );
      expect(
        find.text('Health Sync — montre · HUAWEI WATCH GT 5 Pro'),
        findsOneWidget,
      );
      expect(find.text('Google Fit — téléphone'), findsOneWidget);
      expect(find.text('Données lues'), findsOneWidget);
      expect(find.textContaining('ne pas additionner'), findsOneWidget);
      expect(find.textContaining('Somme brute'), findsOneWidget);
    });

    testWidgets('journée sans entrée : « Aucune donnée disponible »', (
      tester,
    ) async {
      await _pump(tester, FakeHealth(granted: {HealthCategory.steps}));
      await _tap(tester, find.text('Lire la journée'));
      expect(find.text('Aucune donnée disponible'), findsOneWidget);
      expect(find.text('Aucune donnée'), findsOneWidget);
    });

    testWidgets('jamais la journée en cours ; jour précédent possible', (
      tester,
    ) async {
      final health = await _pump(
        tester,
        FakeHealth(
          granted: {HealthCategory.steps},
          entries: {HealthCategory.steps: _watchAndPhone()},
        ),
      );
      final next = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_right_rounded),
      );
      expect(next.onPressed, isNull);

      await tester.tap(find.byTooltip('Jour précédent'));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Lire la journée'));
      expect(health.days.single, DateTime(2026, 11, 1));
      expect(find.text('Aucune donnée disponible'), findsOneWidget);
    });

    testWidgets('autres catégories après une lecture des pas réussie', (
      tester,
    ) async {
      await _pump(tester, FakeHealth());
      expect(
        find.text('À tester après une lecture des pas réussie.'),
        findsNWidgets(3),
      );
      expect(_authorize('Sommeil'), findsNothing);

      await _tap(tester, _authorize('Pas'));
      expect(
        find.text('À tester après une lecture des pas réussie.'),
        findsNothing,
      );
      expect(_authorize('Sommeil'), findsOneWidget);
    });

    testWidgets('pas refusés : les autres catégories restent verrouillées', (
      tester,
    ) async {
      final health = await _pump(
        tester,
        FakeHealth(refuse: {HealthCategory.steps}),
      );
      await _tap(tester, _authorize('Pas'));
      expect(find.text('Permission refusée'), findsOneWidget);
      expect(health.calls, ['request:steps'], reason: 'aucune lecture');
      expect(
        find.text('À tester après une lecture des pas réussie.'),
        findsNWidgets(3),
      );
      await _tap(tester, find.text('Ouvrir Health Connect'));
      expect(health.calls.last, 'settings');
    });

    testWidgets('une permission par catégorie ; lues, refusées, vides', (
      tester,
    ) async {
      final health = await _pump(
        tester,
        FakeHealth(
          granted: {HealthCategory.steps},
          refuse: {HealthCategory.heartRate},
          entries: {
            HealthCategory.steps: _watchAndPhone(),
            HealthCategory.sleep: [
              HealthEntry(
                origin: healthSyncPackage,
                start: _at(1, 23),
                end: _at(2, 7),
                value: 480,
                deviceType: 1,
                stages: const {4: 300, 5: 90, 6: 90},
              ),
            ],
          },
        ),
      );
      await _tap(tester, find.text('Lire la journée'));

      await _tap(tester, _authorize('Sommeil'));
      expect(find.textContaining('8 h 00'), findsWidgets);
      expect(find.textContaining('léger 5 h 00'), findsOneWidget);

      await _tap(tester, _authorize('Fréquence cardiaque'));
      expect(find.text('Permission refusée'), findsOneWidget);

      await _tap(tester, _authorize('Entraînements'));
      expect(find.text('Aucune donnée disponible'), findsOneWidget);

      expect(health.calls.where((c) => c.startsWith('request:')), [
        'request:sleep',
        'request:heart_rate',
        'request:exercise',
      ]);
      expect(health.granted, isNot(contains(HealthCategory.heartRate)));
      expect(find.text('Données lues'), findsNWidgets(2));
    });

    testWidgets('historique accessible', (tester) async {
      await _pump(
        tester,
        FakeHealth(
          granted: {HealthCategory.steps},
          entries: {
            HealthCategory.steps: [_steps(healthSyncPackage, 2, 8, 9, 10)],
          },
        ),
      );
      await _tap(tester, find.text('Historique accessible'));
      expect(
        find.textContaining('Plus ancienne entrée lisible : 2 novembre 2026'),
        findsOneWidget,
      );
      expect(find.textContaining('30 jours'), findsOneWidget);
      expect(find.textContaining('(il y a 1 jour)'), findsOneWidget);
    });

    testWidgets('Health Connect absent', (tester) async {
      await _pump(tester, FakeHealth(sdk: HealthSdk.unavailable));
      expect(find.text('Health Connect indisponible'), findsOneWidget);
      expect(_authorize('Pas'), findsNothing);
    });

    testWidgets('mise à jour de Health Connect requise', (tester) async {
      final health = await _pump(
        tester,
        FakeHealth(sdk: HealthSdk.updateRequired),
      );
      await tester.tap(find.text('Mettre à jour'));
      expect(health.calls, ['settings']);
    });
  });

  testApp('depuis Réglages, sans aucun appel au serveur', (tester) async {
    final backend = FakeBackend();
    final health = FakeHealth(
      entries: {HealthCategory.steps: _watchAndPhone()},
    );
    await pumpApp(tester, backend, health: health);
    await tester.tap(find.text('Réglages').last);
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Diagnostic santé (prototype)'));
    expect(find.text('Diagnostic santé'), findsOneWidget);

    final before = backend.requests.length;
    await _tap(tester, _authorize('Pas'));
    await tester.tap(find.byTooltip('Jour précédent'));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Lire la journée'));
    expect(health.calls, contains('read:steps'));
    // Only the background check of the server may run meanwhile.
    final sent = backend.requests.skip(before).map((r) => r.url.path);
    expect(sent.where((p) => !p.endsWith('/health')), isEmpty);
    for (final r in backend.requests) {
      expect(r.body, isNot(contains('pas')));
      expect(r.body, isNot(contains(healthSyncPackage)));
    }
  });
}

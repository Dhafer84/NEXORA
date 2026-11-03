import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';

Future<void> openTasks(WidgetTester tester) async {
  await tester.tap(find.text('Tâches'));
  await tester.pumpAndSettle();
}

void main() {
  testApp('programmer la vérification : seuil, fréquence, fuseau', (
    tester,
  ) async {
    final backend = FakeBackend();
    await pumpApp(tester, backend);
    await openTasks(tester);
    expect(find.text('Aucune automatisation'), findsOneWidget);
    await tester.tap(find.text('Programmer la vérification'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(
        TextFormField,
        'Seuil d’alerte (% du disque utilisé)',
      ),
      '100',
    );
    await tester.tap(find.text('Programmer'));
    await tester.pumpAndSettle();
    expect(find.text('Un nombre entre 0 et 100, exclus.'), findsOneWidget);
    expect(backend.automations, isEmpty);

    await tester.enterText(
      find.widgetWithText(
        TextFormField,
        'Seuil d’alerte (% du disque utilisé)',
      ),
      '1,5',
    );
    await tester.tap(find.text('Programmer'));
    await tester.pumpAndSettle();
    final created = backend.automations.values.single;
    expect(created['threshold_percent'], 1.5);
    expect(created['interval_minutes'], 60);
    expect(created['timezone'], 'Europe/Paris');
    // Opens the detail: next run shown in the phone's time zone.
    expect(find.text('Vérification du disque'), findsWidgets);
    expect(find.textContaining('toutes les heures'), findsOneWidget);
    expect(find.textContaining('Europe/Paris'), findsOneWidget);
    expect(find.text('Aucune vérification pour l’instant.'), findsOneWidget);
  });

  testApp('vérifier maintenant, résultat et historique, alerte unique', (
    tester,
  ) async {
    final backend = FakeBackend()..diskPercent = 90;
    backend.addAutomation(threshold: 85);
    await pumpApp(tester, backend);
    await openTasks(tester);
    expect(find.textContaining('Seuil 85\u00a0%'), findsOneWidget);
    await tester.tap(find.text('Vérification du disque'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Vérifier maintenant'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Vérification terminée — Seuil atteint : 90,0\u00a0%. Notification envoyée.',
      ),
      findsOneWidget,
    );
    expect(find.text('Au-dessus du seuil'), findsOneWidget);
    expect(find.textContaining('notification envoyée'), findsOneWidget);

    await tester.tap(find.text('Vérifier maintenant'));
    await tester.pumpAndSettle();
    expect(
      find.text('Vérification terminée — Seuil atteint : 90,0\u00a0%.'),
      findsOneWidget,
    );
    expect(backend.notifications, hasLength(1));
    expect(find.byType(ListTile), findsNWidgets(2));
  });

  testApp('échec de mesure enregistré et affiché', (tester) async {
    final backend = FakeBackend()..diskPercent = null;
    backend.addAutomation();
    await pumpApp(tester, backend);
    await openTasks(tester);
    await tester.tap(find.text('Vérification du disque'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vérifier maintenant'));
    await tester.pumpAndSettle();
    expect(
      find.text('Vérification terminée — Échec. Notification envoyée.'),
      findsOneWidget,
    );
    expect(find.text('Mesure impossible'), findsOneWidget);
    expect(find.text('Mesure du disque impossible'), findsOneWidget);
  });

  testApp('vérification sans réponse : pas de renvoi, historique relu', (
    tester,
  ) async {
    final backend = FakeBackend();
    backend.addAutomation();
    await pumpApp(tester, backend);
    await openTasks(tester);
    await tester.tap(find.text('Vérification du disque'));
    await tester.pumpAndSettle();
    var runs = 0;
    backend.override = (request) {
      if (request.url.path.endsWith('/run')) {
        runs++;
        return jsonResponse({'unexpected': true});
      }
      return null;
    };
    await tester.tap(find.text('Vérifier maintenant'));
    await tester.pumpAndSettle();
    expect(runs, 1);
    expect(find.textContaining('a peut-être été traitée'), findsOneWidget);
    expect(find.textContaining('Consultez l’historique'), findsOneWidget);
  });

  testApp('suspendre puis reprendre, modifier, supprimer', (tester) async {
    final backend = FakeBackend();
    final automation = backend.addAutomation(threshold: 80);
    await pumpApp(tester, backend);
    await openTasks(tester);
    await tester.tap(find.text('Vérification du disque'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Suspendre'));
    await tester.pumpAndSettle();
    expect(automation['enabled'], false);
    expect(find.text('Vérifications suspendues.'), findsOneWidget);
    expect(find.textContaining('aucune (suspendue)'), findsOneWidget);
    await tester.tap(find.text('Reprendre'));
    await tester.pumpAndSettle();
    expect(automation['enabled'], true);

    await tester.tap(find.byTooltip('Modifier'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(
        TextFormField,
        'Seuil d’alerte (% du disque utilisé)',
      ),
      '70',
    );
    await tester.tap(find.text('toutes les heures'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('toutes les 30 min').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(automation['threshold_percent'], 70.0);
    expect(automation['interval_minutes'], 30);
    expect(find.text('Modifications enregistrées.'), findsOneWidget);

    await tester.tap(find.byTooltip('Supprimer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(backend.automations, hasLength(1));
    await tester.tap(find.byTooltip('Supprimer'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Supprimer'));
    await tester.pumpAndSettle();
    expect(backend.automations, isEmpty);
    expect(find.text('Aucune automatisation'), findsOneWidget);
  });

  testApp('alertes du téléphone : permission accordée puis refusée', (
    tester,
  ) async {
    final alerts = FakeAlerts();
    await pumpApp(tester, FakeBackend(), alerts: alerts);
    await openTasks(tester);
    expect(find.textContaining('Désactivées'), findsOneWidget);
    await tester.tap(find.text('Alertes sur ce téléphone'));
    await tester.pumpAndSettle();
    expect(alerts.enabled, isTrue);
    expect(find.textContaining('même application fermée'), findsOneWidget);
    await tester.tap(find.text('Alertes sur ce téléphone'));
    await tester.pumpAndSettle();
    expect(alerts.enabled, isFalse);

    alerts.permitted = false;
    await tester.tap(find.text('Alertes sur ce téléphone'));
    await tester.pumpAndSettle();
    expect(find.text('Notifications refusées par Android.'), findsOneWidget);
    expect(alerts.enabled, isFalse);
  });

  testApp('alertes activées mais bloquées dans Android : expliqué', (
    tester,
  ) async {
    final alerts = FakeAlerts(permitted: false)..enabled = true;
    await pumpApp(tester, FakeBackend(), alerts: alerts);
    await openTasks(tester);
    expect(find.textContaining('bloquées par Android'), findsOneWidget);
  });

  testApp('403 sur les automatisations : expliqué', (tester) async {
    final backend = FakeBackend()..forbidden.add('/api/v1/automations');
    await pumpApp(tester, backend);
    await openTasks(tester);
    expect(find.text('Accès refusé'), findsOneWidget);
  });
}

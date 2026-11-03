import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora/src/ui/screens/approval_detail_screen.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';

Finder textHas(String part) => find.textContaining(part, findRichText: true);

Future<void> goBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
}

Future<void> tapText(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  group('premier lancement et réglages', () {
    testApp('explique Tailscale, valide l’adresse, teste et enregistre', (
      tester,
    ) async {
      final backend = FakeBackend();
      final state = await pumpApp(tester, backend, configured: false);
      expect(find.text('Bienvenue dans NEXORA'), findsOneWidget);
      expect(textHas('activez Tailscale'), findsOneWidget);

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'http://serveur.test');
      await tapText(tester, 'Tester la connexion');
      expect(textHas('HTTPS obligatoire'), findsOneWidget);
      expect(backend.requests, isEmpty);

      await tester.enterText(fields.at(0), testBaseUrl);
      await tester.enterText(fields.at(1), 'mauvaise');
      await tapText(tester, 'Tester la connexion');
      expect(textHas('clé personnelle est refusée'), findsOneWidget);

      await tester.enterText(fields.at(1), testApiKey);
      await tapText(tester, 'Tester la connexion');
      expect(textHas('Connexion réussie'), findsOneWidget);

      await tapText(tester, 'Enregistrer');
      expect(state.configured, isTrue);
      expect(find.text('Discussions'), findsWidgets);
      // The key typed earlier is never displayed back.
      expect(find.text(testApiKey), findsNothing);
    });

    testApp('changer d’adresse exige la clé de la nouvelle adresse', (
      tester,
    ) async {
      final backend = FakeBackend();
      final state = await pumpApp(tester, backend);
      await tapText(tester, 'Réglages');
      backend.requests.clear();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'https://autre.test:8101');
      await tapText(tester, 'Tester la connexion');
      expect(textHas('n’est jamais envoyée à une autre'), findsOneWidget);
      await tapText(tester, 'Enregistrer');
      expect(state.baseUrl, testBaseUrl);
      expect(
        backend.requests.where((r) => r.url.host == 'autre.test'),
        isEmpty,
        reason: 'l’ancienne clé ne part jamais vers la nouvelle adresse',
      );
    });

    testApp('supprimer la clé demande confirmation', (tester) async {
      final backend = FakeBackend();
      final state = await pumpApp(tester, backend);
      await tapText(tester, 'Réglages');
      expect(textHas('Une clé est enregistrée'), findsOneWidget);
      await tapText(tester, 'Supprimer la clé de ce téléphone');
      await tapText(tester, 'Annuler');
      expect(state.hasKey, isTrue);
      await tapText(tester, 'Supprimer la clé de ce téléphone');
      await tapText(tester, 'Supprimer');
      expect(state.hasKey, isFalse);
      expect(find.text('Bienvenue dans NEXORA'), findsOneWidget);
    });
  });

  testApp('tableau de bord : 403 expliqué sans masquer le reste', (
    tester,
  ) async {
    final backend = FakeBackend()..forbidden.add('/api/v1/server/metrics');
    await pumpApp(tester, backend);
    await tapText(tester, 'Serveur');
    expect(textHas('server:read'), findsOneWidget);
    expect(textHas('n’a pas le droit'), findsOneWidget);
    expect(find.text('Disponible'), findsNWidgets(2));
    expect(find.text('Simulation — pas une IA réelle'), findsOneWidget);
    expect(textHas('ne garantit pas'), findsOneWidget);
  });

  testApp('tableau de bord : jauges datées', (tester) async {
    await pumpApp(tester, FakeBackend());
    await tapText(tester, 'Serveur');
    expect(find.text('Processeur'), findsOneWidget);
    expect(find.text('12,5 %'), findsOneWidget);
    expect(textHas('Mesuré'), findsOneWidget);
    expect(textHas('serveur Ubuntu'), findsOneWidget);
  });

  testApp('conversation : créer, envoyer, réponse simulée signalée', (
    tester,
  ) async {
    final backend = FakeBackend();
    await pumpApp(tester, backend);
    expect(find.text('Aucune conversation'), findsOneWidget);
    await tapText(tester, 'Nouvelle conversation');
    await tapText(tester, 'Créer');
    expect(backend.conversations, hasLength(1));

    await tester.enterText(find.byType(TextField).last, 'Bonjour serveur');
    await tester.pump();
    await tester.tap(find.byTooltip('Envoyer'));
    await tester.pumpAndSettle();
    expect(textHas('Bonjour serveur'), findsWidgets);
    expect(textHas('Réponse simulée à : Bonjour serveur'), findsOneWidget);
    expect(textHas('**'), findsNothing, reason: 'gras rendu, balises masquées');
    expect(find.text('Simulation — pas une IA réelle'), findsOneWidget);
    expect(backend.turns, 1);
  });

  testApp('validation : approuver puis exécuter, deux actions explicites', (
    tester,
  ) async {
    final backend = FakeBackend();
    final state = await pumpApp(tester, backend);
    await tapText(tester, 'Nouvelle conversation');
    await tapText(tester, 'Créer');
    await tester.enterText(
      find.byType(TextField).last,
      'lance une action de test',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Envoyer'));
    await tester.pumpAndSettle();
    expect(textHas('attend votre validation'), findsOneWidget);
    expect(backend.executions, 0);

    await tapText(tester, 'Ouvrir la validation');
    expect(find.byType(ApprovalDetailScreen), findsOneWidget);
    await goBack(tester);
    expect(
      textHas('attend votre validation'),
      findsNothing,
      reason: 'bannière retirée au retour de la validation',
    );
    await tapText(tester, 'Ouvrir la validation');
    expect(find.text('En attente'), findsOneWidget);
    expect(textHas('"message": "bonjour"'), findsWidgets);
    expect(textHas(testHash), findsOneWidget);

    await tapText(tester, 'Approuver');
    expect(find.text('Approuver cette action ?'), findsOneWidget);
    await tapText(tester, 'Annuler');
    expect(backend.approvals.values.single['status'], 'pending');

    await tapText(tester, 'Approuver');
    await tapText(tester, 'Approuver');
    expect(find.text('Approuvée, non exécutée'), findsOneWidget);
    expect(backend.executions, 0, reason: 'approuver n’exécute pas');

    await tapText(tester, 'Exécuter maintenant');
    await tapText(tester, 'Exécuter');
    expect(backend.executions, 1);
    expect(find.text('Exécutée'), findsOneWidget);
    expect(find.text('Réussi'), findsOneWidget);
    expect(textHas('ajouté à la conversation'), findsOneWidget);
    expect(state.pendingApprovals, 0);

    // Back to the conversation: the tool result is in the history.
    await goBack(tester);
    await tester.tap(find.byTooltip('Recharger l’historique'));
    await tester.pumpAndSettle();
    expect(find.text('Action de test'), findsOneWidget);
    expect(find.text('Réussi'), findsOneWidget);
  });

  testApp('validation consommée : résultat rejoué, jamais réexécuté', (
    tester,
  ) async {
    final backend = FakeBackend()..addApproval(status: 'consumed');
    await pumpApp(tester, backend);
    await tapText(tester, 'Validations');
    await tapText(tester, 'Toutes');
    expect(textHas('demandée'), findsOneWidget);
    expect(textHas('expire'), findsNothing);
    await tapText(tester, 'Action de test');
    expect(textHas('ne peut pas être relancée'), findsOneWidget);
    await tapText(tester, 'Afficher le résultat enregistré');
    expect(textHas('aucune nouvelle exécution'), findsOneWidget);
    expect(backend.executions, 0);
  });

  testApp('validation refusée avec motif', (tester) async {
    final backend = FakeBackend()..addApproval();
    await pumpApp(tester, backend);
    await tapText(tester, 'Validations');
    await tapText(tester, 'Action de test');
    await tapText(tester, 'Refuser');
    await tester.enterText(find.byType(TextField).last, 'pas maintenant');
    await tapText(tester, 'Refuser');
    final approval = backend.approvals.values.single;
    expect(approval['status'], 'rejected');
    expect(approval['decision_reason'], 'pas maintenant');
    expect(find.text('Refusée'), findsOneWidget);
    expect(find.text('Approuver'), findsNothing);
  });

  testApp('validation expirée côté serveur : statut rechargé', (tester) async {
    final backend = FakeBackend();
    final approval = backend.addApproval(status: 'approved');
    await pumpApp(tester, backend);
    await tapText(tester, 'Validations');
    await tapText(tester, 'Toutes');
    await tapText(tester, 'Action de test');
    approval['status'] = 'expired';
    await tapText(tester, 'Exécuter maintenant');
    await tapText(tester, 'Exécuter');
    expect(textHas('a expiré'), findsOneWidget);
    expect(find.text('Expirée'), findsOneWidget);
    expect(find.text('Exécuter maintenant'), findsNothing);
    expect(backend.executions, 0);
  });

  testApp('badge des validations en attente', (tester) async {
    final backend = FakeBackend()
      ..addApproval()
      ..addApproval();
    await pumpApp(tester, backend);
    expect(find.byTooltip('2 validation(s) en attente'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  group('petit écran, thème sombre, grand texte', () {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testApp('aucun débordement (${mode.name})', (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final backend = FakeBackend()..addApproval(risk: 'high');
        final id = backend.addConversation('Charge du serveur')['id'] as String;
        backend
          ..addMessage(id, 'user', 'Quelle est la charge ?')
          ..addMessage(
            id,
            'assistant',
            'Charge **faible**.',
            provider: 'simulated',
          );
        await pumpApp(tester, backend, themeMode: mode);
        for (final tab in ['Serveur', 'Validations', 'Réglages']) {
          await tapText(tester, tab);
          expect(tester.takeException(), isNull, reason: tab);
        }
        await tapText(tester, 'Validations');
        await tapText(tester, 'Action de test');
        expect(tester.takeException(), isNull);
        await goBack(tester);
        await tapText(tester, 'Messages');
        await tapText(tester, 'Charge du serveur');
        expect(tester.takeException(), isNull);
      });
    }
  });
}

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

/// The validations button of the header (shield with the pending count).
Future<void> openValidations(WidgetTester tester) async {
  await tester.tap(
    find
        .byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              (widget.tooltip ?? '').startsWith('Validations'),
        )
        .first,
  );
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
      // Messages is the main screen: a first conversation is opened directly.
      expect(find.text('NEXORA'), findsOneWidget);
      expect(find.text('Bonjour, que puis-je faire ?'), findsOneWidget);
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
    expect(find.text('12,5\u00a0%'), findsOneWidget);
    expect(textHas('Mesuré'), findsOneWidget);
    expect(textHas('serveur Ubuntu'), findsOneWidget);
  });

  testApp('tableau de bord : projets GitHub en lecture seule', (tester) async {
    final backend = FakeBackend();
    await pumpApp(tester, backend);
    await tapText(tester, 'Serveur');
    await tester.scrollUntilVisible(
      find.text('Dhafer84/assistant'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Mobile checks : échec'), findsOneWidget);
    expect(find.text('2 issue(s) ouverte(s)'), findsOneWidget);
    expect(textHas('Enregistre l’adresse et la clé ensemble'), findsOneWidget);
    expect(
      find.text('Dépôt introuvable, ou privé sans jeton d’accès'),
      findsOneWidget,
    );
    expect(
      backend.requests
          .where((r) => r.url.path.contains('github'))
          .map((r) => r.method)
          .toSet(),
      {'GET'},
    );
  });

  testApp('conversation : créer, envoyer, réponse simulée signalée', (
    tester,
  ) async {
    final backend = FakeBackend();
    await pumpApp(tester, backend);
    // No conversation yet: Messages creates one and opens it.
    expect(find.text('Bonjour, que puis-je faire ?'), findsOneWidget);
    expect(backend.conversations, hasLength(1));
    expect(find.text('Connecté'), findsOneWidget);

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
    await tester.enterText(
      find.byType(TextField).last,
      'lance une action de test',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Envoyer'));
    await tester.pumpAndSettle();
    expect(find.text('Validation requise'), findsOneWidget);
    expect(textHas('Rien n’est exécuté sans votre accord'), findsOneWidget);
    expect(backend.executions, 0);
    expect(find.byTooltip('Validations : 1 en attente'), findsOneWidget);

    await tapText(tester, 'Voir la demande');
    expect(find.byType(ApprovalDetailScreen), findsOneWidget);
    await goBack(tester);
    expect(
      find.text('Validation requise'),
      findsOneWidget,
      reason: 'toujours en attente : rien n’a été décidé',
    );
    await tapText(tester, 'Voir la demande');
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

    // Back to the conversation: the request is no longer pending and the
    // result is in the history.
    await goBack(tester);
    expect(find.text('Validation requise'), findsNothing);
    expect(find.text('Demande de validation traitée'), findsOneWidget);
    expect(find.text('Action de démonstration'), findsOneWidget);
    expect(find.text('Exécutée'), findsOneWidget);
  });

  testApp('chat : carte « Espace disque » avec la valeur réelle', (
    tester,
  ) async {
    final backend = FakeBackend()..diskPercent = 63.4;
    await pumpApp(tester, backend);
    await tester.enterText(
      find.byType(TextField).last,
      'Vérifie l’espace disque',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Envoyer'));
    await tester.pumpAndSettle();
    expect(find.text('Espace disque'), findsOneWidget);
    expect(find.text('63,4\u00a0%'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Espace disque utilisé : 63,4\u00a0%'),
      findsOneWidget,
    );
    expect(textHas('Mémoire 41,7'), findsOneWidget);
    // A read-only check never asks for a validation.
    expect(find.text('Validation requise'), findsNothing);
    expect(backend.approvals, isEmpty);
    // The answer comes before its card, as on the reference design.
    final answer = tester.getTopLeft(textHas('Le disque est utilisé'));
    final card = tester.getTopLeft(find.text('Espace disque'));
    expect(answer.dy, lessThan(card.dy));
  });

  testApp('chat : ancien message d’outil sans données structurées', (
    tester,
  ) async {
    final backend = FakeBackend();
    final id = backend.addConversation('Ancienne')['id'] as String;
    backend
      ..addMessage(id, 'user', 'État ?')
      ..addMessage(id, 'tool', 'texte libre (ancien format)')
      ..addMessage(id, 'assistant', 'Tout va bien.');
    await pumpApp(tester, backend);
    expect(textHas('Tout va bien.'), findsOneWidget);
    expect(find.text('Espace disque'), findsNothing);
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    expect(find.text('texte libre (ancien format)'), findsOneWidget);
  });

  testApp('validation consommée : résultat rejoué, jamais réexécuté', (
    tester,
  ) async {
    final backend = FakeBackend()..addApproval(status: 'consumed');
    await pumpApp(tester, backend);
    await openValidations(tester);
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
    await openValidations(tester);
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
    await openValidations(tester);
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
    // Global access in every tab header.
    for (final tab in ['Messages', 'Serveur', 'Tâches', 'Réglages']) {
      await tapText(tester, tab);
      expect(find.byTooltip('Validations : 2 en attente'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    }
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
        backend
          ..addAutomation(name: 'Vérification du disque du serveur principal')
          ..diskPercent = 91.25;
        for (final tab in ['Serveur', 'Tâches', 'Réglages']) {
          await tapText(tester, tab);
          expect(tester.takeException(), isNull, reason: tab);
        }
        await openValidations(tester);
        expect(tester.takeException(), isNull);
        await goBack(tester);
        await tapText(tester, 'Tâches');
        await tester.scrollUntilVisible(
          find.text('Vérification du disque du serveur principal'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tapText(tester, 'Vérification du disque du serveur principal');
        await tapText(tester, 'Vérifier maintenant');
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Modifier'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await goBack(tester);
        await goBack(tester);
        await openValidations(tester);
        await tapText(tester, 'Action de test');
        expect(tester.takeException(), isNull);
        await goBack(tester);
        await goBack(tester);
        await tapText(tester, 'Messages');
        expect(textHas('Charge faible.'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Plus d’options'));
        await tester.pumpAndSettle();
        await tapText(tester, 'Discussions');
        await tapText(tester, 'Charge du serveur');
        expect(tester.takeException(), isNull);
      });
    }
  });
}

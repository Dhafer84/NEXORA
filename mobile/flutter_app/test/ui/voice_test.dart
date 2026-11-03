import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora/src/voice/voice_controller.dart';
import 'package:nexora/src/voice/voice_service.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';
import '../support/fake_voice.dart';

Finder textHas(String part) => find.textContaining(part, findRichText: true);

String fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).last).controller!.text;

/// Messages sent to the server (dictation must never send by itself).
int sentMessages(FakeBackend backend) => backend.requests
    .where((r) => r.method == 'POST' && r.url.path.endsWith('/messages'))
    .length;

Future<FakeVoice> pumpWithVoice(
  WidgetTester tester, {
  FakeBackend? backend,
  FakeVoice? voice,
}) async {
  // The pulsing microphone respects "remove animations": settle-able tests.
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  final fake = voice ?? FakeVoice();
  await pumpApp(tester, backend ?? FakeBackend(), voice: fake);
  return fake;
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> tapMic(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Dicter un message').first);
  await tester.pumpAndSettle();
}

void main() {
  testApp('dictée : la transcription va dans le champ, sans envoi', (
    tester,
  ) async {
    final backend = FakeBackend();
    final voice = await pumpWithVoice(tester, backend: backend);
    await tapMic(tester);
    expect(voice.calls, ['permission', 'start(remote: false)']);
    expect(find.text('J’écoute…'), findsOneWidget);
    expect(find.byTooltip('Arrêter l’écoute'), findsOneWidget);
    expect(find.byTooltip('Annuler la dictée'), findsOneWidget);

    voice.emit(const PartialTranscript('Vérifie'));
    await tester.pumpAndSettle();
    expect(find.text('Vérifie'), findsOneWidget);

    await tester.tap(find.byTooltip('Arrêter l’écoute'));
    voice.emit(const FinalTranscript('Vérifie l’espace disque'));
    await tester.pumpAndSettle();
    expect(voice.calls.last, 'stop');
    expect(fieldText(tester), 'Vérifie l’espace disque');
    expect(find.text('J’écoute…'), findsNothing);
    expect(sentMessages(backend), 0, reason: 'jamais d’envoi automatique');

    // The user corrects, then sends explicitly: same path as typed text.
    await tester.enterText(find.byType(TextField).last, 'Vérifie le disque');
    await tester.pump();
    await tester.tap(find.byTooltip('Envoyer'));
    await tester.pumpAndSettle();
    expect(sentMessages(backend), 1);
    expect(textHas('Réponse simulée à : Vérifie le disque'), findsOneWidget);
  });

  testApp('dictée annulée : rien n’est ajouté, même un résultat tardif', (
    tester,
  ) async {
    final voice = await pumpWithVoice(tester);
    await tester.enterText(find.byType(TextField).last, 'Bonjour');
    await tester.pump();
    await tapMic(tester);
    voice.emit(const PartialTranscript('efface tout'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Annuler la dictée'));
    await tester.pumpAndSettle();
    expect(voice.calls.last, 'cancel');
    // A late result from the service after the cancel is ignored.
    voice.emit(const FinalTranscript('efface tout'));
    await tester.pumpAndSettle();
    expect(fieldText(tester), 'Bonjour');
  });

  testApp('transcription ajoutée au texte déjà saisi', (tester) async {
    final voice = await pumpWithVoice(tester);
    await tester.enterText(find.byType(TextField).last, 'Bonjour');
    await tester.pump();
    await tapMic(tester);
    voice.emit(const FinalTranscript('vérifie le serveur'));
    await tester.pumpAndSettle();
    expect(fieldText(tester), 'Bonjour vérifie le serveur');
  });

  testApp('micro refusé : explication, la saisie texte reste possible', (
    tester,
  ) async {
    final backend = FakeBackend();
    final voice = await pumpWithVoice(
      tester,
      backend: backend,
      voice: FakeVoice(permission: MicPermission.denied),
    );
    await tapMic(tester);
    expect(textHas('Micro refusé'), findsOneWidget);
    expect(voice.listened, isFalse);
    await tester.enterText(find.byType(TextField).last, 'Écrit à la main');
    await tester.pump();
    await tester.tap(find.byTooltip('Envoyer'));
    await tester.pumpAndSettle();
    expect(sentMessages(backend), 1);
  });

  testApp('micro refusé définitivement : lien vers les réglages Android', (
    tester,
  ) async {
    final voice = await pumpWithVoice(
      tester,
      voice: FakeVoice(permission: MicPermission.permanentlyDenied),
    );
    await tapMic(tester);
    expect(textHas('Autorisez-le dans les réglages Android'), findsOneWidget);
    await tester.tap(find.text('Réglages Android'));
    await tester.pumpAndSettle();
    expect(voice.calls.last, 'settings');
    expect(voice.listened, isFalse);
  });

  testApp('aucun service vocal : expliqué, rien n’écoute', (tester) async {
    final voice = await pumpWithVoice(
      tester,
      voice: FakeVoice(recognition: RecognitionMode.unavailable),
    );
    await tapMic(tester);
    expect(textHas('Aucune reconnaissance vocale en français'), findsOneWidget);
    expect(voice.calls, isEmpty, reason: 'pas même la permission du micro');
  });

  testApp('reconnaissance en ligne : seulement après accord explicite', (
    tester,
  ) async {
    final voice = FakeVoice(recognition: RecognitionMode.remote);
    await pumpWithVoice(tester, voice: voice);
    await tapMic(tester);
    expect(textHas('peut envoyer l’audio'), findsOneWidget);
    expect(textHas('Service vocal de test'), findsOneWidget);
    expect(voice.listened, isFalse);

    // Settings: the switch asks for confirmation, off by default.
    await tester.tap(find.text('Réglages').last);
    await tester.pumpAndSettle();
    final remoteSwitch = find.text('Autoriser la reconnaissance en ligne');
    await tapVisible(tester, remoteSwitch);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    await tapVisible(tester, remoteSwitch);
    await tester.tap(find.text('Activer'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();
    await tapMic(tester);
    expect(voice.calls.last, 'start(remote: true)');
  });

  testApp('passage en arrière-plan : l’écoute s’arrête sans rien garder', (
    tester,
  ) async {
    final voice = await pumpWithVoice(tester);
    await tapMic(tester);
    voice.emit(const PartialTranscript('quelque chose'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(voice.calls, contains('cancel'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(textHas('Écoute interrompue'), findsOneWidget);
    expect(fieldText(tester), isEmpty);
  });

  testApp('dialogue de permission (inactive) : l’écoute continue', (
    tester,
  ) async {
    final voice = await pumpWithVoice(tester);
    await tapMic(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(voice.calls, isNot(contains('cancel')));
    expect(find.text('J’écoute…'), findsOneWidget);
    voice.emit(const FinalTranscript('Vérifie l’espace disque'));
    await tester.pumpAndSettle();
    expect(fieldText(tester), 'Vérifie l’espace disque');
  });

  testApp('service occupé ou rien compris : message, champ inchangé', (
    tester,
  ) async {
    final voice = await pumpWithVoice(tester);
    await tapMic(tester);
    voice.emit(const ListeningFailed('no_match'));
    await tester.pumpAndSettle();
    expect(textHas('Rien n’a été compris'), findsOneWidget);
    await tapMic(tester);
    voice.emit(const ListeningFailed('network'));
    await tester.pumpAndSettle();
    expect(textHas('n’a pas pu joindre son serveur'), findsOneWidget);
    expect(fieldText(tester), isEmpty);
  });

  testApp('Écouter puis Arrêter ; la dictée coupe la lecture d’abord', (
    tester,
  ) async {
    final backend = FakeBackend();
    final id = backend.addConversation('Disque')['id'] as String;
    backend.addMessage(id, 'user', 'Disque ?');
    final reply = backend.addMessage(
      id,
      'assistant',
      'Le disque est à **72 %**.',
    );
    final voice = await pumpWithVoice(tester, backend: backend);
    await tester.tap(find.byTooltip('Écouter la réponse'));
    await tester.pumpAndSettle();
    expect(voice.calls, ['speak:${reply['id']}']);
    expect(voice.spoken.single, 'Le disque est à 72 %.');
    expect(find.byTooltip('Arrêter la lecture'), findsOneWidget);

    // Dictating while NEXORA speaks: reading stops before listening starts.
    await tapMic(tester);
    final stop = voice.calls.indexOf('stopSpeaking');
    final start = voice.calls.indexOf('start(remote: false)');
    expect(stop, isNonNegative);
    expect(stop, lessThan(start));
    await tester.tap(find.byTooltip('Annuler la dictée'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Écouter la réponse'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Arrêter la lecture'));
    await tester.pumpAndSettle();
    expect(voice.calls.last, 'stopSpeaking');
    expect(find.byTooltip('Écouter la réponse'), findsOneWidget);
  });

  testApp('lecture automatique : désactivée par défaut, facultative', (
    tester,
  ) async {
    final voice = await pumpWithVoice(tester);
    await tester.enterText(find.byType(TextField).last, 'Bonjour');
    await tester.pump();
    await tester.tap(find.byTooltip('Envoyer'));
    await tester.pumpAndSettle();
    expect(voice.spoken, isEmpty);

    await tester.tap(find.text('Réglages').last);
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('Lire les réponses automatiquement'));
    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Encore');
    await tester.pump();
    await tester.tap(find.byTooltip('Envoyer'));
    await tester.pumpAndSettle();
    expect(voice.spoken, ['Réponse simulée à : Encore']);
  });

  test('texte lu : sans balises ni identifiants techniques', () {
    expect(
      plainText(
        '**Validation** requise : demande '
        '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0, via /api/v1/approvals/{id}.',
      ),
      'Validation requise : demande , via',
    );
  });
}

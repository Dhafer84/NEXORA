import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora/main.dart';
import 'package:nexora/src/bubble/bubble_service.dart';
import 'package:nexora/src/session/session.dart';
import 'package:nexora/src/state/app_state.dart';
import 'package:nexora/src/ui/mini_chat.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';
import '../support/fake_voice.dart';

Finder textHas(String part) => find.textContaining(part, findRichText: true);

int sentMessages(FakeBackend backend) => backend.requests
    .where((r) => r.method == 'POST' && r.url.path.endsWith('/messages'))
    .length;

/// The mini-chat (left) and the full app (right), open at the same time on one
/// server, sharing drafts and the in-flight turn as the two Android windows do.
class TwoWindows {
  TwoWindows(this.backend, this.mini, this.app, this.miniBubble, this.session);

  final FakeBackend backend;
  final AppState mini;
  final AppState app;
  final FakeBubble miniBubble;
  final MemorySessionStore session;

  Finder inMini(Finder finder) =>
      find.descendant(of: find.byKey(const Key('mini')), matching: finder);
  Finder inApp(Finder finder) =>
      find.descendant(of: find.byKey(const Key('app')), matching: finder);
}

Future<TwoWindows> pumpTwoWindows(WidgetTester tester) async {
  tester.view.physicalSize = const Size(2160, 2340);
  tester.view.devicePixelRatio = 2.625;
  final backend = FakeBackend();
  final id = backend.addConversation('Discussion')['id'] as String;
  backend
    ..addMessage(id, 'user', 'Bonjour')
    ..addMessage(id, 'assistant', 'Bonjour, je suis NEXORA.');
  final turns = MemoryTurnLock();
  final session = MemorySessionStore();
  await session.setString(SessionKeys.currentConversation, id);
  final miniBubble = FakeBubble(conversation: id);
  final mini = await startState(
    backend,
    turns: turns,
    session: session,
    bubble: miniBubble,
    window: 'bubble',
  );
  final app = await startState(
    backend,
    turns: turns,
    session: session,
    bubble: FakeBubble(),
  );
  await tester.pumpWidget(
    Row(
      textDirection: TextDirection.ltr,
      children: [
        Expanded(
          child: NexoraApp(
            key: const Key('mini'),
            state: mini,
            themeMode: ThemeMode.dark,
            home: const MiniChat(),
          ),
        ),
        Expanded(
          child: NexoraApp(key: const Key('app'), state: app),
        ),
      ],
    ),
  );
  await mini.load();
  await app.load();
  await tester.pumpAndSettle();
  return TwoWindows(backend, mini, app, miniBubble, session);
}

void main() {
  testApp('mini-chat : même discussion, même historique que l’application', (
    tester,
  ) async {
    final w = await pumpTwoWindows(tester);
    expect(w.inMini(textHas('Bonjour, je suis NEXORA.')), findsOneWidget);
    expect(w.inApp(textHas('Bonjour, je suis NEXORA.')), findsOneWidget);
    expect(w.inMini(find.byTooltip('Agrandir en plein écran')), findsOneWidget);
    // Reduced by Android (bubble icon, outside tap, Back): no app button.
    expect(w.inMini(find.byTooltip('Réduire la bulle')), findsNothing);
  });

  testApp('deux fenêtres ouvertes : un seul envoi, historique actualisé', (
    tester,
  ) async {
    final w = await pumpTwoWindows(tester);
    final gate = w.backend.turnGate = Completer<void>();
    await tester.enterText(
      w.inMini(find.byType(TextField)),
      'Vérifie l’espace disque',
    );
    await tester.pump();
    await tester.tap(w.inMini(find.byTooltip('Envoyer')));
    await tester.pump();
    await tester.pump();
    // The full app sees the message in flight and cannot send meanwhile.
    expect(w.inApp(textHas('Envoi depuis la bulle')), findsOneWidget);
    final appField = tester.widget<TextField>(w.inApp(find.byType(TextField)));
    expect(appField.enabled, isFalse);
    expect(
      tester
          .widget<IconButton>(
            w.inApp(find.widgetWithIcon(IconButton, Icons.send_rounded)),
          )
          .onPressed,
      isNull,
    );
    expect(sentMessages(w.backend), 1);

    gate.complete();
    await tester.pumpAndSettle();
    expect(sentMessages(w.backend), 1, reason: 'aucun double envoi');
    // Both windows show the answer once, the app after refreshing its history.
    expect(w.inMini(textHas('Le disque est utilisé')), findsOneWidget);
    expect(w.inApp(textHas('Le disque est utilisé')), findsOneWidget);
    expect(w.inApp(find.text('Espace disque')), findsOneWidget);
    expect(w.inApp(textHas('Envoi depuis la bulle')), findsNothing);
  });

  testApp('plein écran : le brouillon suit, rien n’est envoyé', (tester) async {
    final w = await pumpTwoWindows(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.enterText(
      w.inMini(find.byType(TextField)),
      'Brouillon commencé dans la bulle',
    );
    await tester.pump();
    await tester.tap(w.inMini(find.byTooltip('Agrandir en plein écran')));
    await tester.pumpAndSettle();
    final id = await w.app.currentConversation();
    expect(w.miniBubble.calls, ['fullScreen:$id:-']);
    // Still in front after the switch (the app was already open): explained.
    await tester.pump(const Duration(seconds: 1));
    expect(w.inMini(textHas('derrière la bulle')), findsOneWidget);
    // The full app comes to the front and restores the draft.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(w.inApp(find.byType(TextField)));
    expect(field.controller!.text, 'Brouillon commencé dans la bulle');
    expect(sentMessages(w.backend), 0);
  });

  testApp('validation depuis le mini-chat : ouverte en plein écran, jamais '
      'approuvée', (tester) async {
    final w = await pumpTwoWindows(tester);
    await tester.enterText(
      w.inMini(find.byType(TextField)),
      'lance une action de test',
    );
    await tester.pump();
    await tester.tap(w.inMini(find.byTooltip('Envoyer')));
    await tester.pumpAndSettle();
    final approval = w.backend.approvals.values.single;
    // Compact card in the mini-chat, no approve button anywhere in it.
    expect(w.inMini(find.text('Validation requise')), findsOneWidget);
    expect(w.inMini(find.text('Approuver')), findsNothing);
    await tester.tap(w.inMini(find.text('Validation requise')));
    await tester.pumpAndSettle();
    expect(
      w.miniBubble.calls.last,
      'fullScreen:${approval['conversation_id']}:${approval['id']}',
    );
    expect(approval['status'], 'pending');
    expect(w.backend.executions, 0);
  });

  testApp('demande ouverte par le mini-chat : écran de validation existant', (
    tester,
  ) async {
    final backend = FakeBackend();
    final approval = backend.addApproval();
    final bubble = FakeBubble();
    await pumpApp(tester, backend, bubble: bubble);
    bubble.launch(LaunchRequest(approvalId: approval['id'] as String));
    await tester.pumpAndSettle();
    expect(find.text('Validation'), findsOneWidget);
    expect(find.text('Approuver'), findsOneWidget);
    expect(approval['status'], 'pending', reason: 'deux gestes explicites');
  });

  group('réglage de la bulle', () {
    testApp('activer la bulle ouvre la discussion courante', (tester) async {
      final backend = FakeBackend();
      final bubble = FakeBubble();
      final state = await pumpApp(tester, backend, bubble: bubble);
      await tester.tap(find.text('Réglages').last);
      await tester.pumpAndSettle();
      final toggle = find.text('Bulle NEXORA');
      await tester.scrollUntilVisible(
        toggle,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final id = await state.currentConversation();
      expect(bubble.calls, ['show:$id']);
      expect(await state.bubbleEnabled(), isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(bubble.calls.last, 'hide');
      expect(await state.bubbleEnabled(), isFalse);
    });

    testApp('bulle indisponible : raccourci proposé', (tester) async {
      final bubble = FakeBubble(availability: BubbleAvailability.unsupported);
      await pumpApp(tester, FakeBackend(), bubble: bubble);
      await tester.tap(find.text('Réglages').last);
      await tester.pumpAndSettle();
      final shortcut = find.text('Raccourci vers le chat');
      await tester.scrollUntilVisible(
        shortcut,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(shortcut);
      await tester.pumpAndSettle();
      expect(textHas('ne propose pas les bulles'), findsOneWidget);
      final toggle = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Bulle NEXORA'),
      );
      expect(toggle.onChanged, isNull);
      await tester.tap(shortcut);
      await tester.pumpAndSettle();
      expect(bubble.calls, ['pin']);
      expect(textHas('confirmez l’ajout'), findsOneWidget);
    });
  });
}

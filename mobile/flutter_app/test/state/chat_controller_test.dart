import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nexora/src/state/chat_controller.dart';

import '../support/fake_backend.dart';

void main() {
  late FakeBackend backend;
  late ChatController chat;
  late String id;

  setUp(() async {
    backend = FakeBackend();
    id = backend.addConversation('Essai')['id'] as String;
    chat = ChatController(api: backend.api(), conversationId: id);
    await chat.reload();
  });

  tearDown(() => chat.dispose());

  int turnsSent() => backend.requests
      .where((r) => r.method == 'POST' && r.url.path.endsWith('/messages'))
      .length;

  test('envoi : affiche la question puis la réponse', () async {
    final outcome = await chat.send('  bonjour  ');
    expect(outcome, SendOutcome.sent);
    expect(chat.messages.map((m) => m.role), ['user', 'assistant']);
    expect(chat.messages.first.content, 'bonjour');
    expect(chat.messages.last.isSimulated, isTrue);
    expect(chat.sending, isFalse);
  });

  test('texte vide ignoré', () async {
    expect(await chat.send('   '), SendOutcome.ignored);
    expect(turnsSent(), 0);
  });

  test('pas de double envoi pendant un tour', () async {
    backend.turnGate = Completer<void>();
    final first = chat.send('un');
    expect(chat.sending, isTrue);
    expect(chat.pendingText, 'un');
    expect(await chat.send('deux'), SendOutcome.ignored);
    backend.turnGate!.complete();
    expect(await first, SendOutcome.sent);
    expect(turnsSent(), 1);
  });

  test('validation demandée : bannière avec identifiant', () async {
    await chat.send('lance une action de test');
    expect(chat.banner?.tone, BannerTone.warning);
    expect(chat.banner?.approvalId, backend.approvals.keys.single);
    expect(backend.executions, 0, reason: 'jamais exécutée automatiquement');
  });

  test('issue incertaine : pas de renvoi, historique rechargé', () async {
    backend.override = (request) {
      if (request.method == 'POST') {
        // The server stored the message, then the connection dropped.
        backend.addMessage(id, 'user', 'coupé');
        throw http.ClientException('Connection closed before full header');
      }
      return null;
    };
    final outcome = await chat.send('coupé');
    expect(outcome, SendOutcome.uncertain);
    expect(turnsSent(), 1);
    expect(chat.messages.single.content, 'coupé');
    expect(chat.banner?.message, contains('pas renvoyé automatiquement'));
  });

  test('503 fournisseur IA : recharge l’historique sans renvoyer', () async {
    backend.override = (request) {
      if (request.method != 'POST') return null;
      final user = backend.addMessage(id, 'user', 'question');
      final error = backend.addMessage(
        id,
        'assistant',
        'Fournisseur indisponible',
        status: 'error',
      );
      return jsonResponse({
        'detail': {
          'code': 'ai_unavailable',
          'message': 'Fournisseur indisponible',
          'messages': [user, error],
        },
      }, 503);
    };
    final outcome = await chat.send('question');
    expect(outcome, SendOutcome.sent);
    expect(chat.messages.map((m) => m.status), ['ok', 'error']);
    expect(chat.banner?.tone, BannerTone.error);
    expect(turnsSent(), 1);
  });

  test('503 : messages renvoyés gardés si le rechargement échoue', () async {
    backend.override = (request) {
      if (request.method == 'GET') {
        return errorResponse(503, 'database_unavailable', 'Base indisponible');
      }
      return jsonResponse({
        'detail': {
          'code': 'ai_timeout',
          'message': 'Délai dépassé',
          'messages': [
            {
              'id': 'm-user',
              'role': 'user',
              'content': 'question',
              'status': 'ok',
              'created_at': '2026-11-02T09:31:00Z',
            },
          ],
        },
      }, 503);
    };
    await chat.send('question');
    expect(chat.messages.single.id, 'm-user');
    expect(chat.banner?.message, contains('pas répondu à temps'));
  });

  test(
    'IA non configurée ou tour déjà en cours : brouillon restituable',
    () async {
      backend.override = (request) => request.method == 'POST'
          ? errorResponse(503, 'ai_not_configured', 'Aucun fournisseur')
          : null;
      expect(await chat.send('a'), SendOutcome.rejected);
      expect(chat.banner?.message, contains('Aucun fournisseur IA'));

      backend.override = (request) => request.method == 'POST'
          ? errorResponse(409, 'turn_in_progress', 'Tour en cours')
          : null;
      expect(await chat.send('b'), SendOutcome.rejected);
      expect(chat.banner?.message, contains('déjà en cours'));
    },
  );

  test('erreur de chargement exposée', () async {
    final missing = ChatController(api: backend.api(), conversationId: 'x');
    await missing.reload();
    expect(missing.loadError?.statusCode, 404);
    missing.dispose();
  });
}

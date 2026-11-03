import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora/src/api/api_client.dart';
import 'package:nexora/src/api/api_error.dart';

import '../support/fake_backend.dart';

NexoraApi apiWith(Future<http.Response> Function(http.Request) handler) =>
    NexoraApi(
      baseUrl: testBaseUrl,
      apiKey: testApiKey,
      client: MockClient(handler),
    );

Future<ApiError> failure(Future<Object?> call) async {
  try {
    await call;
  } on ApiError catch (error) {
    return error;
  }
  fail('ApiError attendue');
}

void main() {
  group('checkBaseUrl', () {
    test('accepte une adresse HTTPS avec port', () {
      expect(checkBaseUrl('https://serveur.exemple.ts.net:8101'), isNull);
      expect(checkBaseUrl(' https://serveur.exemple.ts.net:8101/ '), isNull);
    });

    test('refuse HTTP hors débogage, même vers l’émulateur', () {
      expect(
        checkBaseUrl('http://10.0.2.2:8000', allowLocalHttp: false),
        contains('HTTPS obligatoire'),
      );
      expect(
        checkBaseUrl('http://serveur.exemple:8000', allowLocalHttp: true),
        contains('HTTPS obligatoire'),
      );
      expect(
        checkBaseUrl('http://10.0.2.2:8000', allowLocalHttp: true),
        isNull,
      );
    });

    test('refuse identifiants, chemin, paramètres et adresse vide', () {
      expect(checkBaseUrl(''), contains('invalide'));
      expect(checkBaseUrl('serveur:8101'), isNotNull);
      expect(checkBaseUrl('https://a:b@serveur'), contains('identifiants'));
      expect(checkBaseUrl('https://serveur/api'), contains('chemin'));
      expect(checkBaseUrl('https://serveur?x=1'), contains('paramètres'));
    });

    test('normalise la barre finale', () {
      expect(normalizeBaseUrl(' https://s:1/ '), 'https://s:1');
    });
  });

  group('requêtes', () {
    test('envoie la clé dans l’en-tête seulement, jamais dans l’URL', () async {
      final backend = FakeBackend();
      await backend.api().authCheck();
      final request = backend.requests.single;
      expect(request.headers['Authorization'], 'Bearer $testApiKey');
      expect(request.url.toString(), isNot(contains(testApiKey)));
      expect(request.followRedirects, isFalse);
    });

    test('la sonde publique n’envoie pas la clé', () async {
      final backend = FakeBackend();
      await backend.api().live();
      expect(backend.requests.single.headers['Authorization'], isNull);
    });

    test('approuver envoie l’empreinte affichée', () async {
      final backend = FakeBackend();
      final created = backend.addApproval();
      final api = backend.api();
      final approval = await api.approval(created['id'] as String);
      final approved = await api.approve(approval);
      expect(approved.status, 'approved');
      final body = jsonDecode(backend.requests.last.body) as Map;
      expect(body, {'arguments_hash': testHash});
    });

    test('exécuter renvoie les paramètres exacts enregistrés', () async {
      final backend = FakeBackend();
      final created = backend.addApproval(
        status: 'approved',
        arguments: {'message': 'exact', 'n': 3},
      );
      final api = backend.api();
      final execution = await api.execute(
        await api.approval(created['id'] as String),
      );
      expect(execution.status, 'succeeded');
      expect(execution.replayed, isFalse);
      final body = jsonDecode(backend.requests.last.body) as Map;
      expect(body, {
        'arguments': {'message': 'exact', 'n': 3},
      });
    });

    test('refus : motif vide non envoyé', () async {
      final backend = FakeBackend();
      final created = backend.addApproval();
      await backend.api().reject(created['id'] as String, reason: '  ');
      expect(jsonDecode(backend.requests.last.body), isEmpty);
    });
  });

  group('erreurs', () {
    test('401 : clé refusée', () async {
      final error = await failure(FakeBackend().api(key: 'autre').authCheck());
      expect(error.kind, ApiErrorKind.unauthorized);
      expect(error.message, contains('Clé personnelle refusée'));
    });

    test('403 permission_denied : explique la permission', () async {
      final backend = FakeBackend()..forbidden.add('/api/v1/server/metrics');
      final error = await failure(backend.api().metrics());
      expect(error.kind, ApiErrorKind.forbidden);
      expect(error.code, 'permission_denied');
      expect(error.message, contains('server:read'));
      expect(error.message, contains('n’a pas le droit'));
    });

    test('503 ai_* : conserve les messages enregistrés', () async {
      final api = apiWith(
        (_) async => jsonResponse({
          'detail': {
            'code': 'ai_unavailable',
            'message': 'Fournisseur indisponible',
            'messages': [
              {
                'id': 'm1',
                'role': 'user',
                'content': 'bonjour',
                'status': 'ok',
                'created_at': '2026-11-02T09:30:00Z',
              },
            ],
          },
        }, 503),
      );
      final error = await failure(api.sendMessage('c1', 'bonjour'));
      expect(error.kind, ApiErrorKind.unavailable);
      expect(error.code, 'ai_unavailable');
      expect(error.messages.single.content, 'bonjour');
      expect(error.outcomeUnknown, isFalse);
    });

    test('422 : liste de validation lisible', () async {
      final api = apiWith(
        (_) async => jsonResponse({
          'detail': [
            {
              'loc': ['body', 'content'],
              'msg': 'trop long',
            },
          ],
        }, 422),
      );
      final error = await failure(api.sendMessage('c1', 'x'));
      expect(error.kind, ApiErrorKind.invalid);
      expect(error.message, 'Données refusées par le serveur.');
    });

    test('410 et 409 gardent le code serveur', () async {
      final backend = FakeBackend();
      final expired = backend.addApproval(status: 'expired');
      final rejected = backend.addApproval(status: 'rejected');
      final api = backend.api();
      final gone = await failure(
        api.execute(await api.approval(expired['id'] as String)),
      );
      expect((gone.kind, gone.code), (ApiErrorKind.gone, 'approval_expired'));
      final conflict = await failure(
        api.execute(await api.approval(rejected['id'] as String)),
      );
      expect(conflict.kind, ApiErrorKind.conflict);
      expect(conflict.code, 'approval_rejected');
    });

    test(
      'JSON valide mais hors contrat : erreur lisible, jamais TypeError',
      () async {
        final cases = <String, Future<Object?> Function(NexoraApi api)>{
          'liste avec null': (api) => api.approvals(),
          'champ manquant': (api) => api.metrics(),
          'date illisible': (api) => api.conversation('c1'),
        };
        final bodies = {
          'liste avec null': [null],
          'champ manquant': {'scope': 'host'},
          'date illisible': {
            'id': 'c1',
            'title': 't',
            'status': 'active',
            'created_at': 'hier',
            'updated_at': 'hier',
            'messages': [],
          },
        };
        for (final name in cases.keys) {
          final api = apiWith((_) async => jsonResponse(bodies[name]));
          final error = await failure(cases[name]!(api));
          expect(error.kind, ApiErrorKind.badResponse, reason: name);
          expect(error.message, 'Réponse inattendue du serveur.', reason: name);
          expect(error.outcomeUnknown, isFalse, reason: name);
        }
      },
    );

    test('écriture avec réponse hors contrat : issue incertaine', () async {
      final api = apiWith((_) async => jsonResponse({'status': 'completed'}));
      final error = await failure(api.sendMessage('c1', 'x'));
      expect(error.kind, ApiErrorKind.badResponse);
      expect(error.outcomeUnknown, isTrue);
      expect(error.message, contains('peut-être été traitée'));
    });

    test('code d’erreur de type inattendu ignoré', () {
      final error = NexoraApi.errorFromResponse(409, {
        'detail': {'code': 42, 'message': null},
      });
      expect((error.kind, error.code), (ApiErrorKind.conflict, null));
    });

    test('réponse non JSON ou mauvais format', () async {
      final html = apiWith((_) async => http.Response('<html>', 200));
      expect((await failure(html.metrics())).kind, ApiErrorKind.badResponse);
      final list = apiWith((_) async => jsonResponse([1]));
      expect((await failure(list.metrics())).kind, ApiErrorKind.badResponse);
    });

    test('réseau : injoignable, TLS, coupure', () async {
      final socket = apiWith((_) => throw const SocketException('refusé'));
      final unreachable = await failure(socket.ready());
      expect(unreachable.kind, ApiErrorKind.unreachable);
      expect(unreachable.message, contains('Tailscale'));

      final tls = apiWith((_) => throw const HandshakeException('bad cert'));
      expect((await failure(tls.ready())).kind, ApiErrorKind.tls);

      final cut = apiWith(
        (_) =>
            throw http.ClientException('Connection closed before full header'),
      );
      final interrupted = await failure(cut.sendMessage('c1', 'x'));
      expect(interrupted.kind, ApiErrorKind.interrupted);
      expect(interrupted.outcomeUnknown, isTrue);
      expect(interrupted.message, contains('peut-être été traitée'));
    });

    test('délai de lecture court, issue incertaine pour une écriture', () {
      fakeAsync((async) {
        final api = apiWith((_) => Completer<http.Response>().future);
        ApiError? read;
        ApiError? write;
        api.ready().then<void>(
          (_) {},
          onError: (Object e) {
            read = e as ApiError;
          },
        );
        api
            .createConversation('x')
            .then<void>(
              (_) {},
              onError: (Object e) {
                write = e as ApiError;
              },
            );
        async.elapse(readTimeout + const Duration(seconds: 1));
        expect(read?.kind, ApiErrorKind.timeout);
        expect(read?.outcomeUnknown, isTrue);
        expect(write?.message, contains('peut-être été traitée'));
      });
    });

    test('un tour IA attend le délai long', () {
      fakeAsync((async) {
        final api = apiWith((_) => Completer<http.Response>().future);
        ApiError? error;
        api
            .sendMessage('c1', 'x')
            .then<void>(
              (_) {},
              onError: (Object e) {
                error = e as ApiError;
              },
            );
        async.elapse(readTimeout * 2);
        expect(error, isNull);
        async.elapse(turnTimeout);
        expect(error?.kind, ApiErrorKind.timeout);
      });
    });
  });
}

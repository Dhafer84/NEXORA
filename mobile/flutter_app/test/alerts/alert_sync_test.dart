import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexora/src/alerts/alert_sync.dart';
import 'package:nexora/src/api/api_error.dart';
import 'package:nexora/src/api/models.dart';
import 'package:nexora/src/storage/credentials_store.dart';

import '../support/fake_backend.dart';
import '../support/memory_vault.dart';

class MemoryCursors implements CursorStore {
  SyncCursor? cursor;
  int writes = 0;

  /// Makes the N-th write throw, as if the worker were stopped there.
  int? interruptAt;

  @override
  Future<SyncCursor?> read() async => cursor;

  @override
  Future<void> write(SyncCursor value) async {
    writes++;
    if (writes == interruptAt) throw const Interrupted();
    cursor = value;
  }
}

class Shown implements AlertPresenter {
  final List<int> ids = [];

  @override
  Future<void> show(ServerNotification notification) async =>
      ids.add(notification.id);
}

SecureCredentialsStore stored([String url = testBaseUrl]) =>
    SecureCredentialsStore(
      MemoryVault({
        SecureCredentialsStore.entryKey: jsonEncode({
          'base_url': url,
          'api_key': testApiKey,
        }),
      }),
    );

void main() {
  late FakeBackend backend;
  late MemoryCursors cursors;
  late Shown shown;

  AlertSync sync([CredentialsStore? credentials]) => AlertSync(
    credentials: credentials ?? stored(),
    cursors: cursors,
    presenter: shown,
    apiFactory: backend.factory,
  );

  setUp(() {
    backend = FakeBackend();
    cursors = MemoryCursors();
    shown = Shown();
  });

  test(
    'premier passage : part de maintenant, sans rejouer l’historique',
    () async {
      backend
        ..addNotification('ancienne 1')
        ..addNotification('ancienne 2');
      expect(await sync().run(), 0);
      expect(shown.ids, isEmpty);
      expect(cursors.cursor!.lastId, 2);
      backend.addNotification('nouvelle');
      expect(await sync().run(), 1);
      expect(shown.ids, [3]);
      expect(await sync().run(), 0, reason: 'déjà affichée');
    },
  );

  test('plusieurs pages, dans l’ordre', () async {
    await sync().prime();
    for (var i = 0; i < 45; i++) {
      backend.addNotification('alerte $i');
    }
    expect(await sync().run(), 45);
    expect(shown.ids, [for (var i = 1; i <= 45; i++) i]);
  });

  test(
    'interruption après affichage : même identifiant, pas de doublon',
    () async {
      await sync().prime(); // write 1
      backend
        ..addNotification('a')
        ..addNotification('b');
      cursors.interruptAt = 3; // after showing «a», while saving «b»
      await expectLater(sync().run(), throwsA(isA<Interrupted>()));
      expect(shown.ids, [1, 2]);
      expect(cursors.cursor!.lastId, 1);
      await sync().run();
      // «b» is shown again with id 2: Android replaces it instead of adding one.
      expect(shown.ids, [1, 2, 2]);
      expect(shown.ids.toSet(), {1, 2});
    },
  );

  test(
    'serveur injoignable : erreur, curseur inchangé, reprise ensuite',
    () async {
      await sync().prime();
      backend.addNotification('a');
      backend.override = (_) =>
          throw const ApiError(ApiErrorKind.unreachable, 'x');
      await expectLater(sync().run(), throwsA(isA<ApiError>()));
      expect(cursors.cursor!.lastId, 0);
      backend.override = null;
      expect(await sync().run(), 1);
    },
  );

  test(
    'autre serveur : le curseur est remis à zéro sans rien afficher',
    () async {
      backend.addNotification('a');
      cursors.cursor = const SyncCursor('https://ancien.test:8101', 99);
      expect(await sync().run(), 0);
      expect(cursors.cursor!.baseUrl, testBaseUrl);
      expect(cursors.cursor!.lastId, 1);
    },
  );

  test(
    'base du serveur réinitialisée : suit la nouvelle numérotation',
    () async {
      cursors.cursor = const SyncCursor(testBaseUrl, 50);
      backend.addNotification('a');
      expect(await sync().run(), 0);
      expect(cursors.cursor!.lastId, 1);
      backend.addNotification('b');
      expect(await sync().run(), 1);
    },
  );

  test('sans clé enregistrée : aucune requête', () async {
    final empty = SecureCredentialsStore(MemoryVault());
    expect(await sync(empty).run(), 0);
    expect(backend.requests, isEmpty);
  });
}

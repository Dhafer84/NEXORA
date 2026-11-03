import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nexora/src/state/app_state.dart';
import 'package:nexora/src/storage/credentials_store.dart';

import '../support/fake_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBackend backend;
  late AppState state;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    backend = FakeBackend();
    state = AppState(
      store: SecureCredentialsStore(),
      apiFactory: backend.factory,
    );
  });

  tearDown(() => state.dispose());

  test('non configuré sans clé', () async {
    await state.load();
    expect(state.setup, SetupState.unconfigured);
    expect(state.configured, isFalse);
  });

  group('testConnection', () {
    test('succès : sonde publique puis clé', () async {
      final report = await state.testConnection(testBaseUrl, testApiKey);
      expect(report.ok, isTrue);
      expect(backend.requests.map((r) => r.url.path), [
        '/health/live',
        '/api/v1/auth/check',
      ]);
      expect(await state.store.read(), isNull, reason: 'rien enregistré');
    });

    test('clé refusée', () async {
      final report = await state.testConnection(testBaseUrl, 'mauvaise');
      expect(report.ok, isFalse);
      expect(report.message, contains('clé personnelle est refusée'));
    });

    test('adresse en HTTP refusée sans requête', () async {
      final report = await state.testConnection(
        'http://serveur.test',
        testApiKey,
      );
      expect(report.ok, isFalse);
      expect(report.message, contains('HTTPS'));
      expect(backend.requests, isEmpty);
    });

    test('serveur injoignable : message Tailscale', () async {
      backend.override = (_) =>
          throw http.ClientException('Failed host lookup');
      final report = await state.testConnection(testBaseUrl, testApiKey);
      expect(report.ok, isFalse);
      expect(report.message, contains('Tailscale'));
    });
  });

  test('enregistrer, compter les validations, supprimer la clé', () async {
    backend
      ..addApproval()
      ..addApproval()
      ..addApproval(status: 'consumed');
    await state.save('$testBaseUrl/', testApiKey);
    expect(state.setup, SetupState.ready);
    expect(state.baseUrl, testBaseUrl);
    await state.refreshPending();
    expect(state.pendingApprovals, 2);

    // Garder la clé quand le champ reste vide.
    await state.save(testBaseUrl, null);
    expect(state.hasKey, isTrue);

    await state.deleteKey();
    expect(state.setup, SetupState.unconfigured);
    expect(state.pendingApprovals, isNull);
    expect(state.baseUrl, testBaseUrl);
  });

  group('clé liée à l’adresse', () {
    const other = 'https://autre.test:8101';

    test('nouvelle adresse sans clé : refus, rien n’est changé', () async {
      await state.save(testBaseUrl, testApiKey);
      backend.requests.clear();
      final problem = await state.save(other, '');
      expect(problem, AppState.newAddressNeedsKey);
      expect(state.baseUrl, testBaseUrl);
      expect(await state.storedKeyFor(other), isNull);
      await state.refreshPending();
      expect(
        backend.requests.map((r) => r.url.host).toSet(),
        {'nexora.test'},
        reason: 'aucune requête vers la nouvelle adresse',
      );
    });

    test('nouvelle adresse avec sa clé : la clé suit l’adresse', () async {
      await state.save(testBaseUrl, testApiKey);
      expect(await state.save(other, 'cle-de-l-autre'), isNull);
      expect(state.baseUrl, other);
      expect(await state.storedKeyFor(other), 'cle-de-l-autre');
      expect(await state.storedKeyFor(testBaseUrl), isNull);
    });

    test('même adresse (barre finale) : clé conservée', () async {
      await state.save(testBaseUrl, testApiKey);
      expect(await state.save('$testBaseUrl/', null), isNull);
      expect(await state.storedKeyFor(testBaseUrl), testApiKey);
    });
  });

  test('erreur de rafraîchissement conservée sans planter', () async {
    await state.save(testBaseUrl, testApiKey);
    backend.forbidden.add('/api/v1/approvals');
    await state.refreshPending();
    expect(state.pendingError, contains('Permission'));
  });
}

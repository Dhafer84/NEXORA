import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora/src/storage/credentials_store.dart';

import '../support/memory_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const first = 'https://serveur.test:8101';
  const other = 'https://autre.test:8101';

  late MemoryVault vault;
  late SecureCredentialsStore store;

  setUp(() {
    vault = MemoryVault();
    store = SecureCredentialsStore(vault);
  });

  Map<String, dynamic> entry() =>
      jsonDecode(vault.data[SecureCredentialsStore.entryKey]!)
          as Map<String, dynamic>;

  test('vide au premier lancement', () async {
    expect(await store.read(), isNull);
    expect(await store.hasApiKey(), isFalse);
    expect(await store.readBaseUrl(), isNull);
  });

  test(
    'adresse et clé dans une seule entrée, écrite en une opération',
    () async {
      await store.save(first, apiKey: 'cle');
      expect(vault.data.keys, [SecureCredentialsStore.entryKey]);
      expect(entry(), {'base_url': first, 'api_key': 'cle'});
      expect(vault.operations, 1 + SecureCredentialsStore.legacyKeys.length);
    },
  );

  test('enregistre, conserve, remplace puis supprime la clé', () async {
    await store.save(first);
    expect(await store.read(), isNull, reason: 'pas encore de clé');
    await store.save(first, apiKey: 'premiere');
    await store.save(first);
    expect((await store.read())?.apiKey, 'premiere', reason: 'même adresse');
    await store.save(first, apiKey: 'seconde');
    expect((await store.read())?.apiKey, 'seconde');
    await store.deleteApiKey();
    expect(await store.hasApiKey(), isFalse);
    expect(await store.readBaseUrl(), first);
  });

  test('nouvelle adresse sans clé : l’ancienne clé disparaît', () async {
    await store.save(first, apiKey: 'cle-du-premier');
    await store.save(other);
    expect(await store.read(), isNull);
    expect(entry(), {'base_url': other});
  });

  group('interruption pendant un changement de serveur', () {
    setUp(() async {
      await store.save(first, apiKey: 'cle-du-premier');
      vault.operations = 0;
    });

    test('avant l’écriture : ancienne paire intacte', () async {
      vault.interruptAt = 1;
      await expectLater(
        store.save(other, apiKey: 'cle-de-l-autre'),
        throwsA(isA<Interrupted>()),
      );
      // Restart: a new store over the same storage.
      final restarted = SecureCredentialsStore(vault);
      final credentials = await restarted.read();
      expect(credentials?.baseUrl, first);
      expect(credentials?.apiKey, 'cle-du-premier');
    });

    test('après l’écriture, pendant le nettoyage : nouvelle paire', () async {
      vault.interruptAt = 2;
      await store.save(other, apiKey: 'cle-de-l-autre');
      final credentials = await SecureCredentialsStore(vault).read();
      expect(credentials?.baseUrl, other);
      expect(credentials?.apiKey, 'cle-de-l-autre');
    });

    test(
      'nouvelle adresse sans clé, interrompue : jamais de mélange',
      () async {
        for (var step = 1; step <= 4; step++) {
          final copy = MemoryVault(vault.data)..interruptAt = step;
          try {
            await SecureCredentialsStore(copy).save(other);
          } on Interrupted {
            // Expected for every step that is reached.
          }
          final credentials = await SecureCredentialsStore(copy).read();
          final pair = (credentials?.baseUrl, credentials?.apiKey);
          expect(
            pair == (first, 'cle-du-premier') || credentials == null,
            isTrue,
            reason: 'étape $step : $pair',
          );
          if (credentials == null) {
            expect(await SecureCredentialsStore(copy).readBaseUrl(), other);
          }
        }
      },
    );
  });

  test(
    'anciennes entrées séparées : adresse reprise, clé abandonnée',
    () async {
      final legacy = MemoryVault({
        'nexora.base_url': first,
        'nexora.api_key': 'ancienne-cle',
        'nexora.api_key_url': first,
      });
      final migrated = SecureCredentialsStore(legacy);
      expect(await migrated.readBaseUrl(), first);
      expect(await migrated.read(), isNull);
      await migrated.save(first, apiKey: 'nouvelle');
      expect(legacy.data.keys, [SecureCredentialsStore.entryKey]);
    },
  );

  test('entrée illisible : traitée comme absente', () async {
    vault.data[SecureCredentialsStore.entryKey] = '{pas du json';
    expect(await store.read(), isNull);
    expect(await store.readBaseUrl(), isNull);
  });

  test('adaptateur FlutterSecureStorage', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final real = SecureCredentialsStore();
    await real.save(first, apiKey: 'cle');
    expect((await real.read())?.apiKey, 'cle');
    expect(await const FlutterSecureStorage().readAll(), {
      SecureCredentialsStore.entryKey: jsonEncode({
        'base_url': first,
        'api_key': 'cle',
      }),
    });
  });
}

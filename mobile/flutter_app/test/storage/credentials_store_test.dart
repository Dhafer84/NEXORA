import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora/src/storage/credentials_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const first = 'https://serveur.test:8101';
  const other = 'https://autre.test:8101';

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('vide au premier lancement', () async {
    final store = SecureCredentialsStore();
    expect(await store.read(), isNull);
    expect(await store.hasApiKey(), isFalse);
    expect(await store.readBaseUrl(), isNull);
  });

  test(
    'enregistre, remplace puis supprime la clé en gardant l’adresse',
    () async {
      final store = SecureCredentialsStore();
      await store.save(first);
      expect(await store.read(), isNull, reason: 'pas encore de clé');
      await store.save(first, apiKey: 'premiere');
      expect((await store.read())?.apiKey, 'premiere');
      await store.save(first);
      expect((await store.read())?.apiKey, 'premiere', reason: 'même adresse');
      await store.save(first, apiKey: 'seconde');
      expect((await store.read())?.apiKey, 'seconde');
      await store.deleteApiKey();
      expect(await store.hasApiKey(), isFalse);
      expect(await store.readBaseUrl(), first);
    },
  );

  test('nouvelle adresse sans clé : l’ancienne clé est effacée', () async {
    const storage = FlutterSecureStorage();
    final store = SecureCredentialsStore(storage);
    await store.save(first, apiKey: 'cle-du-premier');
    await store.save(other);
    expect(await store.read(), isNull);
    expect(await store.hasApiKey(), isFalse);
    expect(await storage.readAll(), {'nexora.base_url': other});
  });

  test('clé jamais rendue pour une autre adresse que la sienne', () async {
    FlutterSecureStorage.setMockInitialValues({
      'nexora.base_url': other,
      'nexora.api_key': 'cle-du-premier',
      'nexora.api_key_url': first,
    });
    final store = SecureCredentialsStore();
    expect(await store.read(), isNull);
    expect(await store.hasApiKey(), isFalse);
  });

  test('stocke la clé avec l’adresse à laquelle elle appartient', () async {
    const storage = FlutterSecureStorage();
    await SecureCredentialsStore(storage).save(first, apiKey: 'cle');
    expect(await storage.readAll(), {
      'nexora.base_url': first,
      'nexora.api_key': 'cle',
      'nexora.api_key_url': first,
    });
  });
}

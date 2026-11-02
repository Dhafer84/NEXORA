import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora/src/storage/credentials_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      await store.saveBaseUrl('https://serveur.test:8101');
      expect(await store.read(), isNull, reason: 'pas encore de clé');
      await store.saveApiKey('premiere');
      expect((await store.read())?.apiKey, 'premiere');
      await store.saveApiKey('seconde');
      expect((await store.read())?.apiKey, 'seconde');
      await store.deleteApiKey();
      expect(await store.hasApiKey(), isFalse);
      expect(await store.read(), isNull);
      expect(await store.readBaseUrl(), 'https://serveur.test:8101');
    },
  );

  test('stocke sous des noms dédiés', () async {
    const storage = FlutterSecureStorage();
    final store = SecureCredentialsStore(storage);
    await store.saveBaseUrl('https://serveur.test');
    await store.saveApiKey('cle');
    expect(await storage.readAll(), {
      'nexora.base_url': 'https://serveur.test',
      'nexora.api_key': 'cle',
    });
  });
}

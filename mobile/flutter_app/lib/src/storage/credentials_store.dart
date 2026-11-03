import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Credentials {
  const Credentials({required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;
}

/// Backend address and personal key. The key is bound to the address it was
/// entered for: it is never returned for, nor sent to, another address.
abstract class CredentialsStore {
  Future<String?> readBaseUrl();

  /// True when a key exists for the stored address.
  Future<bool> hasApiKey();

  /// Address and key, only when the key belongs to that address.
  Future<Credentials?> read();

  /// Saves the address. With [apiKey], binds that key to it; without, keeps the
  /// stored key only if the address is unchanged, and deletes it otherwise.
  Future<void> save(String baseUrl, {String? apiKey});
  Future<void> deleteApiKey();
}

/// Android Keystore-backed storage (flutter_secure_storage).
class SecureCredentialsStore implements CredentialsStore {
  SecureCredentialsStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _urlKey = 'nexora.base_url';
  static const _apiKeyKey = 'nexora.api_key';

  /// Address the key was entered for.
  static const _keyUrlKey = 'nexora.api_key_url';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readBaseUrl() => _storage.read(key: _urlKey);

  @override
  Future<bool> hasApiKey() async => await read() != null;

  @override
  Future<Credentials?> read() async {
    final url = await _storage.read(key: _urlKey);
    final key = await _storage.read(key: _apiKeyKey);
    final keyUrl = await _storage.read(key: _keyUrlKey);
    if (url == null || url.isEmpty || key == null || key.isEmpty) return null;
    if (keyUrl != url) return null;
    return Credentials(baseUrl: url, apiKey: key);
  }

  @override
  Future<void> save(String baseUrl, {String? apiKey}) async {
    if (apiKey != null && apiKey.isNotEmpty) {
      await _storage.write(key: _apiKeyKey, value: apiKey);
      await _storage.write(key: _keyUrlKey, value: baseUrl);
    } else if (await _storage.read(key: _keyUrlKey) != baseUrl) {
      await deleteApiKey();
    }
    await _storage.write(key: _urlKey, value: baseUrl);
  }

  @override
  Future<void> deleteApiKey() async {
    await _storage.delete(key: _apiKeyKey);
    await _storage.delete(key: _keyUrlKey);
  }
}

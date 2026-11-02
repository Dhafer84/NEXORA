import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Credentials {
  const Credentials({required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;
}

/// Backend address and personal key. Only the key is secret, but both are kept
/// together so the address is never written to plain preferences or backups.
abstract class CredentialsStore {
  Future<String?> readBaseUrl();
  Future<bool> hasApiKey();
  Future<Credentials?> read();
  Future<void> saveBaseUrl(String baseUrl);
  Future<void> saveApiKey(String apiKey);
  Future<void> deleteApiKey();
}

/// Android Keystore-backed storage (flutter_secure_storage).
class SecureCredentialsStore implements CredentialsStore {
  SecureCredentialsStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _urlKey = 'nexora.base_url';
  static const _apiKeyKey = 'nexora.api_key';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readBaseUrl() => _storage.read(key: _urlKey);

  @override
  Future<bool> hasApiKey() async =>
      (await _storage.read(key: _apiKeyKey))?.isNotEmpty ?? false;

  @override
  Future<Credentials?> read() async {
    final url = await _storage.read(key: _urlKey);
    final key = await _storage.read(key: _apiKeyKey);
    if (url == null || url.isEmpty || key == null || key.isEmpty) return null;
    return Credentials(baseUrl: url, apiKey: key);
  }

  @override
  Future<void> saveBaseUrl(String baseUrl) =>
      _storage.write(key: _urlKey, value: baseUrl);

  @override
  Future<void> saveApiKey(String apiKey) =>
      _storage.write(key: _apiKeyKey, value: apiKey);

  @override
  Future<void> deleteApiKey() => _storage.delete(key: _apiKeyKey);
}

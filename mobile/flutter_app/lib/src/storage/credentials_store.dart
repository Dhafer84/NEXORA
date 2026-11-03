import 'dart:convert';

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
  /// stored key only if the address is unchanged, and drops it otherwise.
  Future<void> save(String baseUrl, {String? apiKey});
  Future<void> deleteApiKey();
}

/// Minimal secure key-value access, so tests can simulate an interrupted write.
abstract class SecureVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureVault implements SecureVault {
  const FlutterSecureVault([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Android Keystore-backed storage. Address and key live in ONE entry, written
/// in a single operation: an interruption leaves either the old pair or the new
/// one, never a key paired with another address.
class SecureCredentialsStore implements CredentialsStore {
  SecureCredentialsStore([SecureVault? vault])
    : _vault = vault ?? const FlutterSecureVault();

  static const entryKey = 'nexora.credentials';

  /// Separate entries written by versions 0.3.0 and 0.3.1. Only the address is
  /// carried over; their key is never used again and they are deleted.
  static const legacyKeys = [
    'nexora.base_url',
    'nexora.api_key',
    'nexora.api_key_url',
  ];

  final SecureVault _vault;

  Future<({String? baseUrl, String? apiKey})> _load() async {
    final raw = await _vault.read(entryKey);
    if (raw == null) {
      return (baseUrl: await _vault.read(legacyKeys.first), apiKey: null);
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final url = json['base_url'];
      final key = json['api_key'];
      return (
        baseUrl: url is String && url.isNotEmpty ? url : null,
        apiKey: url is String && key is String && key.isNotEmpty ? key : null,
      );
    } on Object {
      // Unreadable entry: start again from the settings screen.
      return (baseUrl: null, apiKey: null);
    }
  }

  Future<void> _write(String baseUrl, String? apiKey) async {
    await _vault.write(
      entryKey,
      jsonEncode({'base_url': baseUrl, 'api_key': ?apiKey}),
    );
    // Best effort: old entries are never read once the single entry exists, so
    // a failure here must not report the save itself as failed.
    for (final legacy in legacyKeys) {
      try {
        await _vault.delete(legacy);
      } on Object {
        // Retried at the next save.
      }
    }
  }

  @override
  Future<String?> readBaseUrl() async => (await _load()).baseUrl;

  @override
  Future<bool> hasApiKey() async => await read() != null;

  @override
  Future<Credentials?> read() async {
    final stored = await _load();
    final url = stored.baseUrl;
    final key = stored.apiKey;
    if (url == null || key == null) return null;
    return Credentials(baseUrl: url, apiKey: key);
  }

  @override
  Future<void> save(String baseUrl, {String? apiKey}) async {
    final current = await _load();
    final key = apiKey != null && apiKey.isNotEmpty
        ? apiKey
        : (current.baseUrl == baseUrl ? current.apiKey : null);
    await _write(baseUrl, key);
  }

  @override
  Future<void> deleteApiKey() async {
    final url = (await _load()).baseUrl;
    if (url == null) {
      await _vault.delete(entryKey);
    } else {
      await _write(url, null);
    }
  }
}

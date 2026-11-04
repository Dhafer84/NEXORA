import 'dart:convert';

import '../health/health_service.dart';
import '../storage/credentials_store.dart';

/// What NEXORA keeps of Health Connect on the phone: the last successful
/// read of each category, encrypted by the Android Keystore (secure storage),
/// excluded from backups (`allowBackup=false`) and never logged. Erasing it
/// leaves Health Connect untouched.
abstract class ActivityStore {
  Future<Map<String, Object?>?> read(HealthCategory category);
  Future<void> write(HealthCategory category, Map<String, Object?> raw);
  Future<void> delete(HealthCategory category);

  Future<void> clear() async {
    for (final category in HealthCategory.values) {
      await delete(category);
    }
  }
}

class VaultActivityStore extends ActivityStore {
  VaultActivityStore([SecureVault? vault])
    : _vault = vault ?? const FlutterSecureVault();

  final SecureVault _vault;

  static String keyOf(HealthCategory category) =>
      'nexora.activity.${category.wire}';

  @override
  Future<Map<String, Object?>?> read(HealthCategory category) async {
    final text = await _vault.read(keyOf(category));
    if (text == null) return null;
    try {
      return jsonDecode(text) as Map<String, Object?>;
    } on FormatException {
      // Unreadable copy: forget it, the next refresh rebuilds it.
      await _vault.delete(keyOf(category));
      return null;
    }
  }

  @override
  Future<void> write(HealthCategory category, Map<String, Object?> raw) =>
      _vault.write(keyOf(category), jsonEncode(raw));

  @override
  Future<void> delete(HealthCategory category) =>
      _vault.delete(keyOf(category));
}

class MemoryActivityStore extends ActivityStore {
  final Map<HealthCategory, Map<String, Object?>> data = {};

  @override
  Future<Map<String, Object?>?> read(HealthCategory category) async =>
      data[category];

  @override
  Future<void> write(HealthCategory category, Map<String, Object?> raw) async =>
      data[category] = raw;

  @override
  Future<void> delete(HealthCategory category) async => data.remove(category);
}

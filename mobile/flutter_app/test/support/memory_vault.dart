import 'package:nexora/src/storage/credentials_store.dart';

/// Thrown by [MemoryVault] to imitate the app being stopped mid-operation.
class Interrupted implements Exception {
  const Interrupted();
}

/// In-memory secure storage. [interruptAt] makes the N-th write or delete
/// (counting from 1, both together) throw before changing anything.
class MemoryVault implements SecureVault {
  MemoryVault([Map<String, String>? initial]) : data = {...?initial};

  final Map<String, String> data;
  int? interruptAt;
  int operations = 0;

  void _step() {
    operations++;
    if (operations == interruptAt) throw const Interrupted();
  }

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    _step();
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _step();
    data.remove(key);
  }
}

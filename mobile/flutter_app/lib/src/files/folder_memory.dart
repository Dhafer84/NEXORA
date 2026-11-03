import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'file_access.dart';

class PreferencesFolderMemory implements FolderMemory {
  PreferencesFolderMemory([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const _key = 'nexora.files.folder';
  final SharedPreferencesAsync _preferences;

  @override
  Future<PickedFolder?> read() async {
    final raw = await _preferences.getString(_key);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return PickedFolder(
        tree: json['tree'] as String,
        name: json['name'] as String,
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(PickedFolder? folder) => folder == null
      ? _preferences.remove(_key)
      : _preferences.setString(
          _key,
          jsonEncode({'tree': folder.tree, 'name': folder.name}),
        );
}

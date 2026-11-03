import 'package:nexora/src/files/file_access.dart';

/// In-memory picked folder: records every operation, never touches a disk.
class FakeFiles implements FileAccess {
  FakeFiles(List<String> names) {
    for (final name in names) {
      _add(name, root);
    }
  }

  static const root = 'root';
  static const tree = 'content://test/tree/Download';
  final Map<String, ({String name, String parent, String mime})> docs = {};
  final List<String> operations = [];
  PickedFolder? pickResult = const PickedFolder(tree: tree, name: 'Download');
  String? failNextWith;
  int _ids = 0;

  String _add(
    String name,
    String parent, {
    String mime = 'application/octet-stream',
  }) {
    final id = 'doc${++_ids}';
    docs[id] = (name: name, parent: parent, mime: mime);
    return id;
  }

  List<String> namesIn(String parent) => [
    for (final doc in docs.values)
      if (doc.parent == parent) doc.name,
  ]..sort();

  String? folderId(String name) => docs.entries
      .where((e) => e.value.name == name && e.value.mime == folderMime)
      .map((e) => e.key)
      .firstOrNull;

  void _maybeFail() {
    final code = failNextWith;
    if (code != null) {
      failNextWith = null;
      throw FileOperationError(
        code,
        'Échec simulé ($code) : rien n’a été modifié.',
      );
    }
  }

  @override
  Future<PickedFolder?> pickFolder() async => pickResult;

  @override
  Future<List<DeviceFile>> listFiles(String tree) async => [
    for (final entry in docs.entries)
      if (entry.value.parent == root)
        DeviceFile(
          id: entry.key,
          name: entry.value.name,
          mime: entry.value.mime,
        ),
  ];

  @override
  Future<String> ensureFolder(String tree, String name) async {
    final existing = folderId(name);
    if (existing != null) return existing;
    operations.add('mkdir $name');
    return _add(name, root, mime: folderMime);
  }

  @override
  Future<void> move(String tree, String documentId, String targetId) async {
    _maybeFail();
    final doc = docs[documentId]!;
    if (namesIn(targetId).contains(doc.name)) {
      throw const FileOperationError(
        'name_taken',
        'Nom déjà pris : rien n’a été modifié.',
      );
    }
    operations.add('move ${doc.name} -> ${docs[targetId]!.name}');
    docs[documentId] = (name: doc.name, parent: targetId, mime: doc.mime);
  }

  @override
  Future<void> rename(String tree, String documentId, String name) async {
    _maybeFail();
    final doc = docs[documentId]!;
    operations.add('rename ${doc.name} -> $name');
    docs[documentId] = (name: name, parent: doc.parent, mime: doc.mime);
  }

  @override
  Future<void> release(String tree) async => operations.add('release');
}

class MemoryFolder implements FolderMemory {
  PickedFolder? folder;

  @override
  Future<PickedFolder?> read() async => folder;

  @override
  Future<void> write(PickedFolder? value) async => folder = value;
}

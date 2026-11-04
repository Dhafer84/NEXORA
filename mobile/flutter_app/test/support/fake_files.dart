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

  /// Answer of [checkAccess] for the remembered folder.
  String access = 'ok';

  /// Documents returned by [pickFiles]; null stands for a cancelled picker.
  List<DeviceFile>? pickedFiles;

  /// Picked documents the storage refuses to move (other provider).
  final Set<String> unmovable = {};

  /// Names already taken where picked documents are renamed.
  final Set<String> takenNames = {};

  /// Exports saved or shared: name and exact content.
  final List<({String action, String name, String content})> exports = [];
  String? saveAnswer = 'nexora-export.csv';
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

  @override
  Future<String> checkAccess(String tree) async {
    operations.add('check');
    return access;
  }

  @override
  Future<List<DeviceFile>?> pickFiles(String? tree) async {
    operations.add('pickFiles');
    return pickedFiles;
  }

  @override
  Future<void> moveFile(String uri, String tree, String targetId) async {
    _maybeFail();
    final file = pickedFiles!.firstWhere((f) => f.id == uri);
    if (unmovable.contains(uri)) {
      throw const FileOperationError('move_unsupported', moveUnsupported);
    }
    if (namesIn(targetId).contains(file.name)) {
      throw const FileOperationError(
        'name_taken',
        'Nom déjà pris : rien n’a été modifié.',
      );
    }
    operations.add('moveFile ${file.name} -> ${docs[targetId]!.name}');
    _add(file.name, targetId);
  }

  @override
  Future<void> renameFile(String uri, String tree, String name) async {
    _maybeFail();
    if (takenNames.contains(name)) {
      throw const FileOperationError(
        'name_taken',
        'Un fichier du même nom existe déjà : rien n’a été modifié.',
      );
    }
    final file = pickedFiles!.firstWhere((f) => f.id == uri);
    operations.add('renameFile ${file.name} -> $name');
  }

  @override
  Future<String?> saveExport(String name, String mime, String content) async {
    exports.add((action: 'save', name: name, content: content));
    return saveAnswer;
  }

  @override
  Future<void> shareExport(String name, String mime, String content) async =>
      exports.add((action: 'share', name: name, content: content));

  @override
  Future<void> purgeExports() async => operations.add('purgeExports');
}

class MemoryFolder implements FolderMemory {
  PickedFolder? folder;

  @override
  Future<PickedFolder?> read() async => folder;

  @override
  Future<void> write(PickedFolder? value) async => folder = value;
}

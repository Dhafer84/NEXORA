import 'package:flutter/services.dart';

const folderMime = 'vnd.android.document/directory';

class DeviceFile {
  const DeviceFile({
    required this.id,
    required this.name,
    required this.mime,
    this.size,
    this.modified,
    this.canMove = true,
    this.canRename = true,
  });

  factory DeviceFile.fromMap(Map<Object?, Object?> map) => DeviceFile(
    id: map['id']! as String,
    name: map['name']! as String,
    mime: (map['mime'] as String?) ?? 'application/octet-stream',
    size: map['size'] as int?,
    modified: map['modified'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(map['modified']! as int),
    canMove: map['canMove'] as bool? ?? false,
    canRename: map['canRename'] as bool? ?? false,
  );

  final String id;
  final String name;
  final String mime;
  final int? size;
  final DateTime? modified;
  final bool canMove;
  final bool canRename;

  bool get isFolder => mime == folderMime;
}

/// The one folder the user granted through Android's picker.
class PickedFolder {
  const PickedFolder({required this.tree, required this.name});

  final String tree;
  final String name;
}

class FileOperationError implements Exception {
  const FileOperationError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Android Storage Access Framework, limited to the picked folder. No delete,
/// no copy, no overwrite: only listing, creating a sub-folder, moving into it
/// and renaming.
abstract class FileAccess {
  Future<PickedFolder?> pickFolder();
  Future<List<DeviceFile>> listFiles(String tree);

  /// Returns the document id of the existing or created sub-folder.
  Future<String> ensureFolder(String tree, String name);
  Future<void> move(String tree, String documentId, String targetId);
  Future<void> rename(String tree, String documentId, String name);
  Future<void> release(String tree);
}

class ChannelFileAccess implements FileAccess {
  const ChannelFileAccess();

  static const _channel = MethodChannel('app.nexora/files');

  Future<T> _call<T>(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments) as T;
    } on PlatformException catch (error) {
      throw FileOperationError(error.code, switch (error.code) {
        'name_taken' =>
          'Un fichier du même nom existe déjà : rien n’a été modifié.',
        'move_unsupported' =>
          'Ce stockage ne permet pas le déplacement : rien n’a été modifié.',
        'rename_unsupported' =>
          'Ce stockage ne permet pas le renommage : rien n’a été modifié.',
        'access_denied' =>
          'L’accès au dossier a été retiré. Choisissez-le de nouveau.',
        'invalid_name' => 'Nom refusé : pas de « / », ni de point au début.',
        'not_found' => 'Fichier introuvable : il a peut-être été déplacé.',
        _ => 'Opération impossible (${error.message ?? error.code}).',
      });
    }
  }

  @override
  Future<PickedFolder?> pickFolder() async {
    final result = await _call<Map<Object?, Object?>?>('pickFolder');
    if (result == null) return null;
    return PickedFolder(
      tree: result['tree']! as String,
      name: result['name']! as String,
    );
  }

  @override
  Future<List<DeviceFile>> listFiles(String tree) async {
    final items = await _call<List<Object?>>('listFiles', {'tree': tree});
    return [
      for (final item in items)
        DeviceFile.fromMap(item! as Map<Object?, Object?>),
    ];
  }

  @override
  Future<String> ensureFolder(String tree, String name) =>
      _call<String>('ensureFolder', {'tree': tree, 'name': name});

  @override
  Future<void> move(String tree, String documentId, String targetId) =>
      _call<String>('move', {
        'tree': tree,
        'documentId': documentId,
        'targetId': targetId,
      });

  @override
  Future<void> rename(String tree, String documentId, String name) =>
      _call<String>('rename', {
        'tree': tree,
        'documentId': documentId,
        'name': name,
      });

  @override
  Future<void> release(String tree) => _call<void>('release', {'tree': tree});
}

/// Remembers the picked folder between launches (not a secret).
abstract class FolderMemory {
  Future<PickedFolder?> read();
  Future<void> write(PickedFolder? folder);
}

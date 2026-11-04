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
    this.authority,
    this.inFolder = false,
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

  /// A document picked on its own: [id] is its content URI.
  factory DeviceFile.picked(Map<Object?, Object?> map) {
    final file = DeviceFile.fromMap({...map, 'id': map['uri']});
    return DeviceFile(
      id: file.id,
      name: file.name,
      mime: file.mime,
      size: file.size,
      modified: file.modified,
      canMove: file.canMove,
      canRename: file.canRename,
      authority: map['authority'] as String?,
      inFolder: map['inFolder'] as bool? ?? false,
    );
  }

  final String id;
  final String name;
  final String mime;
  final int? size;
  final DateTime? modified;
  final bool canMove;
  final bool canRename;

  /// Storage that provides a picked document (Téléchargements, stockage…).
  final String? authority;

  /// A picked document inside the authorised folder: only there can NEXORA
  /// check the neighbouring names before a move or a rename.
  final bool inFolder;

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

/// Android Storage Access Framework, limited to the picked folder and to the
/// files picked one by one. No delete, no copy, no overwrite: only listing,
/// creating a sub-folder, moving into it and renaming. A move the storage
/// refuses is reported, never replaced by a copy and a deletion.
abstract class FileAccess {
  /// Null when the user cancelled, e.g. after Android refused the root of
  /// Download (« Impossible d’utiliser ce dossier »).
  Future<PickedFolder?> pickFolder();

  /// `ok`, or `revoked` when the folder's access was withdrawn.
  Future<String> checkAccess(String tree);

  /// Documents picked one by one (the Download root included); null if
  /// cancelled. Each says whether it lies inside the authorised [tree].
  Future<List<DeviceFile>?> pickFiles(String? tree);

  /// Moves a picked document of [tree] into its sub-folder [targetId].
  Future<void> moveFile(String uri, String tree, String targetId);
  Future<void> renameFile(String uri, String tree, String name);

  /// Activité export: saved where the user chooses (null if cancelled).
  Future<String?> saveExport(String name, String mime, String content);

  /// Shared through Android's sheet, from a temporary file.
  Future<void> shareExport(String name, String mime, String content);
  Future<void> purgeExports();

  Future<List<DeviceFile>> listFiles(String tree);

  /// Returns the document id of the existing or created sub-folder.
  Future<String> ensureFolder(String tree, String name);
  Future<void> move(String tree, String documentId, String targetId);
  Future<void> rename(String tree, String documentId, String name);
  Future<void> release(String tree);
}

const moveUnsupported =
    'Android ne permet pas à NEXORA de déplacer ce fichier depuis cet emplacement : '
    'rien n’a été modifié. Utilisez l’application Fichiers du téléphone (appui '
    'long sur le fichier, puis Déplacer).';

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
        'move_unsupported' => moveUnsupported,
        'rename_unsupported' =>
          'Ce stockage ne permet pas à NEXORA de renommer ce fichier : rien n’a '
              'été modifié. L’application Fichiers du téléphone peut le faire.',
        'not_persistable' || 'no_write' =>
          'Ce dossier n’accorde pas d’accès durable en écriture. Choisissez un '
              'autre dossier, par exemple un sous-dossier de Téléchargements.',
        'busy' => 'Une sélection est déjà ouverte.',
        'write_failed' => 'Écriture impossible à cet emplacement.',
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
  Future<String> checkAccess(String tree) =>
      _call<String>('checkAccess', {'tree': tree});

  @override
  Future<List<DeviceFile>?> pickFiles(String? tree) async {
    final items = await _call<List<Object?>?>('pickFiles', {'tree': tree});
    return items == null
        ? null
        : [
            for (final item in items)
              DeviceFile.picked(item! as Map<Object?, Object?>),
          ];
  }

  @override
  Future<void> moveFile(String uri, String tree, String targetId) =>
      _call<String>('moveFile', {
        'uri': uri,
        'tree': tree,
        'targetId': targetId,
      });

  @override
  Future<void> renameFile(String uri, String tree, String name) =>
      _call<String>('renameFile', {'uri': uri, 'tree': tree, 'name': name});

  @override
  Future<String?> saveExport(String name, String mime, String content) =>
      _call<String?>('saveExport', {
        'name': name,
        'mime': mime,
        'content': content,
      });

  @override
  Future<void> shareExport(String name, String mime, String content) =>
      _call<bool>('shareExport', {
        'name': name,
        'mime': mime,
        'content': content,
      });

  @override
  Future<void> purgeExports() => _call<int>('purgeExports');

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

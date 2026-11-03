import 'file_access.dart';

enum ChangeKind { move, rename }

/// One proposed change. Nothing happens until the user validates it.
class ProposedChange {
  const ProposedChange.move(this.file, this.folder, this.reason)
    : kind = ChangeKind.move,
      newName = null;

  const ProposedChange.rename(this.file, this.newName, this.reason)
    : kind = ChangeKind.rename,
      folder = null;

  final DeviceFile file;
  final ChangeKind kind;

  /// Sub-folder of the picked folder, for a move.
  final String? folder;

  /// New name, for a rename.
  final String? newName;
  final String reason;

  String get key => '${kind.name}:${file.id}';
}

const categories = <String, Set<String>>{
  'Documents': {'pdf', 'doc', 'docx', 'odt', 'rtf', 'txt', 'md'},
  'Tableurs': {'xls', 'xlsx', 'ods', 'csv'},
  'Présentations': {'ppt', 'pptx', 'odp', 'key'},
  'Images': {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp'},
  'Vidéos': {'mp4', 'mov', 'mkv', 'avi', 'webm', '3gp'},
  'Audio': {'mp3', 'm4a', 'aac', 'wav', 'ogg', 'flac', 'opus'},
  'Archives': {'zip', 'rar', '7z', 'tar', 'gz'},
  'Applications': {'apk', 'apks', 'xapk'},
};

String? extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

String? categoryOf(String name) {
  final extension = extensionOf(name);
  for (final entry in categories.entries) {
    if (entry.value.contains(extension)) return entry.key;
  }
  return null;
}

final _cameraName = RegExp(
  r'^(IMG|VID|PXL|Screenshot|Capture d.écran)[_ -]?(\d{4})(\d{2})(\d{2})[_ -](\d{2})(\d{2})(\d{2})',
  caseSensitive: false,
);

/// Readable name for camera and screenshot files, e.g.
/// `IMG_20261103_101010.jpg` → `Photo 2026-11-03 10-10-10.jpg`.
String? readableName(String name) {
  final match = _cameraName.firstMatch(name);
  final extension = extensionOf(name);
  if (match == null || extension == null) return null;
  final prefix = switch (match[1]!.toUpperCase()) {
    'VID' => 'Vidéo',
    'SCREENSHOT' => 'Capture',
    _ when match[1]!.toLowerCase().startsWith('capture') => 'Capture',
    _ => 'Photo',
  };
  return '$prefix ${match[2]}-${match[3]}-${match[4]} '
      '${match[5]}-${match[6]}-${match[7]}.$extension';
}

/// Proposals for the files directly in the picked folder. Deterministic and
/// local: no AI, no server. Sub-folders and hidden files are left alone. A file
/// gets one proposal at a time; after a validated change the list is computed
/// again from the folder's new content.
List<ProposedChange> proposeChanges(List<DeviceFile> items) {
  final names = {for (final item in items) item.name};
  final changes = <ProposedChange>[];
  for (final file in items) {
    if (file.isFolder || file.name.startsWith('.')) continue;
    final renamed = readableName(file.name);
    if (renamed != null && file.canRename && !names.contains(renamed)) {
      changes.add(
        ProposedChange.rename(
          file,
          renamed,
          'Nom d’appareil photo rendu lisible',
        ),
      );
      continue;
    }
    final category = categoryOf(file.name);
    if (category != null && file.canMove) {
      changes.add(
        ProposedChange.move(
          file,
          category,
          'Fichier .${extensionOf(file.name)} classé dans « $category »',
        ),
      );
    }
  }
  return changes;
}

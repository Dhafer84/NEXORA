import 'package:flutter_test/flutter_test.dart';
import 'package:nexora/src/files/classifier.dart';
import 'package:nexora/src/files/file_access.dart';

DeviceFile file(String name, {bool folder = false, bool canMove = true}) =>
    DeviceFile(
      id: name,
      name: name,
      mime: folder ? folderMime : 'application/octet-stream',
      canMove: canMove,
    );

void main() {
  test('classement par type, dossiers et fichiers cachés laissés en place', () {
    final changes = proposeChanges([
      file('Facture.PDF'),
      file('budget.xlsx'),
      file('chanson.mp3'),
      file('nexora.apk'),
      file('Documents', folder: true),
      file('.nomedia'),
      file('notes'),
      file('inconnu.xyz'),
    ]);
    expect(
      {for (final c in changes) c.file.name: c.folder},
      {
        'Facture.PDF': 'Documents',
        'budget.xlsx': 'Tableurs',
        'chanson.mp3': 'Audio',
        'nexora.apk': 'Applications',
      },
    );
    expect(changes.every((c) => c.kind == ChangeKind.move), isTrue);
  });

  test('noms d’appareil photo rendus lisibles, avant tout déplacement', () {
    expect(
      readableName('IMG_20261103_101010.jpg'),
      'Photo 2026-11-03 10-10-10.jpg',
    );
    expect(
      readableName('VID_20261103_101010.mp4'),
      'Vidéo 2026-11-03 10-10-10.mp4',
    );
    expect(
      readableName('Screenshot_20261103-101010.png'),
      'Capture 2026-11-03 10-10-10.png',
    );
    expect(readableName('vacances.jpg'), isNull);
    final [change] = proposeChanges([file('IMG_20261103_101010.jpg')]);
    expect(change.kind, ChangeKind.rename);
    expect(change.newName, 'Photo 2026-11-03 10-10-10.jpg');
  });

  test(
    'aucun renommage vers un nom déjà présent ; stockage sans déplacement',
    () {
      final changes = proposeChanges([
        file('IMG_20261103_101010.jpg'),
        file('Photo 2026-11-03 10-10-10.jpg'),
        file('scan.pdf', canMove: false),
      ]);
      // The camera file is classified instead of renamed onto an existing name.
      expect(changes.map((c) => (c.kind, c.file.name, c.folder)), [
        (ChangeKind.move, 'IMG_20261103_101010.jpg', 'Images'),
        (ChangeKind.move, 'Photo 2026-11-03 10-10-10.jpg', 'Images'),
      ]);
    },
  );
}

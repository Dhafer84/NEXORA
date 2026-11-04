import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora/src/files/file_access.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';
import '../support/fake_files.dart';

Future<void> openFiles(WidgetTester tester) async {
  await tester.tap(find.text('Tâches'));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.text('Classer des fichiers du téléphone'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  // Past the bottom navigation bar.
  await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Classer des fichiers du téléphone'));
  await tester.pumpAndSettle();
}

Future<void> tapLast(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(text).last);
  await tester.pumpAndSettle();
}

/// « Organiser un dossier »: the explanation comes before Android's picker.
Future<void> pickFolder(WidgetTester tester, FakeFiles files) async {
  await tapLast(tester, 'Organiser un dossier');
  expect(find.textContaining('Download/NEXORA'), findsWidgets);
  expect(
    files.operations,
    isNot(contains('pick')),
    reason: 'pas de sélecteur avant l’explication',
  );
  await tapLast(tester, 'Ouvrir le sélecteur');
}

void main() {
  testApp('choisir un dossier, voir les propositions, rien sans validation', (
    tester,
  ) async {
    final files = FakeFiles([
      'Facture.pdf',
      'IMG_20261103_101010.jpg',
      'Documents',
    ]);
    files.docs['doc3'] = (
      name: 'Documents',
      parent: FakeFiles.root,
      mime: folderMime,
    );
    final memory = MemoryFolder();
    await pumpApp(tester, FakeBackend(), files: files, folderMemory: memory);
    await openFiles(tester);
    expect(find.text('Ranger des fichiers'), findsOneWidget);
    await pickFolder(tester, files);
    expect(memory.folder?.name, 'Download');
    expect(find.text('Changements proposés dans Download (2)'), findsOneWidget);
    expect(
      find.text('Déplacer « Facture.pdf » vers Documents/'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Renommer « IMG_20261103_101010.jpg » en « Photo 2026-11-03 10-10-10.jpg »',
      ),
      findsOneWidget,
    );
    expect(
      files.operations,
      isEmpty,
      reason: 'aucune opération sans validation',
    );

    // Cancelled confirmation: nothing happens.
    await tapLast(tester, 'Valider…');
    await tapLast(tester, 'Annuler');
    expect(files.operations, isEmpty);
  });

  testApp('chaque opération validée une à une, puis rapportée', (tester) async {
    final files = FakeFiles(['Facture.pdf', 'IMG_20261103_101010.jpg']);
    await pumpApp(
      tester,
      FakeBackend(),
      files: files,
      folderMemory: MemoryFolder(),
    );
    await openFiles(tester);
    await pickFolder(tester, files);

    // First proposal: the PDF.
    await tester.tap(find.text('Valider…').first);
    await tester.pumpAndSettle();
    expect(find.text('Déplacer ce fichier ?'), findsOneWidget);
    expect(find.text('Destination : Download/Documents/'), findsOneWidget);
    await tapLast(tester, 'Déplacer');
    expect(files.operations, [
      'mkdir Documents',
      'move Facture.pdf -> Documents',
    ]);
    expect(find.text('« Facture.pdf » déplacé dans Documents'), findsOneWidget);
    expect(find.text('Changements proposés dans Download (1)'), findsOneWidget);

    // The rename proposal can be edited before validation.
    await tapLast(tester, 'Valider…');
    expect(find.text('Renommer ce fichier ?'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Nouveau nom'),
      'Anniversaire.jpg',
    );
    await tapLast(tester, 'Renommer');
    expect(
      files.operations.last,
      'rename IMG_20261103_101010.jpg -> Anniversaire.jpg',
    );
    // Renamed file is now proposed for classification, again awaiting validation.
    expect(
      find.text('Déplacer « Anniversaire.jpg » vers Images/'),
      findsOneWidget,
    );
    expect(files.operations, hasLength(3));
  });

  testApp('échec rapporté, rien de modifié ; ignorer et retirer l’accès', (
    tester,
  ) async {
    final files = FakeFiles(['Facture.pdf', 'chanson.mp3']);
    final memory = MemoryFolder();
    await pumpApp(tester, FakeBackend(), files: files, folderMemory: memory);
    await openFiles(tester);
    await pickFolder(tester, files);

    files.failNextWith = 'move_unsupported';
    await tester.tap(find.text('Valider…').first);
    await tester.pumpAndSettle();
    await tapLast(tester, 'Déplacer');
    expect(
      find.textContaining('Échec simulé (move_unsupported)'),
      findsOneWidget,
    );
    expect(files.namesIn(FakeFiles.root), contains('Facture.pdf'));

    await tester.tap(find.text('Ignorer').first);
    await tester.pumpAndSettle();
    expect(find.text('Changements proposés dans Download (1)'), findsOneWidget);

    await tester.tap(find.byTooltip('Options du dossier'));
    await tester.pumpAndSettle();
    await tapLast(tester, 'Retirer l’accès à ce dossier');
    expect(files.operations.last, 'release');
    expect(memory.folder, isNull);
    expect(find.text('Ranger des fichiers'), findsOneWidget);
  });

  testApp('sélection annulée : aucun accès', (tester) async {
    final files = FakeFiles(['Facture.pdf'])..pickResult = null;
    final memory = MemoryFolder();
    await pumpApp(tester, FakeBackend(), files: files, folderMemory: memory);
    await openFiles(tester);
    await pickFolder(tester, files);
    expect(memory.folder, isNull);
    expect(find.text('Ranger des fichiers'), findsOneWidget);
    // Android's « Impossible d’utiliser ce dossier » ends as a cancellation.
    expect(
      find.textContaining('Impossible d’utiliser ce dossier'),
      findsOneWidget,
    );
  });

  testApp('explication annulée : le sélecteur ne s’ouvre pas', (tester) async {
    final files = FakeFiles(['Facture.pdf']);
    final memory = MemoryFolder();
    await pumpApp(tester, FakeBackend(), files: files, folderMemory: memory);
    await openFiles(tester);
    await tapLast(tester, 'Organiser un dossier');
    await tapLast(tester, 'Annuler');
    expect(memory.folder, isNull);
    expect(files.operations, isEmpty);
  });

  testApp('accès retiré depuis : le dossier est oublié et expliqué', (
    tester,
  ) async {
    final files = FakeFiles(['Facture.pdf'])..access = 'revoked';
    final memory = MemoryFolder()
      ..folder = const PickedFolder(tree: FakeFiles.tree, name: 'NEXORA');
    await pumpApp(tester, FakeBackend(), files: files, folderMemory: memory);
    await openFiles(tester);
    expect(files.operations, ['check']);
    expect(memory.folder, isNull);
    expect(
      find.textContaining('L’accès au dossier « NEXORA » a été retiré'),
      findsOneWidget,
    );
  });

  testApp(
    'fichiers choisis : dans le dossier autorisé, déplacement et conflit',
    (tester) async {
      // Disposable names only, never real documents.
      final files = FakeFiles(['Rapport.pdf']);
      final memory = MemoryFolder()
        ..folder = const PickedFolder(tree: FakeFiles.tree, name: 'NEXORA');
      // Already in NEXORA/Documents: a picked file with the same name conflicts.
      final docsFolder = await files.ensureFolder(FakeFiles.tree, 'Documents');
      files.docs['doc99'] = (
        name: 'Rapport.pdf',
        parent: docsFolder,
        mime: 'application/pdf',
      );
      files.operations.clear();
      files.pickedFiles = const [
        DeviceFile(
          id: 'content://ext/NEXORA/a',
          name: 'essai-a.pdf',
          mime: 'application/pdf',
          inFolder: true,
        ),
        DeviceFile(
          id: 'content://ext/NEXORA/b',
          name: 'Rapport.pdf',
          mime: 'application/pdf',
          inFolder: true,
        ),
      ];
      await pumpApp(tester, FakeBackend(), files: files, folderMemory: memory);
      await openFiles(tester);
      await tapLast(
        tester,
        'Choisir des fichiers (racine de Téléchargements comprise)',
      );
      expect(find.text('Fichiers choisis (2)'), findsOneWidget);
      expect(files.operations.where((o) => o.startsWith('moveFile')), isEmpty);

      // Each move waits for its own confirmation.
      await tester.tap(find.text('Valider…').first);
      await tester.pumpAndSettle();
      expect(find.text('Destination : NEXORA/Documents/'), findsOneWidget);
      await tapLast(tester, 'Déplacer');
      expect(files.operations.last, 'moveFile essai-a.pdf -> Documents');
      expect(find.text('Fichiers choisis (1)'), findsOneWidget);

      // Name already taken at the destination: refused, nothing changed.
      final before = files.operations.length;
      await tester.tap(find.text('Valider…').first);
      await tester.pumpAndSettle();
      await tapLast(tester, 'Déplacer');
      expect(find.textContaining('Nom déjà pris'), findsOneWidget);
      expect(
        files.operations.length,
        before,
        reason: 'aucune copie ni suppression',
      );
      expect(files.namesIn(docsFolder), ['Rapport.pdf', 'essai-a.pdf']);
    },
  );

  testApp('fichiers hors du dossier : proposition et renvoi vers Fichiers', (
    tester,
  ) async {
    final files = FakeFiles([]);
    await pumpApp(
      tester,
      FakeBackend(),
      files: files,
      folderMemory: MemoryFolder(),
    );
    await openFiles(tester);
    await tapLast(tester, 'Choisir des fichiers');
    expect(find.text('Ranger des fichiers'), findsOneWidget, reason: 'annulé');

    files.pickedFiles = const [
      DeviceFile(
        id: 'content://dl/9',
        name: 'IMG_20261103_101010.jpg',
        mime: 'image/jpeg',
      ),
      DeviceFile(
        id: 'content://dl/8',
        name: 'essai.pdf',
        mime: 'application/pdf',
      ),
    ];
    await tapLast(tester, 'Choisir des fichiers');
    expect(find.text('Aucun dossier de destination'), findsOneWidget);
    expect(
      find.text(
        'Renommer « IMG_20261103_101010.jpg » en « Photo 2026-11-03 10-10-10.jpg »',
      ),
      findsOneWidget,
    );
    // No silent « (1) »: NEXORA cannot check the names there, so it does not act.
    expect(find.text('Valider…'), findsNothing);
    expect(
      find.textContaining('application Fichiers du téléphone'),
      findsWidgets,
    );
    expect(files.operations.where((o) => o.contains('File ')), isEmpty);
  });
}

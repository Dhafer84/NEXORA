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
    expect(find.text('Choisissez un dossier'), findsOneWidget);
    await tapLast(tester, 'Choisir un dossier');
    expect(memory.folder?.name, 'Download');
    expect(find.text('Changements proposés (2)'), findsOneWidget);
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
    await tapLast(tester, 'Choisir un dossier');

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
    expect(find.text('Changements proposés (1)'), findsOneWidget);

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
    await tapLast(tester, 'Choisir un dossier');

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
    expect(find.text('Changements proposés (1)'), findsOneWidget);

    await tester.tap(find.byTooltip('Options du dossier'));
    await tester.pumpAndSettle();
    await tapLast(tester, 'Retirer l’accès à ce dossier');
    expect(files.operations.last, 'release');
    expect(memory.folder, isNull);
    expect(find.text('Choisissez un dossier'), findsOneWidget);
  });

  testApp('sélection annulée : aucun accès', (tester) async {
    final files = FakeFiles(['Facture.pdf'])..pickResult = null;
    final memory = MemoryFolder();
    await pumpApp(tester, FakeBackend(), files: files, folderMemory: memory);
    await openFiles(tester);
    await tapLast(tester, 'Choisir un dossier');
    expect(memory.folder, isNull);
    expect(find.text('Choisissez un dossier'), findsOneWidget);
  });
}

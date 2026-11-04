import 'package:flutter/material.dart';

import '../../files/classifier.dart';
import '../../files/file_access.dart';
import '../../state/app_state.dart';
import '../format.dart';
import '../widgets/states.dart';

/// Why a file picked outside the authorised folder only gets a proposal.
const outsideFolder =
    'Hors du dossier autorisé : Android ne laisse pas NEXORA vérifier les noms '
    'voisins, donc ni déplacement ni renommage ici (le téléphone ajouterait '
    'sinon « (1) » sans prévenir). Utilisez l’application Fichiers du téléphone '
    '(appui long sur le fichier, puis Déplacer ou Renommer).';

/// Result of a validated change, kept for this session.
class _Outcome {
  const _Outcome(this.ok, this.text, this.at);

  final bool ok;
  final String text;
  final DateTime at;
}

/// Two ways in. « Organiser un dossier »: a folder granted through Android's
/// tree picker (the root of Download is refused by Android 11+, so a
/// sub-folder such as Download/NEXORA). « Choisir des fichiers »: documents
/// picked one by one, the Download root included, moved into the organised
/// folder when the storage allows it. Each change is applied only after its
/// own explicit validation; nothing is ever deleted, copied or overwritten.
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  PickedFolder? _folder;
  List<DeviceFile>? _items;
  final Set<String> _ignored = {};

  /// Documents picked one by one, for this session only.
  List<DeviceFile> _picked = const [];
  final List<_Outcome> _journal = [];
  String? _problem;
  bool _busy = false;
  bool _loaded = false;

  FileAccess get _access => AppScope.read(context).files!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  Future<void> _restore() async {
    final folder = await AppScope.read(context).folderMemory?.read();
    if (!mounted) return;
    setState(() {
      _folder = folder;
      _loaded = true;
    });
    if (folder == null) return;
    // The access may have been withdrawn since (Android settings, provider).
    String access;
    try {
      access = await _access.checkAccess(folder.tree);
    } on FileOperationError {
      access = 'revoked';
    }
    if (!mounted) return;
    if (access != 'ok') {
      await AppScope.read(context).folderMemory?.write(null);
      setState(() {
        _folder = null;
        _problem =
            'L’accès au dossier « ${folder.name} » a été retiré. Choisissez-le de '
            'nouveau, ou un autre dossier.';
      });
      return;
    }
    await _list();
  }

  Future<void> _list() async {
    final folder = _folder;
    if (folder == null) return;
    setState(() => _busy = true);
    try {
      final items = await _access.listFiles(folder.tree);
      if (!mounted) return;
      setState(() {
        _items = items;
        _problem = null;
      });
    } on FileOperationError catch (error) {
      if (mounted) setState(() => _problem = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Explains the Download root refusal before opening Android's picker.
  Future<void> _pick() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choisir le dossier à organiser'),
        content: const Text(
          'Android refuse la racine de Téléchargements (« Impossible d’utiliser ce '
          'dossier »). Dans le sélecteur, ouvrez Download puis choisissez ou créez '
          'un sous-dossier, par exemple Download/NEXORA, et appuyez sur « Utiliser '
          'ce dossier ».\n\nPour ranger des fichiers qui sont à la racine de '
          'Téléchargements, utilisez plutôt « Choisir des fichiers ».',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Ouvrir le sélecteur'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _problem = null);
    try {
      final folder = await _access.pickFolder();
      if (!mounted) return;
      if (folder == null) {
        setState(
          () => _problem =
              'Aucun dossier choisi. Si Android affiche « Impossible d’utiliser ce '
              'dossier », créez ou choisissez un sous-dossier (par exemple '
              'Download/NEXORA).',
        );
        return;
      }
      await AppScope.read(context).folderMemory?.write(folder);
      setState(() {
        _folder = folder;
        _items = null;
        _ignored.clear();
      });
      await _list();
    } on FileOperationError catch (error) {
      if (mounted) setState(() => _problem = error.message);
    }
  }

  Future<void> _pickFiles() async {
    setState(() => _problem = null);
    try {
      final files = await _access.pickFiles(_folder?.tree);
      if (files == null || !mounted) return;
      setState(() => _picked = files);
    } on FileOperationError catch (error) {
      if (mounted) setState(() => _problem = error.message);
    }
  }

  /// A change on a document picked on its own.
  Future<void> _validatePicked(ProposedChange change) async {
    final folder = _folder;
    if (folder == null || !change.file.inFolder) return;
    final answer = await showDialog<String>(
      context: context,
      builder: (_) => _ConfirmChange(change: change, folder: folder),
    );
    if (answer == null || !mounted) return;
    setState(() => _busy = true);
    _Outcome outcome;
    try {
      if (change.kind == ChangeKind.move) {
        final target = await _access.ensureFolder(folder.tree, change.folder!);
        await _access.moveFile(change.file.id, folder.tree, target);
        outcome = _Outcome(
          true,
          '« ${change.file.name} » déplacé dans ${folder.name}/${change.folder}',
          DateTime.now(),
        );
      } else {
        await _access.renameFile(change.file.id, folder.tree, answer);
        outcome = _Outcome(
          true,
          '« ${change.file.name} » renommé en « $answer »',
          DateTime.now(),
        );
      }
      // Its address changed: it leaves the selection.
      _picked = [
        for (final f in _picked)
          if (f.id != change.file.id) f,
      ];
    } on FileOperationError catch (error) {
      outcome = _Outcome(
        false,
        '« ${change.file.name} » : ${error.message}',
        DateTime.now(),
      );
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _journal.insert(0, outcome);
    });
    await _list();
  }

  Future<void> _forget() async {
    final folder = _folder;
    if (folder == null) return;
    try {
      await _access.release(folder.tree);
    } on FileOperationError {
      // Already revoked: forgetting it locally is enough.
    }
    if (!mounted) return;
    await AppScope.read(context).folderMemory?.write(null);
    setState(() {
      _folder = null;
      _items = null;
    });
  }

  Future<void> _validate(ProposedChange change) async {
    final folder = _folder!;
    // Null when cancelled; the (possibly edited) new name for a rename.
    final answer = await showDialog<String>(
      context: context,
      builder: (_) => _ConfirmChange(change: change, folder: folder),
    );
    if (answer == null || !mounted) return;
    final newName = answer;
    setState(() => _busy = true);
    _Outcome outcome;
    try {
      if (change.kind == ChangeKind.move) {
        final target = await _access.ensureFolder(folder.tree, change.folder!);
        await _access.move(folder.tree, change.file.id, target);
        outcome = _Outcome(
          true,
          '« ${change.file.name} » déplacé dans ${change.folder}',
          DateTime.now(),
        );
      } else {
        await _access.rename(folder.tree, change.file.id, newName);
        outcome = _Outcome(
          true,
          '« ${change.file.name} » renommé en « $newName »',
          DateTime.now(),
        );
      }
    } on FileOperationError catch (error) {
      outcome = _Outcome(
        false,
        '« ${change.file.name} » : ${error.message}',
        DateTime.now(),
      );
    }
    if (!mounted) return;
    setState(() => _journal.insert(0, outcome));
    // The proposals are computed again from what is really in the folder.
    await _list();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final folder = _folder;
    final items = _items;
    final changes = items == null
        ? const <ProposedChange>[]
        : proposeChanges(
            items,
          ).where((c) => !_ignored.contains(c.key)).toList();
    final Widget body;
    if (!_loaded) {
      body = const LoadingView();
    } else if (folder == null && _picked.isEmpty) {
      body = ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: NoticeBar(tone: 'warning', message: _problem!),
            ),
          MessageView(
            icon: Icons.folder_open_rounded,
            title: 'Ranger des fichiers',
            body:
                'NEXORA n’accède qu’au dossier ou aux fichiers que vous choisissez. Il '
                'propose un classement par type et des noms lisibles ; chaque '
                'déplacement ou renommage attend votre validation. Rien n’est '
                'supprimé, copié ni envoyé au serveur.',
            action: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _pick,
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('Organiser un dossier'),
                ),
                OutlinedButton.icon(
                  onPressed: _pickFiles,
                  icon: const Icon(Icons.file_open_rounded),
                  label: const Text('Choisir des fichiers'),
                ),
              ],
            ),
          ),
        ],
      );
    } else {
      final pickedChanges = proposeChanges(_picked);
      body = RefreshIndicator(
        onRefresh: _list,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: NoticeBar(tone: 'error', message: _problem!),
              ),
            if (folder == null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_off_rounded),
                  title: const Text('Aucun dossier de destination'),
                  subtitle: const Text(
                    'Les déplacements demandent un dossier autorisé.',
                  ),
                  trailing: TextButton(
                    onPressed: _pick,
                    child: const Text('Organiser…'),
                  ),
                ),
              )
            else
              Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_rounded),
                  title: Text(folder.name),
                  subtitle: Text(
                    items == null
                        ? 'Lecture…'
                        : '${items.where((i) => !i.isFolder).length} fichier(s), '
                              '${items.where((i) => i.isFolder).length} dossier(s)',
                  ),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Options du dossier',
                    onSelected: (value) =>
                        value == 'pick' ? _pick() : _forget(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'pick',
                        child: Text('Choisir un autre dossier'),
                      ),
                      PopupMenuItem(
                        value: 'forget',
                        child: Text('Retirer l’accès à ce dossier'),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _pickFiles,
                icon: const Icon(Icons.file_open_rounded),
                label: const Text(
                  'Choisir des fichiers (racine de Téléchargements comprise)',
                ),
              ),
            ),
            if (_picked.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Fichiers choisis (${_picked.length})',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              for (final file in _picked)
                if (pickedChanges.where((c) => c.file.id == file.id).firstOrNull
                    case final change?)
                  _ChangeCard(
                    change: change,
                    note: file.inFolder ? null : outsideFolder,
                    busy: _busy,
                    onIgnore: () => setState(
                      () => _picked = [
                        for (final f in _picked)
                          if (f.id != file.id) f,
                      ],
                    ),
                    onValidate: file.inFolder
                        ? () => _validatePicked(change)
                        : null,
                  )
                else
                  ListTile(
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(file.name),
                    subtitle: const Text('Rien à proposer pour ce fichier.'),
                  ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'NEXORA ne déplace ou ne renomme que les fichiers situés dans le dossier '
                  'autorisé, après vérification des noms. Pour les autres, il propose le '
                  'classement et l’application Fichiers du téléphone fait l’opération.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            if (folder != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Changements proposés dans ${folder.name} (${changes.length})',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 4),
              if (items != null && changes.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Rien à proposer : ce dossier est déjà rangé.'),
                ),
              for (final change in changes)
                _ChangeCard(
                  change: change,
                  busy: _busy,
                  onIgnore: () => setState(() => _ignored.add(change.key)),
                  onValidate: () => _validate(change),
                ),
            ],
            if (_journal.isNotEmpty) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Opérations effectuées',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              for (final outcome in _journal)
                ListTile(
                  leading: Icon(
                    outcome.ok
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
                  ),
                  title: Text(outcome.text),
                  subtitle: Text(formatShort(outcome.at)),
                ),
            ],
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Fichiers du téléphone')),
      body: body,
    );
  }
}

class _ChangeCard extends StatelessWidget {
  const _ChangeCard({
    required this.change,
    required this.busy,
    required this.onIgnore,
    required this.onValidate,
    this.note,
  });

  final ProposedChange change;
  final bool busy;
  final VoidCallback onIgnore;

  /// Null when NEXORA cannot apply the change itself ([note] says why).
  final VoidCallback? onValidate;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              change.kind == ChangeKind.move
                  ? 'Déplacer « ${change.file.name} » vers ${change.folder}/'
                  : 'Renommer « ${change.file.name} » en « ${change.newName} »',
            ),
            Text(change.reason, style: theme.textTheme.bodySmall),
            if (note != null) Text(note!, style: theme.textTheme.bodySmall),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: busy ? null : onIgnore,
                  child: const Text('Ignorer'),
                ),
                if (onValidate != null)
                  FilledButton.tonal(
                    onPressed: busy ? null : onValidate,
                    child: const Text('Valider…'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfirmChange extends StatefulWidget {
  const _ConfirmChange({required this.change, required this.folder});

  final ProposedChange change;
  final PickedFolder? folder;

  @override
  State<_ConfirmChange> createState() => _ConfirmChangeState();
}

class _ConfirmChangeState extends State<_ConfirmChange> {
  late final _name = TextEditingController(text: widget.change.newName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final change = widget.change;
    final move = change.kind == ChangeKind.move;
    return AlertDialog(
      title: Text(move ? 'Déplacer ce fichier ?' : 'Renommer ce fichier ?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Fichier : ${change.file.name}'),
            const SizedBox(height: 8),
            if (move)
              Text('Destination : ${widget.folder?.name}/${change.folder}/')
            else
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Nouveau nom'),
              ),
            const SizedBox(height: 12),
            Text(
              'Cette seule opération sera effectuée. Aucun fichier n’est supprimé '
              'ni remplacé.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, move ? '' : _name.text.trim()),
          child: Text(move ? 'Déplacer' : 'Renommer'),
        ),
      ],
    );
  }
}

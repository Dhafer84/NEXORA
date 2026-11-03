import 'package:flutter/material.dart';

import '../../files/classifier.dart';
import '../../files/file_access.dart';
import '../../state/app_state.dart';
import '../format.dart';
import '../widgets/states.dart';

/// Result of a validated change, kept for this session.
class _Outcome {
  const _Outcome(this.ok, this.text, this.at);

  final bool ok;
  final String text;
  final DateTime at;
}

/// Proposes moves and renames in one folder the user picked. Each change is
/// applied only after its own explicit validation; nothing is ever deleted.
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  PickedFolder? _folder;
  List<DeviceFile>? _items;
  final Set<String> _ignored = {};
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
    if (folder != null) await _list();
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

  Future<void> _pick() async {
    setState(() => _problem = null);
    try {
      final folder = await _access.pickFolder();
      if (folder == null || !mounted) return;
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
    } else if (folder == null) {
      body = MessageView(
        icon: Icons.folder_open_rounded,
        title: 'Choisissez un dossier',
        body:
            'NEXORA n’accède qu’au dossier que vous choisissez (par exemple '
            'Téléchargements). Il propose un classement par type et des noms '
            'lisibles ; chaque déplacement ou renommage attend votre validation. '
            'Rien n’est supprimé ni envoyé au serveur.',
        action: FilledButton.icon(
          onPressed: _pick,
          icon: const Icon(Icons.folder_open_rounded),
          label: const Text('Choisir un dossier'),
        ),
      );
    } else {
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
                  onSelected: (value) => value == 'pick' ? _pick() : _forget(),
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Changements proposés (${changes.length})',
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
              Card(
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
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () =>
                                      setState(() => _ignored.add(change.key)),
                            child: const Text('Ignorer'),
                          ),
                          FilledButton.tonal(
                            onPressed: _busy ? null : () => _validate(change),
                            child: const Text('Valider…'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
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

class _ConfirmChange extends StatefulWidget {
  const _ConfirmChange({required this.change, required this.folder});

  final ProposedChange change;
  final PickedFolder folder;

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
              Text('Destination : ${widget.folder.name}/${change.folder}/')
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

import 'package:flutter/material.dart';

import '../../api/api_error.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../format.dart';
import '../widgets/states.dart';
import 'chat_screen.dart';

/// Recent conversations stored on the server; any of them can be resumed.
class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  List<Conversation>? _items;
  ApiError? _error;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final items = await AppScope.read(context).api.conversations();
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } on ApiError catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _create() async {
    if (_creating) return;
    final title = await showDialog<String>(
      context: context,
      builder: (_) => const _TitleDialog(),
    );
    if (title == null || !mounted) return;
    setState(() => _creating = true);
    try {
      final conversation = await AppScope.read(
        context,
      ).api.createConversation(title);
      if (!mounted) return;
      await _open(conversation.id);
    } on ApiError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _open(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChatScreen(conversationId: id)),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    Widget body;
    if (_error != null && items == null) {
      body = ErrorView(error: _error!, onRetry: _load);
    } else if (items == null) {
      body = const LoadingView(label: 'Chargement des conversations…');
    } else if (items.isEmpty) {
      body = MessageView(
        icon: Icons.forum_outlined,
        title: 'Aucune conversation',
        body:
            'Posez votre première question à NEXORA, par exemple : '
            '« Quelle est la charge du serveur ? »',
        action: FilledButton.icon(
          onPressed: _create,
          icon: const Icon(Icons.add_comment_outlined),
          label: const Text('Nouvelle conversation'),
        ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = items[index];
            return ListTile(
              leading: const CircleAvatar(
                child: Icon(Icons.chat_bubble_outline),
              ),
              title: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text('Mise à jour ${formatShort(item.updatedAt)}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(item.id),
            );
          },
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Discussions'),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: body,
      floatingActionButton: items == null || items.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _creating ? null : _create,
              icon: const Icon(Icons.add_comment_outlined),
              label: const Text('Nouvelle'),
            ),
    );
  }
}

class _TitleDialog extends StatefulWidget {
  const _TitleDialog();

  @override
  State<_TitleDialog> createState() => _TitleDialogState();
}

class _TitleDialogState extends State<_TitleDialog> {
  final _controller = TextEditingController(text: 'Nouvelle conversation');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _controller.text.trim();
    if (title.isNotEmpty) {
      Navigator.pop(
        context,
        title.length > 200 ? title.substring(0, 200) : title,
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Nouvelle conversation'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLength: 200,
      decoration: const InputDecoration(labelText: 'Titre'),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Annuler'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Créer')),
    ],
  );
}

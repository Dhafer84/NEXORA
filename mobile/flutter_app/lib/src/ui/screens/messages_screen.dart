import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_error.dart';
import '../../state/app_state.dart';
import '../chat/chat_panel.dart';
import '../theme.dart';
import '../widgets/header.dart';
import '../widgets/states.dart';
import 'approval_detail_screen.dart';
import 'conversations_screen.dart';

/// Main screen: the current conversation, opened directly.
class MessagesScreen extends StatefulWidget {
  const MessagesScreen({super.key, this.onVoiceSettings, this.onOpenBubble});

  final VoidCallback? onVoiceSettings;

  /// Shows the current conversation in the bubble; null when unavailable.
  final ValueChanged<String>? onOpenBubble;

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  String? _conversationId;
  ApiError? _error;
  bool _resolving = true;
  // A new key per conversation: the panel (and its controller) is rebuilt.
  var _panel = GlobalKey<ChatPanelState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  /// The conversation last used in either window, else the most recent one,
  /// else a new one.
  Future<void> _resolve() async {
    final state = AppScope.read(context);
    setState(() {
      _resolving = true;
      _error = null;
    });
    try {
      var id = await state.currentConversation();
      if (id != null) {
        try {
          await state.api.conversation(id, limit: 1);
        } on ApiError catch (error) {
          if (error.kind != ApiErrorKind.notFound) rethrow;
          id = null; // Deleted on the server, or another server.
        }
      }
      if (id == null) {
        final recent = await state.api.conversations();
        id = recent.isNotEmpty
            ? recent.first.id
            : (await state.api.createConversation('Discussion')).id;
      }
      await state.setCurrentConversation(id);
      if (mounted) _show(id);
    } on ApiError catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _open(String id) async {
    await _panel.currentState?.saveDraft();
    if (!mounted) return;
    await AppScope.read(context).setCurrentConversation(id);
    if (mounted) _show(id);
  }

  void _show(String id) {
    if (id == _conversationId) return;
    setState(() {
      _conversationId = id;
      _panel = GlobalKey<ChatPanelState>();
    });
  }

  Future<void> _pickConversation() async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ConversationsScreen(currentId: _conversationId),
      ),
    );
    if (id != null && mounted) await _open(id);
  }

  Future<void> _newConversation() async {
    final title = await askConversationTitle(context);
    if (title == null || !mounted) return;
    try {
      final conversation = await AppScope.read(
        context,
      ).api.createConversation(title);
      await _open(conversation.id);
    } on ApiError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _openApproval(String id) async {
    final state = AppScope.read(context);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ApprovalDetailScreen(approvalId: id),
      ),
    );
    // The decision was taken (or not) on the detail screen; the history shows it.
    await state.refreshPending();
    final panel = _panel.currentState;
    if (panel != null) {
      if (panel.chat.banner?.approvalId == id) panel.chat.dismissBanner();
      await panel.chat.reload();
    }
  }

  @override
  void didUpdateWidget(MessagesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(_followCurrent());
  }

  /// Another screen (bubble, shortcut) may have chosen a conversation.
  Future<void> _followCurrent() async {
    final id = await AppScope.read(context).currentConversation();
    if (id != null && mounted) _show(id);
  }

  @override
  Widget build(BuildContext context) {
    final id = _conversationId;
    Widget body;
    if (id != null) {
      body = ChatPanel(
        key: _panel,
        conversationId: id,
        onOpenApproval: _openApproval,
        onVoiceSettings: widget.onVoiceSettings,
      );
    } else if (_error != null) {
      body = ErrorView(error: _error!, onRetry: _resolve);
    } else {
      body = LoadingView(
        label: _resolving ? 'Ouverture de la discussion…' : 'Chargement…',
      );
    }
    final openBubble = widget.onOpenBubble;
    return Scaffold(
      appBar: AppBar(
        title: const Text('NEXORA'),
        actions: [
          const Flexible(child: ConnectionIndicator()),
          const SizedBox(width: Space.s),
          ...headerActions(),
          PopupMenuButton<String>(
            tooltip: 'Plus d’options',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (value) => switch (value) {
              'list' => _pickConversation(),
              'new' => _newConversation(),
              'reload' => _panel.currentState?.chat.reload(),
              'bubble' => id == null ? null : openBubble?.call(id),
              _ => null,
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'list',
                child: ListTile(
                  leading: Icon(Icons.forum_rounded),
                  title: Text('Discussions'),
                ),
              ),
              const PopupMenuItem(
                value: 'new',
                child: ListTile(
                  leading: Icon(Icons.add_comment_rounded),
                  title: Text('Nouvelle discussion'),
                ),
              ),
              PopupMenuItem(
                value: 'reload',
                enabled: id != null,
                child: const ListTile(
                  leading: Icon(Icons.refresh_rounded),
                  title: Text('Recharger l’historique'),
                ),
              ),
              if (openBubble != null)
                PopupMenuItem(
                  value: 'bubble',
                  enabled: id != null,
                  child: const ListTile(
                    leading: Icon(Icons.bubble_chart_rounded),
                    title: Text('Ouvrir dans la bulle'),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: SafeArea(top: false, child: body),
    );
  }
}

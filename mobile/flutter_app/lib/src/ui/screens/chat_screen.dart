import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../state/chat_controller.dart';
import '../format.dart';
import '../widgets/states.dart';
import 'approval_detail_screen.dart';

const maxMessageChars = 4000; // Backend default NEXORA_AI_MAX_INPUT_CHARS.

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final ChatController _chat;
  final _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    _chat =
        ChatController(
            api: AppScope.read(context).api,
            conversationId: widget.conversationId,
          )
          ..addListener(_changed)
          ..reload();
    _input.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _chat
      ..removeListener(_changed)
      ..dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty || _chat.sending) return;
    _input.clear();
    final outcome = await _chat.send(text);
    if (!mounted) return;
    // Restore the draft only when the server certainly did not process it.
    if (outcome == SendOutcome.rejected && _input.text.isEmpty) {
      _input.text = text;
    }
    if (outcome == SendOutcome.sent && _chat.banner?.approvalId != null) {
      await AppScope.read(context).refreshPending();
    }
  }

  Future<void> _openApproval(String id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ApprovalDetailScreen(approvalId: id),
      ),
    );
    if (!mounted) return;
    // The decision was taken (or not) on the detail screen; the history now shows it.
    if (_chat.banner?.approvalId == id) _chat.dismissBanner();
    await _chat.reload();
  }

  @override
  Widget build(BuildContext context) {
    final banner = _chat.banner;
    final items = _chat.messages.reversed.toList();
    Widget content;
    if (_chat.loadError != null && _chat.messages.isEmpty) {
      content = ErrorView(error: _chat.loadError!, onRetry: _chat.reload);
    } else if (_chat.loading && _chat.messages.isEmpty && !_chat.sending) {
      content = const LoadingView(label: 'Chargement de l’historique…');
    } else if (_chat.messages.isEmpty && !_chat.sending) {
      content = const MessageView(
        icon: Icons.waving_hand_outlined,
        title: 'Conversation vide',
        body:
            'Exemples : « Quelle est la charge du serveur ? », '
            '« La base de données répond-elle ? »',
      );
    } else {
      // Newest first in a reversed list: the view stays anchored at the bottom.
      final pending = [
        if (_chat.sending) const _Thinking(),
        if (_chat.sending)
          _Bubble.outgoing(text: _chat.pendingText!, pending: true),
      ];
      content = ListView.builder(
        reverse: true,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.all(12),
        itemCount: pending.length + items.length,
        itemBuilder: (context, index) => index < pending.length
            ? pending[index]
            : _MessageTile(
                message: items[index - pending.length],
                onOpenApproval: _openApproval,
              ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _chat.conversation?.title ?? 'Conversation',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Recharger l’historique',
            onPressed: _chat.sending ? null : _chat.reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (banner != null)
              NoticeBar(
                tone: switch (banner.tone) {
                  BannerTone.info => 'neutral',
                  BannerTone.warning => 'warning',
                  BannerTone.error => 'error',
                },
                message: banner.message,
                actionLabel: banner.approvalId == null ? null : 'Voir',
                onAction: banner.approvalId == null
                    ? null
                    : () => _openApproval(banner.approvalId!),
                onClose: _chat.dismissBanner,
              ),
            if (_chat.loading && _chat.messages.isNotEmpty)
              const LinearProgressIndicator(),
            Expanded(child: content),
            _Composer(
              controller: _input,
              sending: _chat.sending,
              onSend: _send,
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final canSend = !sending && controller.text.trim().isNotEmpty;
    return Material(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !sending,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                maxLength: maxMessageChars,
                maxLengthEnforcement: MaxLengthEnforcement.enforced,
                buildCounter:
                    (
                      context, {
                      required currentLength,
                      required isFocused,
                      maxLength,
                    }) => currentLength > maxMessageChars - 200
                    ? Text('$currentLength / $maxMessageChars')
                    : null,
                decoration: InputDecoration(
                  hintText: sending
                      ? 'Réponse en cours…'
                      : 'Votre demande en français',
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: 'Envoyer',
              onPressed: canSend ? onSend : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: 'NEXORA traite la demande',
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'NEXORA traite la demande… (jusqu’à 2 minutes)',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    ),
  );
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, required this.onOpenApproval});

  final ChatMessage message;
  final ValueChanged<String> onOpenApproval;

  @override
  Widget build(BuildContext context) {
    switch (message.role) {
      case 'user':
        return _Bubble.outgoing(text: message.content, time: message.createdAt);
      case 'tool':
        return _ToolCard(message: message, onOpenApproval: onOpenApproval);
      default:
        return _Bubble.incoming(
          message: message,
          onOpenApproval: onOpenApproval,
        );
    }
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble.outgoing({required this.text, this.time, this.pending = false})
    : message = null,
      onOpenApproval = null;

  const _Bubble.incoming({
    required ChatMessage this.message,
    this.onOpenApproval,
  }) : text = null,
       time = null,
       pending = false;

  final String? text;
  final DateTime? time;
  final bool pending;
  final ChatMessage? message;
  final ValueChanged<String>? onOpenApproval;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final outgoing = message == null;
    final error = message?.status == 'error';
    final background = outgoing
        ? scheme.primaryContainer
        : error
        ? scheme.errorContainer
        : scheme.surfaceContainerHigh;
    final foreground = outgoing
        ? scheme.onPrimaryContainer
        : error
        ? scheme.onErrorContainer
        : scheme.onSurface;
    final stamp = message?.createdAt ?? time;
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.86,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(16).copyWith(
              bottomRight: outgoing ? const Radius.circular(4) : null,
              bottomLeft: outgoing ? null : const Radius.circular(4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message?.isSimulated ?? false)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: StatusChip(
                    label: 'Simulation — pas une IA réelle',
                    icon: Icons.science_outlined,
                  ),
                ),
              SelectableText.rich(
                TextSpan(children: inlineBold(text ?? message!.content)),
                style: TextStyle(color: foreground),
              ),
              if (message?.approvalRequestId != null) ...[
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: () => onOpenApproval!(message!.approvalRequestId!),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Ouvrir la validation'),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                pending ? 'Envoi…' : (stamp == null ? '' : formatTime(stamp)),
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Minimal rendering of `**bold**`, the only markup models commonly use in short answers.
List<TextSpan> inlineBold(String text) {
  final parts = text.split('**');
  if (parts.length < 3) return [TextSpan(text: text)];
  return [
    for (var i = 0; i < parts.length; i++)
      TextSpan(
        text: i.isOdd && i == parts.length - 1 ? '**${parts[i]}' : parts[i],
        style: i.isOdd && i != parts.length - 1
            ? const TextStyle(fontWeight: FontWeight.bold)
            : null,
      ),
  ];
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.message, required this.onOpenApproval});

  final ChatMessage message;
  final ValueChanged<String> onOpenApproval;

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic> payload;
    try {
      payload = Map<String, dynamic>.from(jsonDecode(message.content) as Map);
    } on Object {
      payload = {'tool': 'outil', 'status': message.status};
    }
    final tool = payload['tool'] as String? ?? 'outil';
    final status = payload['status'] as String? ?? message.status;
    final error = payload['error'] is Map ? payload['error'] as Map : null;
    final details = payload['result'] ?? payload['approval'] ?? error;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        shape: const Border(),
        leading: const Icon(Icons.build_circle_outlined),
        title: Text(toolLabel(tool)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: StatusChip(
              label: executionStatusLabels[status] ?? status,
              tone: statusTones[status] ?? 'neutral',
            ),
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null) Text('${error['message'] ?? error['code']}'),
          if (details != null)
            SelectableText(
              const JsonEncoder.withIndent('  ').convert(details),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          if (message.approvalRequestId != null)
            TextButton.icon(
              onPressed: () => onOpenApproval(message.approvalRequestId!),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Ouvrir la validation'),
            ),
          Text(
            formatShort(message.createdAt),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

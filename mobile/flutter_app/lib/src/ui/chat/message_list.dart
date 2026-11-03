import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/nexora_mark.dart';
import '../widgets/states.dart';
import 'tool_cards.dart';

/// Display order: within a turn (a user message and what follows it), the
/// answer comes before the tool cards, as on the reference design. The stored
/// order on the server is unchanged.
List<ChatMessage> displayOrder(List<ChatMessage> messages) {
  final ordered = <ChatMessage>[];
  final answers = <ChatMessage>[];
  final tools = <ChatMessage>[];
  void flush() {
    ordered
      ..addAll(answers)
      ..addAll(tools);
    answers.clear();
    tools.clear();
  }

  for (final message in messages) {
    switch (message.role) {
      case 'user':
        flush();
        ordered.add(message);
      case 'tool':
        tools.add(message);
      default:
        answers.add(message);
    }
  }
  flush();
  return ordered;
}

/// Reading aloud for one answer: null hides the button.
class ListenAction {
  const ListenAction({
    required this.speaking,
    required this.onListen,
    required this.onStop,
  });

  final bool speaking;
  final VoidCallback onListen;
  final VoidCallback onStop;
}

class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.pendingIds,
    required this.onOpenApproval,
    this.listen,
    this.compact = false,
  });

  final ChatMessage message;
  final Set<String> pendingIds;
  final ValueChanged<String> onOpenApproval;
  final ListenAction? listen;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    switch (message.role) {
      case 'user':
        return UserBubble(
          text: message.content,
          time: message.createdAt,
          compact: compact,
        );
      case 'tool':
        return Padding(
          padding: EdgeInsets.only(
            left: compact ? 0 : Space.xs,
            top: Space.xs,
            bottom: Space.xs,
          ),
          child: ToolCard(
            message: message,
            pendingIds: pendingIds,
            onOpenApproval: onOpenApproval,
            compact: compact,
          ),
        );
      default:
        return AssistantBubble(
          message: message,
          listen: listen,
          compact: compact,
        );
    }
  }
}

double _maxBubbleWidth(BuildContext context, bool compact) =>
    MediaQuery.sizeOf(context).width * (compact ? 0.78 : 0.74);

class UserBubble extends StatelessWidget {
  const UserBubble({
    super.key,
    required this.text,
    this.time,
    this.status,
    this.compact = false,
  });

  final String text;
  final DateTime? time;

  /// Shown instead of the time while the message is not stored yet.
  final String? status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = NexoraColors.of(context);
    final avatar = compact ? 28.0 : 36.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: _maxBubbleWidth(context, compact),
                  ),
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? Space.m : Space.l,
                      vertical: compact ? Space.s : Space.m,
                    ),
                    decoration: BoxDecoration(
                      color: colors.userBubble,
                      borderRadius: BorderRadius.circular(Radii.xl),
                    ),
                    child: SelectableText(
                      text,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colors.onUserBubble,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Space.xs),
                Semantics(
                  label:
                      status ??
                      (time == null ? null : 'Envoyé à ${formatTime(time!)}'),
                  excludeSemantics: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        status ?? (time == null ? '' : formatTime(time!)),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: Space.xs),
                      Icon(
                        status == null
                            ? Icons.done_all_rounded
                            : Icons.schedule_rounded,
                        size: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.s),
          ExcludeSemantics(
            child: CircleAvatar(
              radius: avatar / 2,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              child: Icon(
                Icons.person_rounded,
                size: avatar * 0.6,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AssistantBubble extends StatelessWidget {
  const AssistantBubble({
    super.key,
    required this.message,
    this.listen,
    this.compact = false,
  });

  final ChatMessage message;
  final ListenAction? listen;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = NexoraColors.of(context);
    final error = message.status == 'error';
    final background = error
        ? theme.colorScheme.errorContainer
        : colors.assistantBubble;
    final foreground = error
        ? theme.colorScheme.onErrorContainer
        : colors.onAssistantBubble;
    final listen = this.listen;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NexoraMark(size: compact ? 30 : 38),
          const SizedBox(width: Space.s),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: _maxBubbleWidth(context, compact),
                  ),
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? Space.m : Space.l,
                      vertical: compact ? Space.s : Space.m,
                    ),
                    decoration: BoxDecoration(
                      color: background,
                      borderRadius: BorderRadius.circular(Radii.xl),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (message.isSimulated)
                          const Padding(
                            padding: EdgeInsets.only(bottom: Space.s),
                            child: StatusChip(
                              label: 'Simulation — pas une IA réelle',
                              icon: Icons.science_rounded,
                            ),
                          ),
                        SelectableText.rich(
                          TextSpan(children: inlineBold(message.content)),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: foreground,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: Space.s),
                      child: Text(
                        formatTime(message.createdAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (listen != null)
                      IconButton(
                        tooltip: listen.speaking
                            ? 'Arrêter la lecture'
                            : 'Écouter la réponse',
                        onPressed: listen.speaking
                            ? listen.onStop
                            : listen.onListen,
                        icon: Icon(
                          listen.speaking
                              ? Icons.stop_circle_rounded
                              : Icons.volume_up_rounded,
                          size: 20,
                          color: listen.speaking
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ThinkingRow extends StatelessWidget {
  const ThinkingRow({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: 'NEXORA traite la demande',
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.s),
      child: Row(
        children: [
          NexoraMark(size: compact ? 30 : 38),
          const SizedBox(width: Space.m),
          const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: Space.m),
          Expanded(
            child: Text(
              compact
                  ? 'NEXORA réfléchit…'
                  : 'NEXORA traite la demande… (jusqu’à 2 minutes)',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    ),
  );
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../voice/voice_controller.dart';
import '../theme.dart';

const maxMessageChars = 4000; // Backend default NEXORA_AI_MAX_INPUT_CHARS.

/// Message field, microphone and send button. While listening, a panel shows
/// that the microphone is open, with "Arrêter" and "Annuler".
class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.busy,
    required this.onSend,
    this.voice,
    this.focusNode,
    this.compact = false,
  });

  final TextEditingController controller;

  /// A message is being sent (from this window or the other one).
  final bool busy;
  final VoidCallback onSend;
  final VoiceController? voice;
  final FocusNode? focusNode;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final voice = this.voice;
    if (voice != null && voice.listening) {
      return _ListeningPanel(voice: voice, compact: compact);
    }
    final theme = Theme.of(context);
    final hasText = controller.text.trim().isNotEmpty;
    final canSend = !busy && hasText;
    final mic = voice == null
        ? null
        : IconButton(
            tooltip: 'Dicter un message',
            onPressed: busy ? null : voice.start,
            icon: const Icon(Icons.mic_none_rounded),
          );
    final send = IconButton.filled(
      tooltip: 'Envoyer',
      iconSize: 26,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(52),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: theme.colorScheme.onPrimary,
        disabledBackgroundColor: theme.colorScheme.surfaceContainerHighest,
      ),
      onPressed: canSend ? onSend : null,
      icon: const Icon(Icons.send_rounded),
    );
    // Compact: one large button, the microphone while the field is empty.
    final showBigMic = compact && mic != null && !hasText;
    final bigMic = IconButton.filled(
      tooltip: 'Dicter un message',
      iconSize: 26,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(52),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: theme.colorScheme.onPrimary,
      ),
      onPressed: busy ? null : voice?.start,
      icon: const Icon(Icons.mic_rounded),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? Space.m : Space.l,
        Space.s,
        compact ? Space.m : Space.m,
        Space.m,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: !busy,
              minLines: 1,
              maxLines: compact ? 3 : 5,
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
                hintText: busy ? 'Réponse en cours…' : 'Écrire un message…',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Space.xl,
                  vertical: Space.m,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  borderSide: BorderSide(
                    color: theme.colorScheme.outlineVariant,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  borderSide: BorderSide(
                    color: theme.colorScheme.outlineVariant,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  borderSide: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
                suffixIcon: compact && !hasText ? null : mic,
              ),
            ),
          ),
          const SizedBox(width: Space.s),
          if (showBigMic) bigMic else send,
        ],
      ),
    );
  }
}

class _ListeningPanel extends StatelessWidget {
  const _ListeningPanel({required this.voice, required this.compact});

  final VoiceController voice;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preparing = voice.phase == VoicePhase.preparing;
    final heard = voice.partial;
    return Semantics(
      liveRegion: true,
      container: true,
      label: preparing ? 'Préparation du micro' : 'Écoute en cours',
      child: Container(
        margin: EdgeInsets.fromLTRB(
          compact ? Space.m : Space.l,
          Space.s,
          compact ? Space.m : Space.l,
          Space.m,
        ),
        padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.s, Space.m),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(Radii.xl),
        ),
        child: Row(
          children: [
            _PulsingMic(color: theme.colorScheme.onPrimaryContainer),
            const SizedBox(width: Space.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    preparing ? 'Préparation du micro…' : 'J’écoute…',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  Text(
                    heard.isEmpty ? 'Parlez en français' : heard,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Annuler la dictée',
              onPressed: voice.cancel,
              icon: Icon(
                Icons.close_rounded,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            IconButton.filled(
              tooltip: 'Arrêter l’écoute',
              style: IconButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
              ),
              onPressed: preparing ? null : voice.stop,
              icon: const Icon(Icons.stop_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulsingMic extends StatefulWidget {
  const _PulsingMic({required this.color});

  final Color color;

  @override
  State<_PulsingMic> createState() => _PulsingMicState();
}

class _PulsingMicState extends State<_PulsingMic>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect "remove animations" in the phone's accessibility settings.
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: Tween(begin: 0.9, end: 1.15).animate(_pulse),
    child: Icon(Icons.mic_rounded, color: widget.color, size: 28),
  );
}

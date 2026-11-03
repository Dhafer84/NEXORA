import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../session/session.dart';
import '../../state/app_state.dart';
import '../../state/chat_controller.dart';
import '../../voice/voice_controller.dart';
import '../../voice/voice_service.dart';
import '../theme.dart';
import '../widgets/nexora_mark.dart';
import '../widgets/states.dart';
import 'composer.dart';
import 'message_list.dart';

/// One conversation with its history, message field, dictation and reading
/// aloud. Shared by the Messages tab and the mini-chat ([compact]).
class ChatPanel extends StatefulWidget {
  const ChatPanel({
    super.key,
    required this.conversationId,
    required this.onOpenApproval,
    this.compact = false,
    this.onVoiceSettings,
  });

  final String conversationId;

  /// Opens a validation request (never approves it).
  final ValueChanged<String> onOpenApproval;

  /// Opens the voice section of the settings (remote recognition choice).
  final VoidCallback? onVoiceSettings;
  final bool compact;

  @override
  State<ChatPanel> createState() => ChatPanelState();
}

class ChatPanelState extends State<ChatPanel> with WidgetsBindingObserver {
  late final AppState _state;
  late final ChatController _chat;
  VoiceController? _voice;
  VoiceCapabilities? _caps;
  final _input = TextEditingController();
  final _focus = FocusNode();
  Timer? _draftTimer;
  bool _draftLoaded = false;

  ChatController get chat => _chat;

  @override
  void initState() {
    super.initState();
    _state = AppScope.read(context);
    _chat =
        ChatController(
            api: _state.api,
            conversationId: widget.conversationId,
            turns: _state.turns,
            owner: _state.window,
          )
          ..addListener(_changed)
          ..reload();
    final service = _state.voice;
    if (service != null) {
      _voice = VoiceController(
        service: service,
        allowRemote: _state.allowRemoteRecognition,
        onTranscript: _insertTranscript,
      )..addListener(_changed);
      service.capabilities().then((caps) {
        if (mounted) setState(() => _caps = caps);
      }, onError: (_) {});
    }
    _input.addListener(_draftChanged);
    unawaited(_restoreDraft());
    WidgetsBinding.instance.addObserver(this);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _draftTimer?.cancel();
    if (_draftLoaded) unawaited(_saveDraft());
    _voice
      ?..removeListener(_changed)
      ..dispose();
    _chat
      ..removeListener(_changed)
      ..dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // The other window may have changed the history or the draft.
        unawaited(_chat.reload());
        unawaited(_restoreDraft());
      case AppLifecycleState.inactive:
        // Permission dialog, notification shade: still on screen, keep
        // listening (the microphone request itself makes the app inactive).
        _draftTimer?.cancel();
        if (_draftLoaded) unawaited(_saveDraft());
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        unawaited(_voice?.interrupt());
        _draftTimer?.cancel();
        if (_draftLoaded) unawaited(_saveDraft());
      case AppLifecycleState.detached:
        break;
    }
  }

  // ----- Draft ------------------------------------------------------------------

  Future<void> _restoreDraft() async {
    final stored =
        await _state.session.getString(
          SessionKeys.draft(widget.conversationId),
        ) ??
        '';
    if (!mounted) return;
    _draftLoaded = true;
    if (stored != _input.text && !_chat.sending) {
      _input.value = TextEditingValue(
        text: stored,
        selection: TextSelection.collapsed(offset: stored.length),
      );
    }
  }

  void _draftChanged() {
    _changed();
    if (!_draftLoaded) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 300), _saveDraft);
  }

  /// Writes the draft now (also before switching to the other window).
  Future<void> saveDraft() {
    _draftTimer?.cancel();
    return _saveDraft();
  }

  Future<void> _saveDraft() => _state.session.setString(
    SessionKeys.draft(widget.conversationId),
    _input.text.isEmpty ? null : _input.text,
  );

  // ----- Voice ------------------------------------------------------------------

  void _insertTranscript(String text) {
    // Inserted, never sent: the user corrects, deletes or sends it.
    final current = _input.text;
    final separator = current.isEmpty || current.endsWith(' ') ? '' : ' ';
    final value = '$current$separator$text';
    _input.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _focus.requestFocus();
  }

  ListenAction? _listenFor(ChatMessage message) {
    final voice = _voice;
    if (voice == null || message.status == 'error') return null;
    return ListenAction(
      speaking: voice.speakingId == message.id,
      onListen: () => _listen(message),
      onStop: voice.stopSpeaking,
    );
  }

  Future<void> _listen(ChatMessage message) async {
    final voice = _voice!;
    final caps = _caps ?? await _state.voice!.capabilities();
    if (caps.output != SpeechOutput.offline) {
      _showVoiceProblem(
        caps.output == SpeechOutput.networkOnly
            ? 'La voix française de ce téléphone exige une connexion à son '
                  'éditeur : la lecture n’est pas utilisée.'
            : 'Aucune voix française n’est installée sur ce téléphone '
                  '(réglages Android, Synthèse vocale).',
      );
      return;
    }
    await voice.speak(message.id, message.content);
  }

  void _showVoiceProblem(String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  // ----- Sending ----------------------------------------------------------------

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty || _chat.busy) return;
    await _voice?.cancel();
    _input.clear();
    final outcome = await _chat.send(text);
    if (!mounted) return;
    // Restore the draft only when the server certainly did not process it.
    if ((outcome == SendOutcome.rejected || outcome == SendOutcome.busy) &&
        _input.text.isEmpty) {
      _input.text = text;
    }
    if (outcome == SendOutcome.sent) {
      await _saveDraft();
      await _state.refreshPending();
      final reply = _chat.lastReply;
      if (reply != null && _voice != null && await _state.autoRead()) {
        if (mounted && !(_voice?.listening ?? true)) await _listen(reply);
      }
    }
  }

  // ----- Layout -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    final banner = _chat.banner;
    final items = displayOrder(_chat.messages).reversed.toList();
    final pendingIds = AppScope.of(context).pendingIds;
    Widget content;
    if (_chat.loadError != null && _chat.messages.isEmpty) {
      content = ErrorView(error: _chat.loadError!, onRetry: _chat.reload);
    } else if (_chat.loading && _chat.messages.isEmpty && !_chat.busy) {
      content = const LoadingView(label: 'Chargement de l’historique…');
    } else if (_chat.messages.isEmpty && !_chat.busy) {
      content = _Welcome(compact: compact);
    } else {
      // Newest first in a reversed list: the view stays anchored at the bottom.
      final pending = <Widget>[
        if (_chat.busy) ThinkingRow(compact: compact),
        if (_chat.sending)
          UserBubble(
            text: _chat.pendingText!,
            status: 'Envoi…',
            compact: compact,
          ),
        if (!_chat.sending && _chat.otherWindowText != null)
          UserBubble(
            text: _chat.otherWindowText!,
            status: _state.window == 'bubble'
                ? 'Envoi depuis l’application…'
                : 'Envoi depuis la bulle…',
            compact: compact,
          ),
      ];
      content = ListView.builder(
        reverse: true,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? Space.m : Space.l,
          vertical: Space.m,
        ),
        itemCount: pending.length + items.length,
        itemBuilder: (context, index) {
          if (index < pending.length) return pending[index];
          final message = items[index - pending.length];
          return MessageTile(
            message: message,
            pendingIds: pendingIds,
            onOpenApproval: widget.onOpenApproval,
            listen: message.role == 'assistant' ? _listenFor(message) : null,
            compact: compact,
          );
        },
      );
    }
    final notice = _voice?.notice;
    return Column(
      children: [
        // A validation request shows as its card in the history instead.
        if (banner != null && banner.approvalId == null)
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
                : () => widget.onOpenApproval(banner.approvalId!),
            onClose: _chat.dismissBanner,
          ),
        if (_chat.loading && _chat.messages.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        Expanded(child: content),
        if (notice != null)
          NoticeBar(
            tone: 'neutral',
            message: notice.message,
            actionLabel: switch (notice.action) {
              VoiceNoticeAction.openAppSettings => 'Réglages Android',
              VoiceNoticeAction.openVoiceSettings =>
                widget.onVoiceSettings == null ? null : 'Réglages',
              null => null,
            },
            onAction: switch (notice.action) {
              VoiceNoticeAction.openAppSettings =>
                _state.voice?.openAppSettings,
              VoiceNoticeAction.openVoiceSettings => widget.onVoiceSettings,
              null => null,
            },
            onClose: _voice!.dismissNotice,
          ),
        ChatComposer(
          controller: _input,
          focusNode: _focus,
          busy: _chat.busy,
          onSend: _send,
          voice: _voice,
          compact: compact,
        ),
      ],
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NexoraMark(size: compact ? 48 : 72),
            const SizedBox(height: Space.l),
            Text(
              'Bonjour, que puis-je faire ?',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Space.s),
            Text(
              'Exemples : « Vérifie l’espace disque », « La base de données '
              'répond-elle ? »',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

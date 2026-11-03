import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../api/models.dart';
import '../session/session.dart';

enum BannerTone { info, warning, error }

class ChatBanner {
  const ChatBanner(this.tone, this.message, {this.approvalId});

  final BannerTone tone;
  final String message;

  /// Set when the turn created a validation request the user can open.
  final String? approvalId;
}

enum SendOutcome {
  /// Ignored: empty text or a turn already in progress.
  ignored,

  /// Stored by the server (with or without an answer).
  sent,

  /// Definitely not processed: the draft can be restored.
  rejected,

  /// Not sent: the other NEXORA window is sending in this conversation.
  busy,

  /// No answer received: maybe processed. Never resent automatically.
  uncertain,
}

/// One conversation: persisted history from the server and a single in-flight turn.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.api,
    required this.conversationId,
    TurnLock? turns,
    this.owner = 'app',
  }) : turns = turns ?? MemoryTurnLock() {
    _changes = this.turns.changes
        .where((id) => id == conversationId)
        .listen((_) => _otherWindowChanged());
    unawaited(_otherWindowChanged());
  }

  final NexoraApi api;
  final String conversationId;

  /// Shared with the other NEXORA window: one message in flight at a time.
  final TurnLock turns;
  final String owner;
  late final StreamSubscription<String> _changes;

  /// Text being sent by the other window, shown as pending here.
  String? otherWindowText;

  /// The answer received for the last message sent from this window.
  ChatMessage? lastReply;

  Conversation? conversation;
  List<ChatMessage> messages = const [];
  bool loading = false;
  ApiError? loadError;
  ChatBanner? banner;
  String? pendingText;
  bool _disposed = false;

  bool get sending => pendingText != null;

  /// No message can be sent: this window or the other one waits for an answer.
  bool get busy => sending || otherWindowText != null;

  Future<void> _otherWindowChanged() async {
    final turn = await turns.inFlight(conversationId);
    if (_disposed) return;
    final previous = otherWindowText;
    otherWindowText = turn == null || turn.owner == owner ? null : turn.text;
    _notify();
    // The other window got its answer: show it here too.
    if (previous != null && otherWindowText == null && !sending) {
      await reload();
    }
  }

  Future<void> reload() async {
    loading = true;
    _notify();
    try {
      final detail = await api.conversation(conversationId);
      conversation = detail.conversation;
      messages = detail.messages;
      loadError = null;
    } on ApiError catch (error) {
      loadError = error;
    } finally {
      loading = false;
      _notify();
    }
  }

  void dismissBanner() {
    banner = null;
    _notify();
  }

  Future<SendOutcome> send(String text) async {
    final content = text.trim();
    // Synchronous guard: a second tap before the first await is ignored.
    if (content.isEmpty || sending) return SendOutcome.ignored;
    pendingText = content;
    banner = null;
    lastReply = null;
    _notify();
    if (otherWindowText != null ||
        !await turns.begin(conversationId, owner, content)) {
      pendingText = null;
      banner = const ChatBanner(
        BannerTone.warning,
        'Un message est déjà en cours d’envoi dans l’autre fenêtre de NEXORA. '
        'Le vôtre n’est pas envoyé : il reste dans le champ de saisie.',
      );
      _notify();
      return SendOutcome.busy;
    }
    try {
      final result = await api.sendMessage(conversationId, content);
      lastReply = result.messages
          .where((message) => message.role == 'assistant')
          .lastOrNull;
      banner = switch (result.status) {
        'pending_approval' => ChatBanner(
          BannerTone.warning,
          'Une action attend votre validation. Rien n’est exécuté sans votre accord.',
          approvalId: result.toolExecutions
              .map((execution) => execution.approval?.id)
              .whereType<String>()
              .firstOrNull,
        ),
        'limit_reached' => const ChatBanner(
          BannerTone.info,
          'Limite de traitement atteinte pour cette demande (nombre d’outils ou durée).',
        ),
        _ => null,
      };
      await _refreshAfter(result.messages);
      return SendOutcome.sent;
    } on ApiError catch (error) {
      return _handleSendError(error);
    } finally {
      pendingText = null;
      await turns.end(conversationId, owner);
      _notify();
    }
  }

  Future<SendOutcome> _handleSendError(ApiError error) async {
    if (error.outcomeUnknown) {
      banner = ChatBanner(
        BannerTone.warning,
        '${error.message} Le message n’est pas renvoyé automatiquement : '
        'l’historique a été rechargé, vérifiez-le avant de réessayer.',
      );
      await _refreshAfter(const []);
      return SendOutcome.uncertain;
    }
    if (error.kind == ApiErrorKind.unavailable &&
        (error.code ?? '').startsWith('ai_') &&
        error.code != 'ai_not_configured') {
      // The server stored the message and an error answer: reload, do not resend.
      banner = ChatBanner(BannerTone.error, _providerMessage(error));
      await _refreshAfter(error.messages);
      return SendOutcome.sent;
    }
    banner = ChatBanner(BannerTone.error, switch (error.code) {
      'ai_not_configured' =>
        'Aucun fournisseur IA n’est configuré sur le serveur. '
            'Le tableau de bord et les validations restent disponibles.',
      'turn_in_progress' =>
        'Une demande est déjà en cours dans cette conversation. '
            'Attendez sa fin puis rechargez.',
      _ => error.message,
    });
    return SendOutcome.rejected;
  }

  static String _providerMessage(ApiError error) => switch (error.code) {
    'ai_timeout' =>
      'Le fournisseur IA n’a pas répondu à temps. Votre message est enregistré.',
    'ai_rate_limited' =>
      'Quota du fournisseur IA atteint. Réessayez plus tard.',
    'ai_auth' =>
      'La clé du fournisseur IA est refusée : à vérifier sur le serveur.',
    _ =>
      'Le fournisseur IA est indisponible. Votre message est enregistré ; '
          'les contrôles du serveur restent accessibles.',
  };

  Future<void> _refreshAfter(List<ChatMessage> fallback) async {
    try {
      final detail = await api.conversation(conversationId);
      conversation = detail.conversation;
      messages = detail.messages;
      loadError = null;
    } on ApiError {
      // Keep what the server returned with the turn; avoid duplicates by id.
      final known = {for (final message in messages) message.id};
      messages = [
        ...messages,
        ...fallback.where((message) => !known.contains(message.id)),
      ];
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _changes.cancel();
    super.dispose();
  }
}

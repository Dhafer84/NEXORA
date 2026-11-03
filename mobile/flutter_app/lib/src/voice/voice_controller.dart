import 'dart:async';

import 'package:flutter/foundation.dart';

import 'voice_service.dart';

enum VoicePhase { idle, preparing, listening }

/// A problem shown under the message field. The text field stays usable.
class VoiceNotice {
  const VoiceNotice(this.message, {this.action});

  final String message;

  /// What the notice button does, when there is one.
  final VoiceNoticeAction? action;
}

enum VoiceNoticeAction { openAppSettings, openVoiceSettings }

/// Dictation and reading aloud for one chat window. A transcript is only ever
/// put into the message field ([onTranscript]); sending stays a separate tap.
class VoiceController extends ChangeNotifier {
  VoiceController({
    required this.service,
    required this.allowRemote,
    required this.onTranscript,
  }) {
    _subscription = service.events.listen(_onEvent);
  }

  final VoiceService service;

  /// Current user choice for remote recognition (read at each start).
  final Future<bool> Function() allowRemote;

  /// Receives the final transcript, to be inserted in the message field.
  final ValueChanged<String> onTranscript;

  late final StreamSubscription<VoiceEvent> _subscription;
  VoicePhase phase = VoicePhase.idle;
  String partial = '';
  VoiceNotice? notice;

  /// Id of the message being read aloud.
  String? speakingId;
  RecognitionMode? mode;

  // Events of a cancelled or older utterance are ignored.
  int _generation = 0;
  int? _active;
  bool _disposed = false;

  bool get listening => phase != VoicePhase.idle;

  Future<void> start() async {
    if (listening) return;
    final generation = ++_generation;
    phase = VoicePhase.preparing;
    partial = '';
    notice = null;
    _notify();
    try {
      final caps = await service.capabilities();
      if (generation != _generation) return;
      mode = caps.recognition;
      if (caps.recognition == RecognitionMode.unavailable) {
        return _fail(
          const VoiceNotice(
            'Aucune reconnaissance vocale en français sur ce téléphone. '
            'La saisie au clavier reste disponible.',
          ),
        );
      }
      final remote = caps.recognition == RecognitionMode.remote;
      if (remote && !await allowRemote()) {
        return _fail(
          VoiceNotice(
            'La reconnaissance sur l’appareil n’est pas disponible. Le service '
            '${caps.serviceName ?? 'du téléphone'} peut envoyer l’audio à son '
            'éditeur : activez-le dans Réglages si vous l’acceptez.',
            action: VoiceNoticeAction.openVoiceSettings,
          ),
        );
      }
      final permission = await service.requestMicrophone();
      if (generation != _generation) return;
      if (permission != MicPermission.granted) {
        return _fail(
          permission == MicPermission.permanentlyDenied
              ? const VoiceNotice(
                  'Le micro est refusé pour NEXORA. Autorisez-le dans les '
                  'réglages Android pour dicter.',
                  action: VoiceNoticeAction.openAppSettings,
                )
              : const VoiceNotice(
                  'Micro refusé : la dictée n’est pas possible. Vous pouvez '
                  'écrire votre message.',
                ),
        );
      }
      // Never listen while NEXORA speaks: its own voice would be transcribed.
      await stopSpeaking();
      if (generation != _generation) return;
      _active = generation;
      phase = VoicePhase.listening;
      _notify();
      await service.startListening(remote: remote);
    } on Object {
      if (generation == _generation) {
        _fail(const VoiceNotice('La dictée n’a pas pu démarrer. Réessayez.'));
      }
    }
  }

  /// Ends the utterance: the transcript goes to the message field.
  Future<void> stop() async {
    if (phase != VoicePhase.listening) return cancel();
    await service.stopListening();
  }

  /// Discards the utterance; nothing is put in the field.
  Future<void> cancel({String? reason}) async {
    if (!listening) return;
    _generation++;
    _active = null;
    phase = VoicePhase.idle;
    partial = '';
    notice = reason == null ? null : VoiceNotice(reason);
    _notify();
    await service.cancelListening();
  }

  /// Interruption (window closed, app in background): listening ends without
  /// keeping anything, and reading aloud stops.
  Future<void> interrupt() async {
    if (listening) {
      await cancel(reason: 'Écoute interrompue : rien n’a été ajouté.');
    }
    await stopSpeaking();
  }

  void dismissNotice() {
    notice = null;
    _notify();
  }

  Future<void> speak(String id, String text) async {
    if (listening) return;
    speakingId = id;
    _notify();
    await service.speak(id, plainText(text));
  }

  Future<void> stopSpeaking() async {
    if (speakingId == null) return;
    speakingId = null;
    _notify();
    await service.stopSpeaking();
  }

  void _onEvent(VoiceEvent event) {
    switch (event) {
      case SpeakingStarted(:final id):
        speakingId = id;
      case SpeakingEnded(:final id):
        if (speakingId == id) speakingId = null;
      case ListeningStarted():
        return;
      case PartialTranscript(:final text):
        if (_active != _generation) return;
        partial = text;
      case FinalTranscript(:final text):
        if (_active != _generation) return;
        _reset();
        if (text.trim().isEmpty) {
          notice = const VoiceNotice('Rien n’a été entendu. Réessayez.');
        } else {
          onTranscript(text.trim());
        }
      case ListeningFailed(:final code):
        if (_active != _generation) return;
        _reset();
        notice = VoiceNotice(_failure(code));
    }
    _notify();
  }

  void _reset() {
    _active = null;
    phase = VoicePhase.idle;
    partial = '';
  }

  void _fail(VoiceNotice value) {
    _reset();
    notice = value;
    _notify();
  }

  static String _failure(String code) => switch (code) {
    'no_match' || 'speech_timeout' => 'Rien n’a été compris. Réessayez.',
    'network' =>
      'Le service vocal n’a pas pu joindre son serveur. Rien n’a été ajouté.',
    'busy' => 'Le service vocal est occupé. Réessayez dans un instant.',
    'permission' => 'Le micro est refusé pour NEXORA.',
    'language' =>
      'Le français n’est pas disponible pour la reconnaissance sur ce '
          'téléphone.',
    'unavailable' => 'Le service vocal n’est plus disponible.',
    _ => 'La dictée s’est arrêtée. Rien n’a été ajouté.',
  };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription.cancel();
    if (listening) service.cancelListening();
    if (speakingId != null) service.stopSpeaking();
    super.dispose();
  }
}

/// Text read aloud: markup removed, long identifiers shortened.
String plainText(String text) => text
    .replaceAll('**', '')
    .replaceAll(
      RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'),
      '',
    )
    .replaceAll(RegExp(r'/api/v1/\S+'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

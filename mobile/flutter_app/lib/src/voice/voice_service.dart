import 'dart:async';

import 'package:flutter/services.dart';

/// Where speech is recognised.
enum RecognitionMode {
  /// On this phone: the audio never leaves it.
  onDevice,

  /// The phone's default recognition service, which may send the audio to its
  /// publisher. Used only after the user turned it on explicitly.
  remote,

  /// No recognition service usable for French.
  unavailable,
}

/// French speech synthesis on this phone.
enum SpeechOutput {
  /// A French voice that works offline.
  offline,

  /// Only voices that need the network: not used.
  networkOnly,

  /// No French voice, or no synthesis engine.
  unavailable,
}

class VoiceCapabilities {
  const VoiceCapabilities({
    required this.recognition,
    required this.output,
    this.serviceName,
    this.engineName,
  });

  final RecognitionMode recognition;
  final SpeechOutput output;

  /// Name of the phone's recognition service (shown before enabling remote).
  final String? serviceName;

  /// Name of the speech synthesis engine.
  final String? engineName;
}

enum MicPermission { granted, denied, permanentlyDenied }

sealed class VoiceEvent {
  const VoiceEvent();
}

/// Recognition is running: the microphone is open.
class ListeningStarted extends VoiceEvent {
  const ListeningStarted();
}

/// Words recognised so far (not final).
class PartialTranscript extends VoiceEvent {
  const PartialTranscript(this.text);
  final String text;
}

/// Final transcript of the utterance; the microphone is closed.
class FinalTranscript extends VoiceEvent {
  const FinalTranscript(this.text);
  final String text;
}

/// Recognition stopped without a result; the microphone is closed.
class ListeningFailed extends VoiceEvent {
  const ListeningFailed(this.code);

  /// `no_match`, `speech_timeout`, `network`, `busy`, `permission`,
  /// `language`, `audio`, `server`, `client`, `unavailable`.
  final String code;
}

class SpeakingStarted extends VoiceEvent {
  const SpeakingStarted(this.id);
  final String id;
}

/// Reading finished, was stopped, or failed.
class SpeakingEnded extends VoiceEvent {
  const SpeakingEnded(this.id);
  final String id;
}

/// Speech recognition and synthesis provided by the phone. One utterance at a
/// time, started by a tap: no continuous listening, no background recording,
/// no audio file. Only the recognised text reaches NEXORA.
abstract class VoiceService {
  Future<VoiceCapabilities> capabilities();

  /// Asks Android for the microphone the first time; explains afterwards.
  Future<MicPermission> requestMicrophone();

  /// Starts one utterance; [remote] uses the phone's default service
  /// ([RecognitionMode.remote]), otherwise only on-device recognition.
  Future<void> startListening({required bool remote});

  /// Stops listening and delivers the transcript heard so far.
  Future<void> stopListening();

  /// Stops listening and discards everything.
  Future<void> cancelListening();

  Future<void> speak(String id, String text);
  Future<void> stopSpeaking();

  /// Opens NEXORA's system settings (microphone allowed again by the user).
  Future<void> openAppSettings();

  Stream<VoiceEvent> get events;
}

/// Android implementation (`VoiceBridge.kt`), one per Flutter engine.
class NativeVoiceService implements VoiceService {
  static const _methods = MethodChannel('app.nexora/voice');
  static const _events = EventChannel('app.nexora/voice/events');

  Stream<VoiceEvent>? _stream;

  @override
  Stream<VoiceEvent> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map((raw) => _event(Map<String, dynamic>.from(raw as Map)))
      .where((event) => event != null)
      .cast<VoiceEvent>()
      .asBroadcastStream();

  static VoiceEvent? _event(Map<String, dynamic> json) =>
      switch (json['type']) {
        'listening' => const ListeningStarted(),
        'partial' => PartialTranscript(json['text'] as String? ?? ''),
        'final' => FinalTranscript(json['text'] as String? ?? ''),
        'error' => ListeningFailed(json['code'] as String? ?? 'client'),
        'speak_start' => SpeakingStarted(json['id'] as String),
        'speak_end' => SpeakingEnded(json['id'] as String),
        _ => null,
      };

  @override
  Future<VoiceCapabilities> capabilities() async {
    final raw = Map<String, dynamic>.from(
      await _methods.invokeMethod<Map>('capabilities') ?? const {},
    );
    return VoiceCapabilities(
      recognition: switch (raw['recognition']) {
        'on_device' => RecognitionMode.onDevice,
        'remote' => RecognitionMode.remote,
        _ => RecognitionMode.unavailable,
      },
      output: switch (raw['output']) {
        'offline' => SpeechOutput.offline,
        'network_only' => SpeechOutput.networkOnly,
        _ => SpeechOutput.unavailable,
      },
      serviceName: raw['service'] as String?,
      engineName: raw['engine'] as String?,
    );
  }

  @override
  Future<MicPermission> requestMicrophone() async =>
      switch (await _methods.invokeMethod<String>('requestMicrophone')) {
        'granted' => MicPermission.granted,
        'permanently_denied' => MicPermission.permanentlyDenied,
        _ => MicPermission.denied,
      };

  @override
  Future<void> startListening({required bool remote}) {
    events; // Subscribe before the first event can arrive.
    return _methods.invokeMethod('startListening', {'remote': remote});
  }

  @override
  Future<void> stopListening() => _methods.invokeMethod('stopListening');

  @override
  Future<void> cancelListening() => _methods.invokeMethod('cancelListening');

  @override
  Future<void> speak(String id, String text) {
    events;
    return _methods.invokeMethod('speak', {'id': id, 'text': text});
  }

  @override
  Future<void> stopSpeaking() => _methods.invokeMethod('stopSpeaking');

  @override
  Future<void> openAppSettings() => _methods.invokeMethod('openAppSettings');
}

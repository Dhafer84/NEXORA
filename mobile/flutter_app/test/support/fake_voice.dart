// Simulated phone voice services and bubble: no microphone, no audio, no
// Android. Tests decide what the "phone" answers and push recognition events.

import 'dart:async';

import 'package:nexora/src/bubble/bubble_service.dart';
import 'package:nexora/src/voice/voice_service.dart';

class FakeVoice implements VoiceService {
  FakeVoice({
    this.recognition = RecognitionMode.onDevice,
    this.output = SpeechOutput.offline,
    this.permission = MicPermission.granted,
  });

  RecognitionMode recognition;
  SpeechOutput output;
  MicPermission permission;

  /// Every call, in order: `start(remote: false)`, `stop`, `cancel`,
  /// `speak:<id>`, `stopSpeaking`, `permission`, `settings`.
  final List<String> calls = [];
  final List<String> spoken = [];
  final _events = StreamController<VoiceEvent>.broadcast(sync: true);

  void emit(VoiceEvent event) => _events.add(event);

  @override
  Stream<VoiceEvent> get events => _events.stream;

  @override
  Future<VoiceCapabilities> capabilities() async => VoiceCapabilities(
    recognition: recognition,
    output: output,
    serviceName: 'Service vocal de test',
    engineName: 'Synthèse de test',
  );

  @override
  Future<MicPermission> requestMicrophone() async {
    calls.add('permission');
    return permission;
  }

  @override
  Future<void> startListening({required bool remote}) async {
    calls.add('start(remote: $remote)');
    emit(const ListeningStarted());
  }

  @override
  Future<void> stopListening() async => calls.add('stop');

  @override
  Future<void> cancelListening() async => calls.add('cancel');

  @override
  Future<void> speak(String id, String text) async {
    calls.add('speak:$id');
    spoken.add(text);
    emit(SpeakingStarted(id));
  }

  @override
  Future<void> stopSpeaking() async => calls.add('stopSpeaking');

  @override
  Future<void> openAppSettings() async => calls.add('settings');

  bool get listened => calls.any((call) => call.startsWith('start'));
}

class FakeBubble implements BubbleService {
  FakeBubble({
    this.availability = BubbleAvailability.allowed,
    this.conversation,
  });

  BubbleAvailability availability;

  /// Conversation the bubble was opened for (mini-chat side).
  String? conversation;
  bool shown = false;
  final List<String> calls = [];
  final _launches = StreamController<LaunchRequest>.broadcast(sync: true);

  void launch(LaunchRequest request) => _launches.add(request);

  @override
  Future<BubbleStatus> status() async =>
      BubbleStatus(availability: availability, shown: shown);

  @override
  Future<String?> show({
    required String conversationId,
    required String title,
    bool expand = false,
  }) async {
    calls.add('show:$conversationId');
    if (availability == BubbleAvailability.unsupported) {
      return 'Les bulles demandent Android 11 ou plus.';
    }
    shown = true;
    return null;
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
    shown = false;
  }

  @override
  Future<void> openBubbleSettings() async => calls.add('settings');

  @override
  Future<bool> pinShortcut() async {
    calls.add('pin');
    return true;
  }

  @override
  Future<String?> bubbleConversation() async => conversation;

  @override
  Future<void> openFullScreen({
    required String conversationId,
    String? approvalId,
  }) async => calls.add('fullScreen:$conversationId:${approvalId ?? '-'}');

  @override
  Stream<LaunchRequest> get launches => _launches.stream;
}

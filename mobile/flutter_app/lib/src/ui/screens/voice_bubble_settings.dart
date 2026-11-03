import 'dart:async';

import 'package:flutter/material.dart';

import '../../bubble/bubble_service.dart';
import '../../state/app_state.dart';
import '../../voice/voice_service.dart';
import '../theme.dart';
import '../widgets/states.dart';

/// Dictation and reading aloud: what the phone offers and the user's choices.
class VoiceSettings extends StatefulWidget {
  const VoiceSettings({super.key});

  @override
  State<VoiceSettings> createState() => _VoiceSettingsState();
}

class _VoiceSettingsState extends State<VoiceSettings> {
  VoiceCapabilities? _caps;
  bool _remote = false;
  bool _autoRead = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final state = AppScope.read(context);
    try {
      final caps = await state.voice!.capabilities();
      final remote = await state.allowRemoteRecognition();
      final autoRead = await state.autoRead();
      if (mounted) {
        setState(() {
          _caps = caps;
          _remote = remote;
          _autoRead = autoRead;
        });
      }
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _setRemote(bool value) async {
    if (value) {
      final caps = _caps!;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Reconnaissance en ligne'),
          content: Text(
            'Le service ${caps.serviceName ?? 'de reconnaissance du téléphone'} '
            'peut envoyer l’enregistrement de votre voix à son éditeur pour le '
            'transcrire. NEXORA ne reçoit que le texte, et seulement quand vous '
            'l’envoyez. Activer ?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Activer'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    await AppScope.read(context).setAllowRemoteRecognition(value);
    if (mounted) setState(() => _remote = value);
  }

  Future<void> _setAutoRead(bool value) async {
    await AppScope.read(context).setAutoRead(value);
    if (mounted) setState(() => _autoRead = value);
  }

  @override
  Widget build(BuildContext context) {
    final caps = _caps;
    if (_failed) {
      return const _Section(
        title: 'Voix',
        children: [
          ListTile(
            leading: Icon(Icons.mic_off_rounded),
            title: Text('Services vocaux du téléphone injoignables'),
          ),
        ],
      );
    }
    if (caps == null) {
      return const _Section(
        title: 'Voix',
        children: [LinearProgressIndicator()],
      );
    }
    final (recognitionText, recognitionTone) = switch (caps.recognition) {
      RecognitionMode.onDevice => (
        'Sur l’appareil : l’audio ne quitte pas le téléphone.',
        'ok',
      ),
      RecognitionMode.remote => (
        'Pas de reconnaissance française sur l’appareil. Service du téléphone : '
            '${caps.serviceName ?? 'inconnu'}, qui peut envoyer l’audio à son '
            'éditeur.',
        'warning',
      ),
      RecognitionMode.unavailable => (
        'Aucun service de reconnaissance vocale en français sur ce téléphone. '
            'La saisie au clavier reste disponible.',
        'neutral',
      ),
    };
    final outputText = switch (caps.output) {
      SpeechOutput.offline =>
        'Voix française hors ligne${caps.engineName == null ? '' : ' (${caps.engineName})'}.',
      SpeechOutput.networkOnly =>
        'La voix française exige le réseau de son éditeur : la lecture n’est '
            'pas utilisée.',
      SpeechOutput.unavailable =>
        'Aucune voix française installée (réglages Android, Synthèse vocale).',
    };
    return _Section(
      title: 'Voix',
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.mic_rounded),
          title: const Text('Dictée'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Text(recognitionText),
          ),
          trailing: StatusChip(
            label: switch (caps.recognition) {
              RecognitionMode.onDevice => 'Locale',
              RecognitionMode.remote => 'En ligne',
              RecognitionMode.unavailable => 'Indisponible',
            },
            tone: recognitionTone,
          ),
        ),
        if (caps.recognition == RecognitionMode.remote)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _remote,
            onChanged: _setRemote,
            title: const Text('Autoriser la reconnaissance en ligne'),
            subtitle: const Text(
              'Désactivée par défaut. L’audio part chez l’éditeur du service ; '
              'NEXORA ne reçoit que le texte que vous envoyez.',
            ),
          ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.volume_up_rounded),
          title: const Text('Lecture des réponses'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Text(outputText),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _autoRead,
          onChanged: caps.output == SpeechOutput.offline ? _setAutoRead : null,
          title: const Text('Lire les réponses automatiquement'),
          subtitle: const Text(
            'Désactivée par défaut. Le bouton « Écouter » reste disponible.',
          ),
        ),
      ],
    );
  }
}

/// The mini-chat bubble: switch, what Android allows, fallback shortcut.
class BubbleSettings extends StatefulWidget {
  const BubbleSettings({super.key});

  @override
  State<BubbleSettings> createState() => _BubbleSettingsState();
}

class _BubbleSettingsState extends State<BubbleSettings>
    with WidgetsBindingObserver {
  BubbleStatus? _status;
  bool _enabled = false;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the Android bubble settings.
    if (state == AppLifecycleState.resumed) unawaited(_load());
  }

  Future<void> _load() async {
    final state = AppScope.read(context);
    try {
      final status = await state.bubble!.status();
      final enabled = await state.bubbleEnabled();
      if (mounted) {
        setState(() {
          _status = status;
          _enabled = enabled;
        });
      }
    } on Object {
      if (mounted) {
        setState(
          () => _status = const BubbleStatus(
            availability: BubbleAvailability.unsupported,
            shown: false,
          ),
        );
      }
    }
  }

  Future<void> _setEnabled(bool value) async {
    final state = AppScope.read(context);
    setState(() {
      _busy = true;
      _message = null;
    });
    String? problem;
    if (value) {
      final conversation = await state.currentConversation();
      if (conversation == null) {
        problem = 'Ouvrez d’abord une discussion dans Messages.';
      } else {
        problem = await state.bubble!.show(
          conversationId: conversation,
          title: 'NEXORA',
        );
      }
    } else {
      await state.bubble!.hide();
    }
    await state.setBubbleEnabled(value && problem == null);
    await _load();
    if (mounted) {
      setState(() {
        _busy = false;
        _message = problem;
      });
    }
  }

  Future<void> _pin() async {
    final pinned = await AppScope.read(context).bubble!.pinShortcut();
    if (mounted) {
      setState(
        () => _message = pinned
            ? 'Demande envoyée : confirmez l’ajout sur l’écran d’accueil.'
            : 'Votre écran d’accueil ne permet pas d’épingler un raccourci. '
                  'Un appui long sur l’icône NEXORA propose « Chat NEXORA ».',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (status == null) {
      return const _Section(
        title: 'Bulle',
        children: [LinearProgressIndicator()],
      );
    }
    final availability = switch (status.availability) {
      BubbleAvailability.allowed => 'Bulles autorisées pour NEXORA.',
      BubbleAvailability.selected =>
        'Bulles autorisées pour les conversations choisies : touchez l’icône '
            'de bulle de la notification NEXORA si elle n’apparaît pas.',
      BubbleAvailability.blocked => 'Bulles désactivées sur ce téléphone.',
      BubbleAvailability.notAllowed =>
        'Bulles pas encore autorisées pour NEXORA : touchez l’icône de bulle '
            'de la notification NEXORA, ou ouvrez Réglages des bulles.',
      BubbleAvailability.notificationsBlocked =>
        'Notifications refusées : Android ne peut pas afficher la bulle.',
      BubbleAvailability.unsupported =>
        'Ce téléphone ne propose pas les bulles de conversation (Android 11 '
            'ou plus).',
    };
    final canTry = status.availability != BubbleAvailability.unsupported;
    return _Section(
      title: 'Bulle',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.bubble_chart_rounded),
          value: _enabled && status.shown,
          onChanged: _busy || !canTry ? null : _setEnabled,
          title: const Text('Bulle NEXORA'),
          subtitle: Text(
            'Mini-chat ouvert par-dessus les autres applications. '
            '$availability',
          ),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s),
            child: NoticeBar(tone: 'neutral', message: _message!),
          ),
        Wrap(
          spacing: Space.m,
          runSpacing: Space.s,
          children: [
            if (canTry)
              OutlinedButton.icon(
                onPressed: AppScope.read(context).bubble!.openBubbleSettings,
                icon: const Icon(Icons.settings_rounded),
                label: const Text('Réglages des bulles'),
              ),
            OutlinedButton.icon(
              onPressed: _pin,
              icon: const Icon(Icons.add_to_home_screen_rounded),
              label: const Text('Raccourci vers le chat'),
            ),
          ],
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: Space.s),
        ...children,
      ],
    ),
  );
}

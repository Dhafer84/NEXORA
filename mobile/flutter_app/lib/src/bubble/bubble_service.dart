import 'dart:async';

import 'package:flutter/services.dart';

/// What Android allows for the NEXORA conversation bubble.
enum BubbleAvailability {
  /// Android 10 or older: no conversation bubbles.
  unsupported,

  /// Notifications refused: no bubble can be shown.
  notificationsBlocked,

  /// Bubbles turned off for the whole phone.
  blocked,

  /// Nothing of NEXORA may bubble yet: Android's default for a new app. The
  /// user allows it from the bubble button of the notification or the
  /// bubble settings.
  notAllowed,

  /// Allowed for the conversations the user picks: the first bubble may need
  /// a tap on the bubble button of its notification.
  selected,

  allowed,
}

class BubbleStatus {
  const BubbleStatus({required this.availability, required this.shown});

  final BubbleAvailability availability;

  /// A NEXORA bubble (or its notification) is currently posted.
  final bool shown;

  bool get usable =>
      availability == BubbleAvailability.allowed ||
      availability == BubbleAvailability.selected;
}

/// Request from Android to open a screen of the full app.
class LaunchRequest {
  const LaunchRequest({this.conversationId, this.approvalId});

  final String? conversationId;
  final String? approvalId;
}

/// Native conversation bubble (`BubbleBridge.kt`) and the launcher shortcut
/// that replaces it when Android does not show bubbles.
abstract class BubbleService {
  Future<BubbleStatus> status();

  /// Posts (or updates) the bubble of [conversationId]. Returns a French
  /// message when it cannot be shown.
  Future<String?> show({
    required String conversationId,
    required String title,
    bool expand = false,
  });

  Future<void> hide();
  Future<void> openBubbleSettings();

  /// Asks the launcher to pin a "Chat NEXORA" shortcut (the launcher confirms).
  Future<bool> pinShortcut();

  /// Mini-chat only: conversation the bubble was opened for.
  Future<String?> bubbleConversation();

  /// Mini-chat only: opens the full app on [conversationId] (and an approval),
  /// then collapses the bubble.
  Future<void> openFullScreen({
    required String conversationId,
    String? approvalId,
  });

  /// Full app only: screens requested by a shortcut or by the mini-chat.
  Stream<LaunchRequest> get launches;
}

class NativeBubbleService implements BubbleService {
  NativeBubbleService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'launch') {
        _launches.add(_request(call.arguments));
      }
    });
  }

  static const _channel = MethodChannel('app.nexora/bubble');
  final _launches = StreamController<LaunchRequest>.broadcast();
  bool _initialRead = false;

  static LaunchRequest _request(Object? raw) {
    final json = raw is Map ? Map<String, dynamic>.from(raw) : const {};
    return LaunchRequest(
      conversationId: json['conversation'] as String?,
      approvalId: json['approval'] as String?,
    );
  }

  @override
  Future<BubbleStatus> status() async {
    final raw = Map<String, dynamic>.from(
      await _channel.invokeMethod<Map>('status') ?? const {},
    );
    return BubbleStatus(
      availability: switch (raw['availability']) {
        'allowed' => BubbleAvailability.allowed,
        'selected' => BubbleAvailability.selected,
        'blocked' => BubbleAvailability.blocked,
        'not_allowed' => BubbleAvailability.notAllowed,
        'notifications_blocked' => BubbleAvailability.notificationsBlocked,
        _ => BubbleAvailability.unsupported,
      },
      shown: raw['shown'] as bool? ?? false,
    );
  }

  @override
  Future<String?> show({
    required String conversationId,
    required String title,
    bool expand = false,
  }) => _channel.invokeMethod<String>('show', {
    'conversation': conversationId,
    'title': title,
    'expand': expand,
  });

  @override
  Future<void> hide() => _channel.invokeMethod('hide');

  @override
  Future<void> openBubbleSettings() => _channel.invokeMethod('openSettings');

  @override
  Future<bool> pinShortcut() async =>
      await _channel.invokeMethod<bool>('pinShortcut') ?? false;

  @override
  Future<String?> bubbleConversation() =>
      _channel.invokeMethod<String>('bubbleConversation');

  @override
  Future<void> openFullScreen({
    required String conversationId,
    String? approvalId,
  }) => _channel.invokeMethod('openFullScreen', {
    'conversation': conversationId,
    'approval': approvalId,
  });

  @override
  Stream<LaunchRequest> get launches {
    if (!_initialRead) {
      _initialRead = true;
      // The intent that started the app, delivered once.
      _channel.invokeMethod<Map>('initialLaunch').then((raw) {
        if (raw != null) _launches.add(_request(raw));
      });
    }
    return _launches.stream;
  }
}

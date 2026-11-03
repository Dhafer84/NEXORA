import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../api/api_error.dart';
import '../api/models.dart';
import '../storage/credentials_store.dart';
import 'alert_sync.dart';

const _taskName = 'nexora.alerts';
const _enabledKey = 'nexora.alerts.enabled';
const _cursorKey = 'nexora.alerts.cursor';
const _channelId = 'nexora_alerts';

/// State of phone alerts as shown in the app.
class AlertsStatus {
  const AlertsStatus({required this.enabled, required this.permitted});

  /// The user turned alerts on in NEXORA.
  final bool enabled;

  /// Android lets NEXORA post notifications.
  final bool permitted;
}

/// Phone side of server alerts: permission, background worker, cursor.
abstract class AlertsController {
  Future<AlertsStatus> status();

  /// Returns a message when alerts could not be turned on.
  Future<String?> enable();
  Future<void> disable();
}

/// Uncached preferences: the worker and the app run in separate isolates.
class PreferencesCursorStore implements CursorStore {
  PreferencesCursorStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<SyncCursor?> read() async {
    final raw = await _preferences.getString(_cursorKey);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return SyncCursor(json['base_url'] as String, json['last_id'] as int);
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(SyncCursor cursor) => _preferences.setString(
    _cursorKey,
    jsonEncode({'base_url': cursor.baseUrl, 'last_id': cursor.lastId}),
  );
}

class LocalAlertPresenter implements AlertPresenter {
  LocalAlertPresenter(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<void> show(ServerNotification notification) => _plugin.show(
    id: notification.id,
    title: notification.title,
    body: notification.body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'Alertes du serveur',
        channelDescription: 'Seuils dépassés et vérifications impossibles',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.status,
        styleInformation: BigTextStyleInformation(notification.body),
        when: notification.createdAt.millisecondsSinceEpoch,
      ),
    ),
  );
}

Future<FlutterLocalNotificationsPlugin> _notifications() async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('ic_stat_nexora'),
    ),
  );
  return plugin;
}

AlertSync _sync(FlutterLocalNotificationsPlugin plugin) => AlertSync(
  credentials: SecureCredentialsStore(),
  cursors: PreferencesCursorStore(),
  presenter: LocalAlertPresenter(plugin),
);

/// Entry point of the Android worker, run even when NEXORA is closed.
@pragma('vm:entry-point')
void alertsDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await _sync(await _notifications()).run();
      return true;
    } on Object catch (error) {
      // Type only: messages may contain the server address.
      debugPrint('nexora_alerts_failed type=${error.runtimeType}');
      // Network or server down: the next periodic run retries from the cursor.
      return true;
    }
  });
}

/// Android WorkManager: one check every 15 minutes at best (system minimum),
/// with network, delayed by battery saving; survives app closing and reboots.
class WorkManagerAlerts implements AlertsController {
  WorkManagerAlerts._(this._plugin);

  static Future<WorkManagerAlerts> initialize() async {
    await Workmanager().initialize(alertsDispatcher);
    return WorkManagerAlerts._(await _notifications());
  }

  final FlutterLocalNotificationsPlugin _plugin;
  final _preferences = SharedPreferencesAsync();

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  @override
  Future<AlertsStatus> status() async => AlertsStatus(
    enabled: await _preferences.getBool(_enabledKey) ?? false,
    permitted: await _android?.areNotificationsEnabled() ?? false,
  );

  @override
  Future<String?> enable() async {
    final granted =
        await _android?.requestNotificationsPermission() ??
        await _android?.areNotificationsEnabled() ??
        false;
    if (!granted) {
      return 'Notifications refusées : autorisez-les pour NEXORA dans les '
          'paramètres Android, puis réessayez.';
    }
    try {
      await _sync(_plugin).prime();
    } on ApiError catch (error) {
      return 'Alertes non activées : ${error.message}';
    }
    await Workmanager().registerPeriodicTask(
      _taskName,
      _taskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
    await _preferences.setBool(_enabledKey, true);
    return null;
  }

  @override
  Future<void> disable() async {
    await Workmanager().cancelByUniqueName(_taskName);
    await _preferences.setBool(_enabledKey, false);
  }
}

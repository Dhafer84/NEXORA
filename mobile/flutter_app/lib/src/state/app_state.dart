import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../api/api_client.dart';
import '../alerts/background_alerts.dart';
import '../api/api_error.dart';
import '../files/file_access.dart';
import '../storage/credentials_store.dart';

typedef ApiFactory = NexoraApi Function(String baseUrl, String apiKey);

/// IANA name of the phone's time zone, e.g. `Europe/Paris`.
typedef TimezoneProvider = Future<String> Function();

NexoraApi defaultApiFactory(String baseUrl, String apiKey) =>
    NexoraApi(baseUrl: baseUrl, apiKey: apiKey, client: http.Client());

enum SetupState { loading, unconfigured, ready }

class ConnectionReport {
  const ConnectionReport.success()
    : ok = true,
      message = 'Connexion réussie : serveur joignable et clé acceptée.';
  const ConnectionReport.failure(this.message) : ok = false;

  final bool ok;
  final String message;
}

/// Application-wide state: credentials, API client and pending approvals badge.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState({
    required this.store,
    ApiFactory? apiFactory,
    this.pollInterval = const Duration(seconds: 30),
    this.alerts,
    this.files,
    this.folderMemory,
    TimezoneProvider? timezone,
  }) : _apiFactory = apiFactory ?? defaultApiFactory,
       timezone = timezone ?? (() async => 'Europe/Paris');

  final CredentialsStore store;

  /// Phone notifications for server alerts; null where unsupported (tests).
  final AlertsController? alerts;

  /// Local file organisation in one user-picked folder; null where unsupported.
  final FileAccess? files;
  final FolderMemory? folderMemory;
  final TimezoneProvider timezone;
  final ApiFactory _apiFactory;
  final Duration pollInterval;

  SetupState setup = SetupState.loading;
  String? baseUrl;
  bool hasKey = false;
  NexoraApi? _api;

  int? pendingApprovals;
  String? pendingError;
  Timer? _timer;
  bool _disposed = false;

  NexoraApi get api => _api ?? (throw StateError('Backend non configuré'));
  bool get configured => _api != null;

  Future<void> load() async {
    baseUrl = await store.readBaseUrl();
    hasKey = await store.hasApiKey();
    final credentials = await store.read();
    _replaceApi(credentials);
    setup = credentials == null ? SetupState.unconfigured : SetupState.ready;
    _notify();
    if (configured) {
      _startPolling();
      unawaited(refreshPending());
    }
  }

  /// Checks address, HTTPS chain and key without saving anything.
  Future<ConnectionReport> testConnection(String url, String key) async {
    final problem = checkBaseUrl(url);
    if (problem != null) return ConnectionReport.failure(problem);
    final api = _apiFactory(normalizeBaseUrl(url), key);
    try {
      // Public probe first: separates network/TLS problems from a refused key.
      await api.live();
      await api.authCheck();
      return const ConnectionReport.success();
    } on ApiError catch (error) {
      if (error.kind == ApiErrorKind.unauthorized) {
        return const ConnectionReport.failure(
          'Le serveur répond, mais la clé personnelle est refusée.',
        );
      }
      return ConnectionReport.failure(error.message);
    } finally {
      api.close();
    }
  }

  /// True when [url] is the address the stored key was entered for.
  bool keyBelongsTo(String url) =>
      hasKey && baseUrl != null && normalizeBaseUrl(url) == baseUrl;

  /// The stored key, only for the address it belongs to; never for another one.
  Future<String?> storedKeyFor(String url) async {
    if (!keyBelongsTo(url)) return null;
    return (await store.read())?.apiKey;
  }

  /// Saves the address and, when given, a new key. Without [newKey] the stored
  /// key is kept only for the same address: a new address requires its key.
  /// Returns a message when nothing was saved.
  Future<String?> save(String url, String? newKey) async {
    final key = newKey?.trim() ?? '';
    if (key.isEmpty && !keyBelongsTo(url)) return newAddressNeedsKey;
    try {
      await store.save(normalizeBaseUrl(url), apiKey: key.isEmpty ? null : key);
    } on Object {
      // Single-entry write: the stored pair is still the previous one.
      await load();
      return saveFailed;
    }
    await load();
    return null;
  }

  static const saveFailed =
      'Enregistrement impossible : les réglages précédents sont conservés. '
      'Réessayez.';

  static const newAddressNeedsKey =
      'Saisissez la clé personnelle de ce serveur : la clé enregistrée reste '
      'liée à l’adresse précédente et n’est jamais envoyée à une autre.';

  Future<void> deleteKey() async {
    // Drop the client first: no request may use the key while it is deleted.
    _stopPolling();
    _replaceApi(null);
    pendingApprovals = null;
    try {
      await store.deleteApiKey();
    } finally {
      await load();
    }
  }

  Future<void> refreshPending() async {
    final api = _api;
    if (api == null) return;
    try {
      final pending = await api.approvals(status: 'pending', limit: 100);
      // Ignore an answer that arrives after the address or key changed.
      if (!identical(api, _api)) return;
      pendingApprovals = pending.length;
      pendingError = null;
    } on ApiError catch (error) {
      if (!identical(api, _api)) return;
      pendingError = error.message;
    }
    _notify();
  }

  void _replaceApi(Credentials? credentials) {
    _api?.close();
    _api = credentials == null
        ? null
        : _apiFactory(credentials.baseUrl, credentials.apiKey);
  }

  // Foreground polling only: no background service, no push (see QUESTIONS_EN_ATTENTE).
  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => refreshPending());
  }

  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && configured) {
      _startPolling();
      unawaited(refreshPending());
    } else if (state == AppLifecycleState.paused) {
      _stopPolling();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopPolling();
    _api?.close();
    super.dispose();
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

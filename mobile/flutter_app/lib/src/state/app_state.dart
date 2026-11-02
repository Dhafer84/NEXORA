import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../storage/credentials_store.dart';

typedef ApiFactory = NexoraApi Function(String baseUrl, String apiKey);

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
  }) : _apiFactory = apiFactory ?? defaultApiFactory;

  final CredentialsStore store;
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

  /// Saves the address and, when given, a new key. An empty [newKey] keeps the stored one.
  Future<void> save(String url, String? newKey) async {
    await store.saveBaseUrl(normalizeBaseUrl(url));
    if (newKey != null && newKey.isNotEmpty) await store.saveApiKey(newKey);
    await load();
  }

  Future<void> deleteKey() async {
    await store.deleteApiKey();
    _stopPolling();
    pendingApprovals = null;
    await load();
  }

  Future<void> refreshPending() async {
    final api = _api;
    if (api == null) return;
    try {
      final pending = await api.approvals(status: 'pending', limit: 100);
      pendingApprovals = pending.length;
      pendingError = null;
    } on ApiError catch (error) {
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

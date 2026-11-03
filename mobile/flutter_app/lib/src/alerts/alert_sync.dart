import '../api/models.dart';
import '../state/app_state.dart';
import '../storage/credentials_store.dart';

/// Last server notification shown on this phone, for one backend address.
class SyncCursor {
  const SyncCursor(this.baseUrl, this.lastId);

  final String baseUrl;
  final int lastId;
}

abstract class CursorStore {
  Future<SyncCursor?> read();
  Future<void> write(SyncCursor cursor);
}

/// Shows one server notification on the phone. The server id is the Android
/// notification id: showing it twice replaces it instead of duplicating it.
abstract class AlertPresenter {
  Future<void> show(ServerNotification notification);
}

/// Fetches the notifications raised on the server since the last sync and shows
/// them. Runs in the background worker, without the user interface.
class AlertSync {
  AlertSync({
    required this.credentials,
    required this.cursors,
    required this.presenter,
    ApiFactory? apiFactory,
  }) : _apiFactory = apiFactory ?? defaultApiFactory;

  final CredentialsStore credentials;
  final CursorStore cursors;
  final AlertPresenter presenter;
  final ApiFactory _apiFactory;

  static const pageSize = 20;
  static const maxPages = 5;

  /// Starts from the server's latest notification: enabling alerts never
  /// replays the old ones.
  Future<void> prime() async {
    final stored = await credentials.read();
    if (stored == null) return;
    final api = _apiFactory(stored.baseUrl, stored.apiKey);
    try {
      final page = await api.notifications(limit: 1);
      await cursors.write(SyncCursor(stored.baseUrl, page.latestId));
    } finally {
      api.close();
    }
  }

  /// Returns the number of notifications shown. Throws [ApiError] when the
  /// server cannot be reached; the next run retries from the same cursor.
  Future<int> run() async {
    final stored = await credentials.read();
    if (stored == null) return 0;
    final cursor = await cursors.read();
    if (cursor == null || cursor.baseUrl != stored.baseUrl) {
      // New phone or new server: start from now.
      await prime();
      return 0;
    }
    final api = _apiFactory(stored.baseUrl, stored.apiKey);
    var after = cursor.lastId;
    var shown = 0;
    try {
      for (var page = 0; page < maxPages; page++) {
        final result = await api.notifications(afterId: after, limit: pageSize);
        if (result.latestId < cursor.lastId) {
          // The server database was reset: follow its numbering.
          await cursors.write(SyncCursor(stored.baseUrl, result.latestId));
          return shown;
        }
        for (final notification in result.items) {
          await presenter.show(notification);
          after = notification.id;
          shown++;
          // Saved after each one: an interruption shows at most this one again,
          // under the same id, so it replaces itself.
          await cursors.write(SyncCursor(stored.baseUrl, after));
        }
        if (result.items.length < pageSize) break;
      }
    } finally {
      api.close();
    }
    return shown;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'models.dart';

/// Short delay for reads and decisions; long delay for an assistant turn.
/// The backend caps a turn at 90 s by default; the margin covers the network.
const readTimeout = Duration(seconds: 15);
const turnTimeout = Duration(seconds: 150);

/// Validates a backend address. HTTPS is mandatory; plain HTTP is only accepted
/// for the emulator or local loopback in debug builds (local test backend).
String? checkBaseUrl(String input, {bool allowLocalHttp = kDebugMode}) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return 'Adresse invalide. Exemple : https://mon-serveur.tailnet.ts.net:8101';
  }
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
    return 'L’adresse ne doit contenir ni identifiants, ni paramètres.';
  }
  if (uri.path.isNotEmpty && uri.path != '/') {
    return 'Indiquez seulement l’adresse du serveur, sans chemin.';
  }
  const local = {'10.0.2.2', '127.0.0.1', 'localhost'};
  if (uri.scheme == 'https') return null;
  if (uri.scheme == 'http' && allowLocalHttp && local.contains(uri.host)) {
    return null;
  }
  return 'HTTPS obligatoire : l’adresse doit commencer par https://';
}

String normalizeBaseUrl(String input) {
  final value = input.trim();
  return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
}

/// Single entry point to the NEXORA backend: authentication, delays and errors.
class NexoraApi {
  NexoraApi({
    required String baseUrl,
    required String apiKey,
    http.Client? client,
  }) : _base = normalizeBaseUrl(baseUrl),
       _apiKey = apiKey,
       _client = client ?? http.Client();

  final String _base;
  final String _apiKey;
  final http.Client _client;

  void close() => _client.close();

  // ----- Health and server ---------------------------------------------------

  /// Public liveness probe: proves the address and the HTTPS chain, without the key.
  Future<void> live() async {
    await _send('GET', '/health/live', authenticated: false);
  }

  Future<void> authCheck() async {
    await _send('GET', '/api/v1/auth/check');
  }

  Future<void> ready() async {
    await _send('GET', '/health/ready');
  }

  Future<ServerMetrics> metrics() =>
      _object('GET', '/api/v1/server/metrics', ServerMetrics.fromJson);

  Future<AiStatus> aiStatus() =>
      _object('GET', '/api/v1/ai/status', AiStatus.fromJson);

  // ----- Conversations -------------------------------------------------------

  Future<List<Conversation>> conversations({int limit = 50}) =>
      _list('/api/v1/conversations?limit=$limit', Conversation.fromJson);

  Future<Conversation> createConversation(String title) => _object(
    'POST',
    '/api/v1/conversations',
    Conversation.fromJson,
    body: {'title': title},
  );

  Future<ConversationDetail> conversation(String id, {int limit = 200}) =>
      _object(
        'GET',
        '/api/v1/conversations/$id?limit=$limit',
        ConversationDetail.fromJson,
      );

  /// One assistant turn. Never retried automatically: on a timeout the server may
  /// already have stored and processed the message ([ApiError.outcomeUnknown]).
  Future<TurnResult> sendMessage(String conversationId, String content) =>
      _object(
        'POST',
        '/api/v1/conversations/$conversationId/messages',
        TurnResult.fromJson,
        body: {'content': content},
        timeout: turnTimeout,
      );

  // ----- Approvals -----------------------------------------------------------

  Future<List<Approval>> approvals({String? status, int limit = 50}) {
    final filter = status == null ? '' : '&status=$status';
    return _list('/api/v1/approvals?limit=$limit$filter', Approval.fromJson);
  }

  Future<Approval> approval(String id) =>
      _object('GET', '/api/v1/approvals/$id', Approval.fromJson);

  /// Records the decision only. The hash proves which parameters were shown.
  Future<Approval> approve(Approval approval) => _object(
    'POST',
    '/api/v1/approvals/${approval.id}/approve',
    Approval.fromJson,
    body: {'arguments_hash': approval.argumentsHash},
  );

  Future<Approval> reject(String id, {String? reason}) => _object(
    'POST',
    '/api/v1/approvals/$id/reject',
    Approval.fromJson,
    body: {
      if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
    },
  );

  /// Runs an approved action with its exact stored parameters. Safe to repeat:
  /// the server returns the stored outcome with `replayed: true`.
  Future<ToolExecution> execute(Approval approval) => _object(
    'POST',
    '/api/v1/approvals/${approval.id}/execute',
    ToolExecution.fromJson,
    body: {'arguments': approval.arguments},
    timeout: turnTimeout,
  );

  // ----- Automations ---------------------------------------------------------

  Future<List<Automation>> automations() =>
      _list('/api/v1/automations', Automation.fromJson);

  Future<Automation> automation(String id) =>
      _object('GET', '/api/v1/automations/$id', Automation.fromJson);

  Future<Automation> createAutomation({
    required String name,
    required double thresholdPercent,
    required int intervalMinutes,
    required String timezone,
    bool enabled = true,
  }) => _object(
    'POST',
    '/api/v1/automations',
    Automation.fromJson,
    body: {
      'name': name,
      'kind': 'disk_check',
      'threshold_percent': thresholdPercent,
      'interval_minutes': intervalMinutes,
      'timezone': timezone,
      'enabled': enabled,
    },
  );

  /// Sends only the given fields. Same values twice give the same result.
  Future<Automation> updateAutomation(
    String id, {
    String? name,
    double? thresholdPercent,
    int? intervalMinutes,
    String? timezone,
    bool? enabled,
  }) => _object(
    'PATCH',
    '/api/v1/automations/$id',
    Automation.fromJson,
    body: {
      'name': ?name,
      'threshold_percent': ?thresholdPercent,
      'interval_minutes': ?intervalMinutes,
      'timezone': ?timezone,
      'enabled': ?enabled,
    },
  );

  Future<void> deleteAutomation(String id) async {
    await _send('DELETE', '/api/v1/automations/$id');
  }

  /// Manual check. Not retried automatically: a timeout leaves the outcome
  /// unknown, and the history tells whether it ran.
  Future<AutomationRun> runAutomation(String id) =>
      _object('POST', '/api/v1/automations/$id/run', AutomationRun.fromJson);

  Future<List<AutomationRun>> automationRuns(String id, {int limit = 50}) =>
      _list(
        '/api/v1/automations/$id/runs?limit=$limit',
        AutomationRun.fromJson,
      );

  Future<NotificationPage> notifications({int afterId = 0, int limit = 20}) =>
      _object(
        'GET',
        '/api/v1/notifications?after_id=$afterId&limit=$limit',
        NotificationPage.fromJson,
      );

  /// Allow-listed repositories only; read-only on the server side.
  Future<GitHubReport> github() =>
      _object('GET', '/api/v1/github', GitHubReport.fromJson);

  // ----- Transport -----------------------------------------------------------

  Future<T> _object<T>(
    String method,
    String path,
    T Function(Map<String, dynamic> json) parse, {
    Object? body,
    Duration timeout = readTimeout,
  }) async {
    final decoded = await _send(method, path, body: body, timeout: timeout);
    return _parse(
      method,
      () => parse(Map<String, dynamic>.from(decoded as Map)),
    );
  }

  Future<List<T>> _list<T>(
    String path,
    T Function(Map<String, dynamic> json) parse,
  ) async {
    final decoded = await _send('GET', path);
    return _parse('GET', () {
      return [
        for (final item in decoded as List)
          parse(Map<String, dynamic>.from(item as Map)),
      ];
    });
  }

  /// Any response outside the documented contract (wrong type, missing field,
  /// `null` item, bad date) becomes a readable [ApiError], never a raw TypeError.
  /// For a write, the server answered 2xx: the request was probably processed.
  static T _parse<T>(String method, T Function() build) {
    try {
      return build();
    } on Object {
      throw _badResponse(method);
    }
  }

  static ApiError _badResponse(String method) => method == 'GET'
      ? const ApiError(
          ApiErrorKind.badResponse,
          'Réponse inattendue du serveur.',
        )
      : const ApiError(
          ApiErrorKind.badResponse,
          'Réponse inattendue du serveur : la demande a peut-être été traitée.',
          maybeProcessed: true,
        );

  Future<Object?> _send(
    String method,
    String path, {
    Object? body,
    bool authenticated = true,
    Duration timeout = readTimeout,
  }) async {
    final request = http.Request(method, Uri.parse(_base + path))
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    // The key only travels in this header; it is never logged nor put in a URL.
    if (authenticated) request.headers['Authorization'] = 'Bearer $_apiKey';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      final streamed = await _client.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw ApiError(
        ApiErrorKind.timeout,
        method == 'GET'
            ? 'Le serveur n’a pas répondu à temps.'
            : 'Aucune réponse reçue à temps : la demande a peut-être été traitée.',
      );
    } on HandshakeException {
      throw const ApiError(ApiErrorKind.tls, _tlsMessage);
    } on SocketException {
      throw const ApiError(ApiErrorKind.unreachable, _unreachableMessage);
    } on http.ClientException catch (error) {
      throw _transportError(error.message, method);
    }
    return _decode(response, method);
  }

  static ApiError _transportError(String detail, String method) {
    final lower = detail.toLowerCase();
    if (lower.contains('handshake') || lower.contains('certificate')) {
      return const ApiError(ApiErrorKind.tls, _tlsMessage);
    }
    if (lower.contains('connection closed') ||
        lower.contains('reset by peer')) {
      return ApiError(
        ApiErrorKind.interrupted,
        method == 'GET'
            ? 'Connexion interrompue.'
            : 'Connexion interrompue avant la réponse : la demande a peut-être été traitée.',
      );
    }
    return const ApiError(ApiErrorKind.unreachable, _unreachableMessage);
  }

  static const _unreachableMessage =
      'Serveur injoignable. Vérifiez que Tailscale est connecté sur ce téléphone '
      'et que l’adresse est correcte.';
  static const _tlsMessage =
      'Certificat HTTPS refusé. La connexion a été bloquée pour votre sécurité.';

  static Object? _decode(http.Response response, String method) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    Object? decoded;
    try {
      decoded = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (decoded == null && text.isNotEmpty) throw _badResponse(method);
      return decoded;
    }
    throw errorFromResponse(response.statusCode, decoded);
  }

  /// Maps `{"detail": ...}` (string, `{code, message}` or validation list).
  static ApiError errorFromResponse(int status, Object? decoded) {
    final detail = decoded is Map ? decoded['detail'] : null;
    String? code;
    String? serverMessage;
    var stored = const <ChatMessage>[];
    if (detail is Map) {
      code = detail['code'] is String ? detail['code'] as String : null;
      serverMessage = detail['message'] is String
          ? detail['message'] as String
          : null;
      final messages = detail['messages'];
      if (messages is List) {
        try {
          stored = [
            for (final item in messages)
              ChatMessage.fromJson(Map<String, dynamic>.from(item as Map)),
          ];
        } on Object {
          stored = const [];
        }
      }
    } else if (detail is String) {
      serverMessage = detail;
    }
    final kind = switch (status) {
      401 => ApiErrorKind.unauthorized,
      403 => ApiErrorKind.forbidden,
      404 => ApiErrorKind.notFound,
      409 => ApiErrorKind.conflict,
      410 => ApiErrorKind.gone,
      413 => ApiErrorKind.tooLarge,
      422 => ApiErrorKind.invalid,
      503 => ApiErrorKind.unavailable,
      _ => ApiErrorKind.server,
    };
    final fallback = switch (kind) {
      ApiErrorKind.unauthorized => 'Clé personnelle refusée par le serveur.',
      ApiErrorKind.forbidden => 'Permission refusée pour cette clé.',
      ApiErrorKind.notFound => 'Élément introuvable sur le serveur.',
      ApiErrorKind.tooLarge => 'Message trop volumineux.',
      ApiErrorKind.invalid => 'Données refusées par le serveur.',
      ApiErrorKind.unavailable => 'Service temporairement indisponible.',
      _ => 'Erreur du serveur (HTTP $status).',
    };
    final message = switch (kind) {
      ApiErrorKind.unauthorized =>
        'Clé personnelle refusée par le serveur. Vérifiez-la dans les réglages.',
      ApiErrorKind.forbidden when code == 'permission_denied' =>
        '${serverMessage ?? fallback}. Cette clé n’a pas le droit d’accéder à cette information.',
      _ => serverMessage ?? fallback,
    };
    return ApiError(
      kind,
      message,
      statusCode: status,
      code: code,
      messages: stored,
    );
  }
}

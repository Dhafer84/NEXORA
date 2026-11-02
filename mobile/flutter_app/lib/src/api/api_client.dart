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

  Future<ServerMetrics> metrics() async =>
      ServerMetrics.fromJson(await _object('GET', '/api/v1/server/metrics'));

  Future<AiStatus> aiStatus() async =>
      AiStatus.fromJson(await _object('GET', '/api/v1/ai/status'));

  // ----- Conversations -------------------------------------------------------

  Future<List<Conversation>> conversations({int limit = 50}) async => [
    for (final item in await _list('GET', '/api/v1/conversations?limit=$limit'))
      Conversation.fromJson(item),
  ];

  Future<Conversation> createConversation(String title) async =>
      Conversation.fromJson(
        await _object('POST', '/api/v1/conversations', body: {'title': title}),
      );

  Future<ConversationDetail> conversation(String id, {int limit = 200}) async =>
      ConversationDetail.fromJson(
        await _object('GET', '/api/v1/conversations/$id?limit=$limit'),
      );

  /// One assistant turn. Never retried automatically: on a timeout the server may
  /// already have stored and processed the message ([ApiError.outcomeUnknown]).
  Future<TurnResult> sendMessage(String conversationId, String content) async =>
      TurnResult.fromJson(
        await _object(
          'POST',
          '/api/v1/conversations/$conversationId/messages',
          body: {'content': content},
          timeout: turnTimeout,
        ),
      );

  // ----- Approvals -----------------------------------------------------------

  Future<List<Approval>> approvals({String? status, int limit = 50}) async {
    final filter = status == null ? '' : '&status=$status';
    return [
      for (final item in await _list(
        'GET',
        '/api/v1/approvals?limit=$limit$filter',
      ))
        Approval.fromJson(item),
    ];
  }

  Future<Approval> approval(String id) async =>
      Approval.fromJson(await _object('GET', '/api/v1/approvals/$id'));

  /// Records the decision only. The hash proves which parameters were shown.
  Future<Approval> approve(Approval approval) async => Approval.fromJson(
    await _object(
      'POST',
      '/api/v1/approvals/${approval.id}/approve',
      body: {'arguments_hash': approval.argumentsHash},
    ),
  );

  Future<Approval> reject(String id, {String? reason}) async =>
      Approval.fromJson(
        await _object(
          'POST',
          '/api/v1/approvals/$id/reject',
          body: {
            if (reason != null && reason.trim().isNotEmpty)
              'reason': reason.trim(),
          },
        ),
      );

  /// Runs an approved action with its exact stored parameters. Safe to repeat:
  /// the server returns the stored outcome with `replayed: true`.
  Future<ToolExecution> execute(Approval approval) async =>
      ToolExecution.fromJson(
        await _object(
          'POST',
          '/api/v1/approvals/${approval.id}/execute',
          body: {'arguments': approval.arguments},
          timeout: turnTimeout,
        ),
      );

  // ----- Transport -----------------------------------------------------------

  Future<Map<String, dynamic>> _object(
    String method,
    String path, {
    Object? body,
    Duration timeout = readTimeout,
  }) async {
    final decoded = await _send(method, path, body: body, timeout: timeout);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const ApiError(
      ApiErrorKind.badResponse,
      'Réponse inattendue du serveur.',
    );
  }

  Future<List<Map<String, dynamic>>> _list(String method, String path) async {
    final decoded = await _send(method, path);
    if (decoded is List) {
      return [
        for (final item in decoded) Map<String, dynamic>.from(item as Map),
      ];
    }
    throw const ApiError(
      ApiErrorKind.badResponse,
      'Réponse inattendue du serveur.',
    );
  }

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
    return _decode(response);
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

  static Object? _decode(http.Response response) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    Object? decoded;
    try {
      decoded = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (decoded == null && text.isNotEmpty) {
        throw const ApiError(
          ApiErrorKind.badResponse,
          'Réponse illisible du serveur.',
        );
      }
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
      code = detail['code'] as String?;
      serverMessage = detail['message'] as String?;
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

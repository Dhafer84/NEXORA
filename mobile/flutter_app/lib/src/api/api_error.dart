import 'models.dart';

enum ApiErrorKind {
  /// Address unreachable: DNS, refused connection, Tailscale disconnected.
  unreachable,

  /// HTTPS certificate rejected; never bypassed.
  tls,

  /// No answer before the deadline. For a write, the server may still have processed it.
  timeout,

  /// Connection lost after the request was sent: outcome unknown.
  interrupted,
  unauthorized,
  forbidden,
  notFound,
  conflict,
  gone,
  invalid,
  tooLarge,
  unavailable,
  server,

  /// Response that does not match the documented contract.
  badResponse,
}

/// Every failure of the API client, with a French message safe to display.
class ApiError implements Exception {
  const ApiError(
    this.kind,
    this.message, {
    this.statusCode,
    this.code,
    this.messages = const [],
    this.maybeProcessed = false,
  });

  final ApiErrorKind kind;
  final String message;
  final int? statusCode;

  /// Stable backend code (`detail.code`), e.g. `ai_unavailable`, `approval_expired`.
  final String? code;

  /// Messages already stored by the server (AI provider failure, HTTP 503).
  final List<ChatMessage> messages;

  /// Set for a write answered 2xx with an unreadable body.
  final bool maybeProcessed;

  /// True when a write may have been applied although no usable answer was received.
  bool get outcomeUnknown =>
      maybeProcessed ||
      kind == ApiErrorKind.timeout ||
      kind == ApiErrorKind.interrupted;

  @override
  String toString() => 'ApiError($kind, ${statusCode ?? '-'}, ${code ?? '-'})';
}

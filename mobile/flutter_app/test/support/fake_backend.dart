// In-memory imitation of the NEXORA backend for automated tests.
// It never opens a socket and never reaches any AI provider: answers are canned.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nexora/src/api/api_client.dart';

const testBaseUrl = 'https://nexora.test:8101';
const testApiKey = 'cle-de-test-locale';
const testHash =
    '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0';

typedef Handler = FutureOr<http.Response?> Function(http.Request request);

http.Response jsonResponse(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response errorResponse(int status, String code, String message) =>
    jsonResponse({
      'detail': {'code': code, 'message': message},
    }, status);

class FakeBackend {
  FakeBackend({this.apiKey = testApiKey});

  final String apiKey;
  final List<http.Request> requests = [];
  final Map<String, Map<String, dynamic>> conversations = {};
  final Map<String, List<Map<String, dynamic>>> messages = {};
  final Map<String, Map<String, dynamic>> approvals = {};

  /// Paths (without query) answered with 403 permission_denied.
  final Set<String> forbidden = {};

  /// Checked first; returning a response short-circuits the default routes.
  Handler? override;

  /// When set, an assistant turn waits for it before answering.
  Completer<void>? turnGate;

  int executions = 0;
  int turns = 0;
  int _ids = 0;
  final DateTime now = DateTime.utc(2026, 11, 2, 9, 30);

  MockClient get client => MockClient(_handle);

  NexoraApi api({String? key}) =>
      NexoraApi(baseUrl: testBaseUrl, apiKey: key ?? apiKey, client: client);

  NexoraApi factory(String baseUrl, String key) =>
      NexoraApi(baseUrl: baseUrl, apiKey: key, client: client);

  String _id(String prefix) => '$prefix-${(++_ids).toString().padLeft(4, '0')}';

  String _date([Duration offset = Duration.zero]) =>
      now.add(offset).toIso8601String();

  Map<String, dynamic> addConversation(String title) {
    final id = _id('conv');
    final conversation = {
      'id': id,
      'title': title,
      'status': 'active',
      'created_at': _date(),
      'updated_at': _date(),
    };
    conversations[id] = conversation;
    messages[id] = [];
    return conversation;
  }

  Map<String, dynamic> addMessage(
    String conversationId,
    String role,
    String content, {
    String status = 'ok',
    String? provider,
    String? approvalId,
  }) {
    final message = {
      'id': _id('msg'),
      'role': role,
      'content': content,
      'status': status,
      'tool_execution_id': null,
      'approval_request_id': approvalId,
      'provider': provider,
      'created_at': _date(Duration(seconds: _ids)),
    };
    messages[conversationId]!.add(message);
    return message;
  }

  Map<String, dynamic> addApproval({
    String? conversationId,
    String status = 'pending',
    String tool = 'test_action',
    Map<String, dynamic> arguments = const {'message': 'bonjour'},
    String risk = 'low',
  }) {
    final id = _id('appr');
    final approval = {
      'id': id,
      'conversation_id': conversationId,
      'tool': tool,
      'arguments': arguments,
      'arguments_hash': testHash,
      'summary': 'Action de test sans effet : renvoie le message fourni',
      'risk': risk,
      'status': status,
      'expires_at': _date(const Duration(minutes: 10)),
      'decided_at': null,
      'decision_reason': null,
      'consumed_at': null,
      'created_at': _date(),
    };
    approvals[id] = approval;
    return approval;
  }

  Map<String, dynamic> get metrics => {
    'observed_at': _date(),
    'scope': 'host',
    'cpu_percent': 12.5,
    'memory': {
      'total_bytes': 8 * 1024 * 1024 * 1024,
      'used_bytes': 3 * 1024 * 1024 * 1024,
      'available_bytes': 5 * 1024 * 1024 * 1024,
      'used_percent': 37.5,
    },
    'disk': {
      'total_bytes': 100 * 1024 * 1024 * 1024,
      'used_bytes': 40 * 1024 * 1024 * 1024,
      'available_bytes': 60 * 1024 * 1024 * 1024,
      'used_percent': 40.0,
    },
  };

  static const simulatedProvider = {
    'name': 'simulated',
    'model': 'nexora-simulated',
    'real': false,
  };

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    final custom = await override?.call(request);
    if (custom != null) return custom;
    final path = request.url.path;
    final method = request.method;
    if (method == 'GET' && path == '/health/live') {
      return jsonResponse({'status': 'ok'});
    }
    if (request.headers['Authorization'] != 'Bearer $apiKey') {
      return jsonResponse({'detail': 'Clé API invalide ou absente'}, 401);
    }
    if (forbidden.contains(path)) {
      return errorResponse(
        403,
        'permission_denied',
        'Permission « server:read » requise',
      );
    }
    final segments = request.url.pathSegments;
    final body = request.body.isEmpty
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(request.body) as Map);

    switch ((method, segments)) {
      case ('GET', ['api', 'v1', 'auth', 'check']):
        return jsonResponse({'status': 'ok'});
      case ('GET', ['health', 'ready']):
        return jsonResponse({'status': 'ready'});
      case ('GET', ['api', 'v1', 'server', 'metrics']):
        return jsonResponse(metrics);
      case ('GET', ['api', 'v1', 'ai', 'status']):
        return jsonResponse({
          'provider': simulatedProvider,
          'configured': true,
          'detail': 'Fournisseur simulé : aucune IA réelle.',
        });
      case ('GET', ['api', 'v1', 'conversations']):
        return jsonResponse(conversations.values.toList().reversed.toList());
      case ('POST', ['api', 'v1', 'conversations']):
        return jsonResponse(addConversation(body['title'] as String), 201);
      case ('GET', ['api', 'v1', 'conversations', final id]):
        final conversation = conversations[id];
        if (conversation == null) {
          return errorResponse(404, 'conversation_not_found', 'Introuvable');
        }
        return jsonResponse({...conversation, 'messages': messages[id]});
      case ('POST', ['api', 'v1', 'conversations', final id, 'messages']):
        return _turn(id, body['content'] as String);
      case ('GET', ['api', 'v1', 'approvals']):
        final status = request.url.queryParameters['status'];
        return jsonResponse([
          for (final approval in approvals.values)
            if (status == null || approval['status'] == status) approval,
        ]);
      case ('GET', ['api', 'v1', 'approvals', final id]):
        final approval = approvals[id];
        return approval == null
            ? errorResponse(404, 'approval_not_found', 'Introuvable')
            : jsonResponse(approval);
      case ('POST', ['api', 'v1', 'approvals', final id, final action]):
        final approval = approvals[id];
        if (approval == null) {
          return errorResponse(404, 'approval_not_found', 'Introuvable');
        }
        return _decide(approval, action, body);
    }
    return errorResponse(404, 'not_found', 'Route inconnue');
  }

  Future<http.Response> _turn(String id, String content) async {
    turns++;
    if (!conversations.containsKey(id)) {
      return errorResponse(404, 'conversation_not_found', 'Introuvable');
    }
    final gate = turnGate;
    if (gate != null) await gate.future;
    final user = addMessage(id, 'user', content);
    final toolExecutions = <Map<String, dynamic>>[];
    var status = 'completed';
    Map<String, dynamic> answer;
    if (content.contains('action de test')) {
      final approval = addApproval(conversationId: id);
      answer = addMessage(
        id,
        'assistant',
        'Cette action demande votre validation.',
        status: 'pending_approval',
        provider: 'simulated',
        approvalId: approval['id'] as String,
      );
      status = 'pending_approval';
      toolExecutions.add({
        'execution_id': _id('exec'),
        'tool': 'test_action',
        'status': 'pending_approval',
        'result': null,
        'error_code': null,
        'error_message': null,
        'approval': approval,
      });
    } else {
      answer = addMessage(
        id,
        'assistant',
        'Réponse **simulée** à : $content',
        provider: 'simulated',
      );
    }
    return jsonResponse({
      'conversation_id': id,
      'status': status,
      'messages': [user, answer],
      'tool_executions': toolExecutions,
      'provider': simulatedProvider,
      'error_code': null,
    });
  }

  http.Response _decide(
    Map<String, dynamic> approval,
    String action,
    Map<String, dynamic> body,
  ) {
    final status = approval['status'] as String;
    http.Response refused() => status == 'expired'
        ? errorResponse(410, 'approval_expired', 'Demande expirée')
        : errorResponse(409, 'approval_$status', 'Demande $status');
    switch (action) {
      case 'approve':
        if (body['arguments_hash'] != approval['arguments_hash']) {
          return errorResponse(
            409,
            'approval_arguments_mismatch',
            'Paramètres modifiés',
          );
        }
        if (status == 'pending') {
          approval['status'] = 'approved';
          approval['decided_at'] = _date(const Duration(minutes: 1));
        } else if (status != 'approved') {
          return refused();
        }
        return jsonResponse(approval);
      case 'reject':
        if (status == 'pending' || status == 'approved') {
          approval['status'] = 'rejected';
          approval['decided_at'] = _date(const Duration(minutes: 1));
          approval['decision_reason'] = body['reason'];
        } else if (status != 'rejected') {
          return refused();
        }
        return jsonResponse(approval);
      case 'execute':
        final result = {
          'execution_id': 'exec-${approval['id']}',
          'tool': approval['tool'],
          'status': 'succeeded',
          'result': {'echo': approval['arguments']},
          'error_code': null,
          'error_message': null,
          'approval': approval,
        };
        if (status == 'consumed') {
          return jsonResponse({...result, 'replayed': true});
        }
        if (status != 'approved') return refused();
        executions++;
        approval['status'] = 'consumed';
        approval['consumed_at'] = _date(const Duration(minutes: 2));
        final conversationId = approval['conversation_id'] as String?;
        if (conversationId != null) {
          // Same shape as backend tool_content(): a JSON summary of the run.
          addMessage(
            conversationId,
            'tool',
            jsonEncode({
              'tool': approval['tool'],
              'status': 'succeeded',
              'result': result['result'],
            }),
            approvalId: approval['id'] as String,
          );
        }
        return jsonResponse({...result, 'replayed': false});
    }
    return errorResponse(404, 'not_found', 'Route inconnue');
  }
}

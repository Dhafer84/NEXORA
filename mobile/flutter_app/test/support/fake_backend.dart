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
  final Map<String, Map<String, dynamic>> automations = {};
  final Map<String, List<Map<String, dynamic>>> runs = {};
  final List<Map<String, dynamic>> notifications = [];

  Map<String, dynamic> github = {
    'configured': true,
    'authenticated': false,
    'repos': [
      {
        'repo': 'Dhafer84/NEXORA',
        'available': true,
        'error': null,
        'open_issues': 2,
        'commits': [
          {
            'sha': 'e4b3965',
            'message': 'Enregistre l’adresse et la clé ensemble',
            'author': 'Dhafer',
            'date': '2026-11-02T09:00:00Z',
          },
        ],
        'issues': [],
        'workflow_runs': [
          {
            'name': 'Mobile checks',
            'branch': 'main',
            'status': 'completed',
            'conclusion': 'failure',
            'created_at': '2026-11-02T09:01:00Z',
          },
        ],
      },
      {
        'repo': 'Dhafer84/assistant',
        'available': false,
        'error': 'Dépôt introuvable, ou privé sans jeton d’accès',
        'open_issues': null,
        'commits': [],
        'issues': [],
        'workflow_runs': [],
      },
    ],
  };

  /// Disk usage returned by a manual check; an exception value makes it fail.
  double? diskPercent = 42.5;

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

  Map<String, dynamic> addAutomation({
    String name = 'Vérification du disque',
    double threshold = 85,
    int interval = 60,
    bool enabled = true,
  }) {
    final id = _id('auto');
    final automation = {
      'id': id,
      'name': name,
      'kind': 'disk_check',
      'threshold_percent': threshold,
      'interval_minutes': interval,
      'timezone': 'Europe/Paris',
      'enabled': enabled,
      // 10:00 UTC = 11:00 in Paris, as the backend sends it.
      'next_run_at': enabled ? '2026-11-02T11:00:00+01:00' : null,
      'alert_active': false,
      'failing': false,
      'last_run': null,
      'created_at': _date(),
      'updated_at': _date(),
    };
    automations[id] = automation;
    runs[id] = [];
    return automation;
  }

  Map<String, dynamic> addNotification(String title, {String level = 'alert'}) {
    final notification = {
      'id': notifications.length + 1,
      'created_at': _date(),
      'level': level,
      'title': title,
      'body': 'Détail de « $title »',
      'automation_id': null,
      'run_id': null,
    };
    notifications.add(notification);
    return notification;
  }

  /// Same anti-repeat rule as the backend, for manual checks.
  Map<String, dynamic> _check(Map<String, dynamic> automation) {
    final threshold = automation['threshold_percent'] as double;
    final value = diskPercent;
    final alert = value != null && value >= threshold;
    final notify = value == null
        ? !(automation['failing'] as bool)
        : alert != automation['alert_active'];
    final run = {
      'id': _id('run'),
      'automation_id': automation['id'],
      'trigger': 'manual',
      'scheduled_for': null,
      'missed_slots': 0,
      'started_at': _date(Duration(minutes: _ids)),
      'finished_at': _date(Duration(minutes: _ids)),
      'status': value == null ? 'failed' : (alert ? 'alert' : 'ok'),
      'measured_percent': value,
      'threshold_percent': threshold,
      'error_code': value == null ? 'metrics_unavailable' : null,
      'message': value == null
          ? 'Mesure du disque impossible'
          : 'Disque utilisé à ${value.toStringAsFixed(1).replaceAll('.', ',')} %',
      'notified': notify,
    };
    if (value != null) automation['alert_active'] = alert;
    automation['failing'] = value == null;
    automation['last_run'] = run;
    runs[automation['id']]!.insert(0, run);
    if (notify) addNotification(run['message'] as String);
    return run;
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
      case ('GET', ['api', 'v1', 'github']):
        return jsonResponse(github);
      case ('GET', ['api', 'v1', 'automations']):
        return jsonResponse(automations.values.toList());
      case ('POST', ['api', 'v1', 'automations']):
        final created = addAutomation(
          name: body['name'] as String,
          threshold: (body['threshold_percent'] as num).toDouble(),
          interval: body['interval_minutes'] as int,
          enabled: body['enabled'] as bool,
        );
        created['timezone'] = body['timezone'];
        return jsonResponse(created, 201);
      case ('GET', ['api', 'v1', 'notifications']):
        final after = int.parse(request.url.queryParameters['after_id'] ?? '0');
        final limit = int.parse(request.url.queryParameters['limit'] ?? '20');
        return jsonResponse({
          'items': notifications
              .where((n) => (n['id'] as int) > after)
              .take(limit)
              .toList(),
          'latest_id': notifications.length,
        });
    }
    if (segments.length >= 4 &&
        segments.sublist(0, 3).join('/') == 'api/v1/automations') {
      final automation = automations[segments[3]];
      if (automation == null) {
        return errorResponse(
          404,
          'automation_not_found',
          'Automatisation introuvable',
        );
      }
      switch ((method, segments.sublist(4))) {
        case ('GET', []):
          return jsonResponse(automation);
        case ('PATCH', []):
          automation.addAll(body);
          if (body.containsKey('threshold_percent')) {
            automation['threshold_percent'] = (body['threshold_percent'] as num)
                .toDouble();
            automation['alert_active'] = false;
          }
          automation['next_run_at'] = automation['enabled'] as bool
              ? '2026-11-02T11:00:00+01:00'
              : null;
          return jsonResponse(automation);
        case ('DELETE', []):
          automations.remove(segments[3]);
          return http.Response('', 204);
        case ('POST', ['run']):
          return jsonResponse(_check(automation));
        case ('GET', ['runs']):
          return jsonResponse(runs[segments[3]]);
      }
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
    final start = messages[id]!.length;
    addMessage(id, 'user', content);
    final toolExecutions = <Map<String, dynamic>>[];
    var status = 'completed';
    if (content.contains('action de test')) {
      final approval = addApproval(conversationId: id);
      // Same shape as backend tool_content() for a request awaiting approval.
      addMessage(
        id,
        'tool',
        jsonEncode({
          'tool': 'test_action',
          'status': 'pending_approval',
          'approval': {
            'id': approval['id'],
            'summary': approval['summary'],
            'expires_at': approval['expires_at'],
            'note': 'Action non exécutée : en attente de validation.',
          },
        }),
        status: 'pending_approval',
        approvalId: approval['id'] as String,
      );
      addMessage(
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
    } else if (content.toLowerCase().contains('espace disque')) {
      // Read-only tool: a structured result, never a validation request.
      addMessage(
        id,
        'tool',
        jsonEncode({
          'tool': 'server_metrics',
          'status': 'succeeded',
          'result': {
            'observed_at': _date(),
            'scope': 'host',
            'cpu_percent': 12.5,
            'memory': {'used_percent': 41.7},
            'disk': {'used_percent': diskPercent ?? 0},
          },
        }),
      );
      toolExecutions.add({
        'execution_id': _id('exec'),
        'tool': 'server_metrics',
        'status': 'succeeded',
        'result': null,
        'error_code': null,
        'error_message': null,
        'approval': null,
      });
      addMessage(
        id,
        'assistant',
        'Le disque est utilisé à ${diskPercent ?? 0} %.',
        provider: 'simulated',
      );
    } else {
      addMessage(
        id,
        'assistant',
        'Réponse **simulée** à : $content',
        provider: 'simulated',
      );
    }
    return jsonResponse({
      'conversation_id': id,
      'status': status,
      'messages': messages[id]!.sublist(start),
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

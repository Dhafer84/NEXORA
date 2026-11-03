import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Small key-value settings shared by the full app and the mini-chat. The two
/// run in separate isolates, so the store must not cache values.
abstract class SessionStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String? value);
  Future<bool?> getBool(String key);
  Future<void> setBool(String key, bool value);
}

class PreferencesSessionStore implements SessionStore {
  PreferencesSessionStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> getString(String key) => _preferences.getString(key);

  @override
  Future<void> setString(String key, String? value) => value == null
      ? _preferences.remove(key)
      : _preferences.setString(key, value);

  @override
  Future<bool?> getBool(String key) => _preferences.getBool(key);

  @override
  Future<void> setBool(String key, bool value) =>
      _preferences.setBool(key, value);
}

class MemorySessionStore implements SessionStore {
  final Map<String, Object> values = {};

  @override
  Future<String?> getString(String key) async => values[key] as String?;

  @override
  Future<void> setString(String key, String? value) async =>
      value == null ? values.remove(key) : values[key] = value;

  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;

  @override
  Future<void> setBool(String key, bool value) async => values[key] = value;
}

/// Keys of [SessionStore]. Drafts are per conversation.
abstract final class SessionKeys {
  static const currentConversation = 'nexora.chat.current';
  static String draft(String conversationId) =>
      'nexora.chat.draft.$conversationId';
  static const allowRemoteRecognition = 'nexora.voice.remote';
  static const autoRead = 'nexora.voice.autoread';
  static const bubbleEnabled = 'nexora.bubble.enabled';
}

typedef InFlight = ({String owner, String text});

/// The single in-flight message of each conversation, shared by every NEXORA
/// window (full app and mini-chat): a second window cannot send while the
/// first one waits for its answer. The server refuses a concurrent turn too
/// (`409 turn_in_progress`); this lock avoids even trying.
abstract class TurnLock {
  /// Claims the turn of [conversationId] for [owner]. False when taken.
  Future<bool> begin(String conversationId, String owner, String text);

  Future<void> end(String conversationId, String owner);

  /// Window and text of the message being sent in [conversationId], or null.
  Future<InFlight?> inFlight(String conversationId);

  /// Conversation ids whose turn began or ended, from any window.
  Stream<String> get changes;
}

/// Single-process lock, for tests: several controllers share one instance.
class MemoryTurnLock implements TurnLock {
  final Map<String, ({String owner, String text})> _turns = {};
  final _changes = StreamController<String>.broadcast(sync: true);

  @override
  Future<bool> begin(String conversationId, String owner, String text) async {
    if (_turns.containsKey(conversationId)) return false;
    _turns[conversationId] = (owner: owner, text: text);
    _changes.add(conversationId);
    return true;
  }

  @override
  Future<void> end(String conversationId, String owner) async {
    if (_turns[conversationId]?.owner != owner) return;
    _turns.remove(conversationId);
    _changes.add(conversationId);
  }

  @override
  Future<InFlight?> inFlight(String conversationId) async =>
      _turns[conversationId];

  @override
  Stream<String> get changes => _changes.stream;
}

/// Process-wide lock held by the Android side (`SessionHub.kt`): both Flutter
/// engines (app and bubble) live in the same process and see the same turns.
/// Held in memory only: a process restart never leaves a stale lock.
class NativeTurnLock implements TurnLock {
  NativeTurnLock() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') _changes.add(call.arguments as String);
    });
  }

  static const _channel = MethodChannel('app.nexora/session');
  final _changes = StreamController<String>.broadcast();

  @override
  Future<bool> begin(String conversationId, String owner, String text) async =>
      await _channel.invokeMethod<bool>('begin', {
        'conversation': conversationId,
        'owner': owner,
        'text': text,
      }) ??
      false;

  @override
  Future<void> end(String conversationId, String owner) =>
      _channel.invokeMethod<void>('end', {
        'conversation': conversationId,
        'owner': owner,
      });

  @override
  Future<InFlight?> inFlight(String conversationId) async {
    final raw = await _channel.invokeMethod<Map>('inFlight', {
      'conversation': conversationId,
    });
    if (raw == null) return null;
    return (owner: raw['owner'] as String, text: raw['text'] as String);
  }

  @override
  Stream<String> get changes => _changes.stream;
}

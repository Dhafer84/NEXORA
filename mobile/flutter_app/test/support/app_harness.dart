import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora/main.dart';
import 'package:nexora/src/state/app_state.dart';
import 'package:nexora/src/storage/credentials_store.dart';

import 'fake_backend.dart';

AppState? _current;

/// Like [testWidgets], but stops the app state (and its polling timer) before
/// the framework checks that no timer is left behind.
void testApp(String description, WidgetTesterCallback body) {
  testWidgets(description, (tester) async {
    // Phone-sized portrait view unless the test sets its own.
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox());
      _current?.dispose();
      _current = null;
    }
  });
}

/// Starts the real application widget against [backend], optionally already configured.
Future<AppState> pumpApp(
  WidgetTester tester,
  FakeBackend backend, {
  bool configured = true,
  ThemeMode themeMode = ThemeMode.light,
}) async {
  await initializeDateFormatting('fr_FR');
  FlutterSecureStorage.setMockInitialValues(
    configured
        ? {
            SecureCredentialsStore.entryKey: jsonEncode({
              'base_url': testBaseUrl,
              'api_key': backend.apiKey,
            }),
          }
        : {},
  );
  final state = AppState(
    store: SecureCredentialsStore(),
    apiFactory: backend.factory,
  );
  _current = state;
  await tester.pumpWidget(NexoraApp(state: state, themeMode: themeMode));
  await state.load();
  await tester.pumpAndSettle();
  return _current = state;
}

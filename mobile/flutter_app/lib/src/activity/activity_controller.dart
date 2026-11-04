import 'package:flutter/foundation.dart';

import '../health/health_service.dart';
import 'activity_models.dart';
import 'activity_store.dart';

/// Days read on each refresh: 30 days and the 30 before, for comparisons.
const windowDays = 60;

enum Issue {
  /// Read permission not granted yet (never asked, or refused).
  notAuthorized,

  /// The permission was withdrawn: the local copy has been erased.
  revoked,
  unavailable,
  failed,
}

class CategoryState {
  const CategoryState({this.data, this.issue, this.busy = false, this.code});

  /// Last successful read, possibly from the local copy.
  final RangeData? data;
  final Issue? issue;
  final bool busy;

  /// Error code of a failed read (shown, never the values).
  final String? code;

  CategoryState copyWith({
    RangeData? data,
    Issue? issue,
    bool? busy,
    String? code,
  }) => CategoryState(
    data: data ?? this.data,
    issue: issue,
    busy: busy ?? this.busy,
    code: code,
  );
}

/// Activity module state. Each category is read, kept and erased on its own;
/// Health Connect itself is never modified.
class ActivityController extends ChangeNotifier {
  ActivityController({
    required this.service,
    required this.store,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final HealthService service;
  final ActivityStore store;
  final DateTime Function() _now;

  HealthStatus? status;
  final Map<HealthCategory, CategoryState> _states = {
    for (final c in HealthCategory.values) c: const CategoryState(),
  };
  bool _disposed = false;

  CategoryState operator [](HealthCategory category) => _states[category]!;

  DayKey get today => keyOf(_now());

  /// Last finished day: the end of every period except sleep's.
  DayKey get yesterday => shiftDay(today, -1);

  bool get available => status?.sdk == HealthSdk.available;

  void _set(HealthCategory category, CategoryState state) {
    _states[category] = state;
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    status = await service.status();
    for (final category in HealthCategory.values) {
      final raw = await store.read(category);
      RangeData? data;
      if (raw != null) {
        try {
          data = parseRange(category, raw);
        } catch (_) {
          // Copy written by another version: rebuilt on the next refresh.
          await store.delete(category);
        }
      }
      if (available && data != null && !status!.granted.contains(category)) {
        // Permission withdrawn while NEXORA was closed: nothing is kept.
        await store.delete(category);
        _states[category] = const CategoryState(issue: Issue.revoked);
        continue;
      }
      _states[category] = CategoryState(
        data: data,
        issue: !available
            ? Issue.unavailable
            : status!.granted.contains(category)
            ? null
            : Issue.notAuthorized,
      );
    }
    if (!_disposed) notifyListeners();
  }

  /// Shows Health Connect's screen for this category only, then reads it.
  Future<void> authorize(HealthCategory category) async {
    _set(
      category,
      this[category].copyWith(busy: true, issue: this[category].issue),
    );
    final granted = await service.request(category);
    status = await service.status();
    if (granted) {
      await refresh(category);
    } else {
      _set(
        category,
        this[category].copyWith(busy: false, issue: Issue.notAuthorized),
      );
    }
  }

  /// Reads the whole window again and replaces the local copy: updated or
  /// deleted entries are reflected, and the same entries give the same figures.
  Future<void> refresh(HealthCategory category) async {
    _set(
      category,
      this[category].copyWith(busy: true, issue: this[category].issue),
    );
    final reading = await service.range(
      category,
      shiftDay(today, 1 - windowDays),
      today,
    );
    switch (reading) {
      case HealthRangeRaw(:final raw):
        try {
          final data = parseRange(category, raw);
          await store.write(category, raw);
          _set(category, CategoryState(data: data));
        } catch (_) {
          _set(
            category,
            this[category].copyWith(
              busy: false,
              issue: Issue.failed,
              code: 'format',
            ),
          );
        }
      case HealthDenied():
        // Permission withdrawn in Health Connect: nothing is kept any more.
        await store.delete(category);
        status = await service.status();
        _set(category, const CategoryState(issue: Issue.revoked));
      case HealthUnavailable():
        _set(
          category,
          this[category].copyWith(busy: false, issue: Issue.unavailable),
        );
      case HealthFailed(:final code):
        _set(
          category,
          this[category].copyWith(busy: false, issue: Issue.failed, code: code),
        );
      case HealthData():
        _set(
          category,
          this[category].copyWith(
            busy: false,
            issue: Issue.failed,
            code: 'unexpected',
          ),
        );
    }
  }

  /// Manual refresh of every authorized category.
  Future<void> refreshAll() async {
    status = await service.status();
    if (!available) {
      for (final c in HealthCategory.values) {
        _set(c, this[c].copyWith(issue: Issue.unavailable));
      }
      return;
    }
    for (final category in HealthCategory.values) {
      if (status!.granted.contains(category)) {
        await refresh(category);
      } else if (this[category].data != null) {
        // Revoked since the last read.
        await store.delete(category);
        _set(category, const CategoryState(issue: Issue.revoked));
      }
    }
  }

  /// Erases what NEXORA kept; Health Connect's data stays as it is.
  Future<void> clearLocal() async {
    await store.clear();
    for (final c in HealthCategory.values) {
      _set(
        c,
        CategoryState(
          issue: status?.granted.contains(c) ?? false
              ? null
              : Issue.notAuthorized,
        ),
      );
    }
  }

  /// Most recent successful read among the categories.
  DateTime? get lastRead {
    final reads = [
      for (final s in _states.values)
        if (s.data != null) s.data!.readAt,
    ];
    if (reads.isEmpty) return null;
    return reads.reduce((a, b) => a.isAfter(b) ? a : b);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

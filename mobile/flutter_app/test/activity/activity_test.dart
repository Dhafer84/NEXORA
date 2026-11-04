import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:nexora/src/activity/activity_controller.dart';
import 'package:nexora/src/activity/activity_models.dart';
import 'package:nexora/src/activity/activity_report.dart';
import 'package:nexora/src/activity/activity_stats.dart';
import 'package:nexora/src/activity/activity_store.dart';
import 'package:nexora/src/health/health_service.dart';
import 'package:nexora/src/health/health_summary.dart';

import '../support/activity_samples.dart';
import '../support/fake_health.dart';

StepsData _steps([Map<String, Object?>? raw]) =>
    parseRange(HealthCategory.steps, raw ?? stepsRaw()) as StepsData;

void main() {
  setUpAll(() => initializeDateFormatting('fr_FR'));

  group('jours', () {
    test('une semaine qui traverse le changement d’heure garde 7 jours', () {
      // 25 October 2026: clocks go back in Europe.
      final days = daysBetween('2026-10-22', '2026-10-28');
      expect(days, hasLength(7));
      expect(days.toSet(), hasLength(7));
      expect(shiftDay('2026-10-25', 1), '2026-10-26');
      expect(shiftDay('2026-03-29', 1), '2026-03-30');
    });
  });

  group('pas', () {
    test('un jour sans donnée n’est pas un zéro', () {
      final data = _steps(stepsRaw(gaps: {'2026-10-30'}));
      final w = windows('2026-11-02', 7).current;
      final points = stepsSeries(data, healthSyncPackage, w, sampleToday);
      final gap = points.firstWhere((p) => p.day == '2026-10-30');
      expect(gap.value, isNull);
      expect(gap.state, DayState.missing);
      final stats = PeriodStats(points);
      expect(stats.complete, 6);
      expect(stats.missing, 1);
      expect(stats.mean, 8000, reason: 'moyenne sur les jours renseignés');
      expect(stats.total, 48000);
    });

    test('aujourd’hui est partiel et exclu de la moyenne', () {
      final data = _steps();
      final points = stepsSeries(data, healthSyncPackage, [
        '2026-11-02',
        sampleToday,
      ], sampleToday);
      expect(points.last.state, DayState.partial);
      expect(PeriodStats(points).mean, 8000);
    });

    test('Health Sync par défaut ; total Health Connect sans addition', () {
      final data = _steps();
      expect(defaultStepsSource(data), healthSyncPackage);
      final total = stepsSeries(data, allSources, ['2026-11-02'], sampleToday);
      expect(total.single.value, 8500, reason: 'pas 8000 + 1500');
      expect(stepsOverlap(data, '2026-11-02'), 1000);
    });

    test('comparaison seulement à couverture comparable', () {
      final full = _steps();
      final w = windows('2026-11-02', 7);
      PeriodStats s(StepsData d, List<DayKey> days) =>
          PeriodStats(stepsSeries(d, healthSyncPackage, days, sampleToday));
      final ok = compare(s(full, w.current), s(full, w.previous));
      expect(ok.comparable, isTrue);
      expect(ok.change, 0);

      final holes = _steps(
        stepsRaw(gaps: {for (final d in w.previous.take(4)) d}),
      );
      final bad = compare(s(holes, w.current), s(holes, w.previous));
      expect(bad.comparable, isFalse);
      expect(bad.reason, contains('couverture insuffisante'));
    });

    test('appareil affiché seulement s’il est identifié', () {
      final identified = _steps();
      expect(
        identified.origins.first.source.device,
        contains('WATCH GT 5 Pro'),
      );
      final unknown = _steps(stepsRaw(device: {'deviceType': 1}));
      expect(
        unknown.origins.first.source.label,
        'Health Sync — $unidentifiedDevice',
      );
    });
  });

  group('sommeil', () {
    test('nuit comptée au jour du réveil, sans double compte à minuit', () {
      final data =
          parseRange(
                HealthCategory.sleep,
                sleepRaw([
                  sleepSession(
                    healthSyncPackage,
                    '2026-11-01T23:30:00',
                    '2026-11-02T07:00:00',
                    stages: {'4': 300, '5': 150},
                  ),
                  // Same night, other app, overlapping: not added.
                  sleepSession(
                    fitPackage,
                    '2026-11-02T00:00:00',
                    '2026-11-02T06:30:00',
                    device: const {'deviceType': 2},
                  ),
                ]),
              )
              as SleepData;
      final byDay = nights(data, allSources);
      expect(byDay.keys, ['2026-11-02']);
      final night = byDay['2026-11-02']!;
      expect(night.minutes, 450, reason: 'union 23:30–07:00');
      expect(night.bedtime, '23:30');
      expect(night.wake, '07:00');
      expect(night.stages, {
        4: 300,
        5: 150,
      }, reason: 'phases de la session principale');
      expect(defaultSleepSource(data), healthSyncPackage);
    });
  });

  group('fréquence cardiaque', () {
    test('moyenne pondérée par le nombre de mesures', () {
      final data =
          parseRange(
                HealthCategory.heartRate,
                heartRaw([
                  heartDay('2026-11-01', 100, 6000, 50, 120),
                  heartDay('2026-11-02', 300, 24000, 55, 140),
                ]),
              )
              as HeartData;
      final days = heartDays(data, healthSyncPackage);
      final stats = HeartStats(days.values);
      expect(stats.count, 400);
      expect(stats.mean, 75, reason: '(6000 + 24000) / 400, pas (60 + 80) / 2');
      expect(stats.min, 50);
      expect(stats.max, 140);
    });
  });

  group('entraînements', () {
    test('même séance de deux sources : un doublon retiré', () {
      final data =
          parseRange(
                HealthCategory.exercise,
                exerciseRaw([
                  workout(
                    healthSyncPackage,
                    '2026-11-02T18:00:00',
                    '2026-11-02T18:40:00',
                    distance: 6000,
                  ),
                  workout(
                    fitPackage,
                    '2026-11-02T18:05:00',
                    '2026-11-02T18:35:00',
                  ),
                  workout(
                    fitPackage,
                    '2026-11-01T07:00:00',
                    '2026-11-01T07:30:00',
                    type: 79,
                  ),
                ]),
              )
              as ExerciseData;
      final kept = workoutsFor(
        data,
        allSources,
        windows('2026-11-02', 7).current,
      );
      expect(kept, hasLength(2));
      expect(kept.first.source.origin, healthSyncPackage);
      expect(dedupeWorkouts(data.sessions).duplicates, 1);
      final weeks = weeklyWorkouts(kept, windows('2026-11-02', 7).current);
      expect(weeks.map((w) => w.sessions), [1, 1]);
      expect(weeks.first.partial, isTrue);
    });
  });

  group('contrôleur', () {
    late FakeHealth health;
    late MemoryActivityStore store;
    ActivityController build() =>
        ActivityController(service: health, store: store, now: () => sampleNow);

    setUp(() {
      health = FakeHealth(
        granted: {HealthCategory.steps},
        ranges: {HealthCategory.steps: stepsRaw()},
      );
      store = MemoryActivityStore();
    });

    test(
      'une seule catégorie lue, deux lectures donnent les mêmes chiffres',
      () async {
        final c = build();
        await c.load();
        await c.refreshAll();
        expect(health.calls.where((x) => x.startsWith('range')), [
          'range:steps:2026-09-05:$sampleToday',
        ]);
        expect(c[HealthCategory.sleep].issue, Issue.notAuthorized);
        final first = (c[HealthCategory.steps].data! as StepsData).total;
        await c.refreshAll();
        expect((c[HealthCategory.steps].data! as StepsData).total, first);
        expect(await store.read(HealthCategory.steps), isNotNull);
      },
    );

    test('autorisation retirée : la copie locale est effacée', () async {
      final c = build();
      await c.load();
      await c.refreshAll();
      health.granted.clear();
      await c.refreshAll();
      expect(c[HealthCategory.steps].issue, Issue.revoked);
      expect(c[HealthCategory.steps].data, isNull);
      expect(await store.read(HealthCategory.steps), isNull);
    });

    test('autorisation retirée pendant que NEXORA était fermé', () async {
      final c = build();
      await c.load();
      await c.refreshAll();
      health.granted.clear();
      final reopened = build();
      await reopened.load();
      expect(reopened[HealthCategory.steps].issue, Issue.revoked);
      expect(reopened[HealthCategory.steps].data, isNull);
      expect(await store.read(HealthCategory.steps), isNull);
    });

    test(
      'erreur de lecture : la dernière lecture réussie reste affichée',
      () async {
        final c = build();
        await c.load();
        await c.refreshAll();
        health.failRange[HealthCategory.steps] = 'remote';
        await c.refresh(HealthCategory.steps);
        expect(c[HealthCategory.steps].issue, Issue.failed);
        expect(c[HealthCategory.steps].data, isNotNull);
      },
    );

    test('effacer ne touche que NEXORA', () async {
      final c = build();
      await c.load();
      await c.refreshAll();
      final before = health.calls.length;
      await c.clearLocal();
      expect(await store.read(HealthCategory.steps), isNull);
      expect(c[HealthCategory.steps].data, isNull);
      expect(
        health.calls.length,
        before,
        reason: 'aucun appel à Health Connect',
      );
    });
  });

  group('résumé IA et export', () {
    final data = <HealthCategory, RangeData?>{
      HealthCategory.steps: _steps(stepsRaw(gaps: {'2026-10-30'})),
      HealthCategory.sleep: null,
      HealthCategory.heartRate: parseRange(
        HealthCategory.heartRate,
        heartRaw([heartDay('2026-11-02', 100, 7000, 50, 120)]),
      ),
      HealthCategory.exercise: null,
    };

    test('résumé : période, jours manquants, aucun appareil', () {
      final text = analysisSummary(
        data: data,
        categories: {HealthCategory.steps, HealthCategory.heartRate},
        end: '2026-11-02',
        today: sampleToday,
        days: 7,
        zone: 'Africa/Tunis',
      );
      expect(
        text,
        contains('du mardi 27 octobre 2026 au lundi 2 novembre 2026'),
      );
      expect(text, contains('1 sans donnée'));
      expect(text, contains('Health Sync'));
      expect(text, isNot(contains('WATCH')));
      expect(text, isNot(contains('HUAWEI')));
      expect(text, isNot(contains('nl.appyhapps')));
      expect(text, isNot(contains('Sommeil')));
    });

    ExportFile export(ExportFormat format, {bool detailed = false}) =>
        buildExport(
          data: data,
          categories: {HealthCategory.steps},
          from: '2026-10-30',
          to: '2026-11-01',
          today: sampleToday,
          zone: 'Africa/Tunis',
          format: format,
          detailed: detailed,
          generatedAt: sampleNow,
        );

    test('export JSON : exactement la sélection', () {
      final file = export(ExportFormat.json);
      expect(file.name, 'nexora-activite-2026-10-30-2026-11-01.json');
      final json = jsonDecode(file.content) as Map<String, dynamic>;
      expect(json['fuseau'], 'Africa/Tunis');
      expect(json['niveau'], 'agregats');
      final categories = json['categories'] as List;
      expect(categories.map((c) => c['categorie']), ['steps']);
      final days = categories.single['jours'] as List;
      expect(days.map((d) => d['date']), [
        '2026-10-30',
        '2026-10-31',
        '2026-11-01',
      ]);
      expect(days.first['etat'], 'sans_donnee');
      expect(days.first['valeur'], isNull);
      expect(categories.single['unite'], 'pas');
      expect(file.content, isNot(contains('WATCH')));
      expect(file.content, isNot(contains('heart_rate')));
    });

    test('export CSV : agrégats par défaut, détail sur choix distinct', () {
      final csv = export(ExportFormat.csv);
      final rows = csv.content
          .split('\n')
          .where((l) => l.startsWith('steps,'))
          .toList();
      expect(rows, [
        'steps,2026-10-30,sans_donnee,,pas,,,,',
        'steps,2026-10-31,complet,8000,pas,,,,',
        'steps,2026-11-01,complet,8000,pas,,,,',
      ]);
      expect(csv.content, contains('# Pas : Health Sync (unité pas)'));
      expect(csv.content, isNot(contains('WATCH')));

      final detailed = export(ExportFormat.csv, detailed: true);
      expect(detailed.name, endsWith('-detail.csv'));
      expect(detailed.content, contains('WATCH GT 5 Pro'));
      expect(detailed.content, isNot(contains('2026-11-02')));
    });
  });
}

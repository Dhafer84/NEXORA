import 'dart:convert';

import 'package:intl/intl.dart' show DateFormat, NumberFormat;

import '../health/health_service.dart';
import '../health/health_summary.dart';
import 'activity_models.dart';
import 'activity_stats.dart';

/// Period figures shared by « Analyser avec l’IA » and the export, computed
/// on the phone from the local copy. A day without data never counts as 0.

final _number = NumberFormat.decimalPattern('fr_FR');
final _day = DateFormat('EEEE d MMMM y', 'fr_FR');

String _n(num value) => _number.format(value.round());
String _date(DayKey day) => _day.format(parseDay(day));

/// Source used for [category] in reports: the same default as the screens.
String? reportSource(RangeData data) => switch (data) {
  StepsData() => defaultStepsSource(data),
  SleepData() => defaultSleepSource(data),
  HeartData() => defaultHeartSource(data),
  ExerciseData() => allSources,
  _ => null,
};

/// Application name only: device models and identifiers stay on the phone.
String reportSourceName(String? source, RangeData data) {
  if (source == null) return 'aucune source';
  if (source == allSources) {
    return data is StepsData
        ? 'total Health Connect, toutes sources sans double compte'
        : 'toutes sources, doublons retirés';
  }
  return appName(source);
}

// ----- AI summary ------------------------------------------------------------------

/// Exact text sent to the AI after confirmation: totals, means, spread and
/// coverage of the [days] days ending [end], for the [categories] chosen.
/// No per-entry value, no device, no time of a single measurement.
String analysisSummary({
  required Map<HealthCategory, RangeData?> data,
  required Set<HealthCategory> categories,
  required DayKey end,
  required DayKey today,
  required int days,
  required String zone,
}) {
  final w = windows(end, days);
  final lines = <String>[
    'Résumé d’activité calculé par NEXORA sur le téléphone.',
    'Période : du ${_date(w.current.first)} au ${_date(w.current.last)} '
        '($days jours, journée en cours exclue), fuseau $zone.',
    'Règles : un jour sans donnée n’est pas compté comme zéro ; les moyennes '
        'portent sur les jours complets ; la période précédente compte $days jours.',
  ];
  for (final category in HealthCategory.values) {
    if (!categories.contains(category)) continue;
    final d = data[category];
    lines.add('');
    if (d == null) {
      lines.add(
        '${category.label} : aucune donnée lue (lecture non autorisée ou pas encore faite).',
      );
      continue;
    }
    lines.addAll(switch (d) {
      StepsData() => _stepsLines(d, w, today),
      SleepData() => _sleepLines(d, w),
      HeartData() => _heartLines(d, w, today),
      ExerciseData() => _exerciseLines(d, w.current),
      _ => const <String>[],
    });
  }
  return lines.join('\n');
}

String _coverage(PeriodStats s) => [
  '${s.complete} jour${s.complete > 1 ? 's' : ''} complet${s.complete > 1 ? 's' : ''} sur ${s.days}',
  if (s.partial > 0) '${s.partial} partiel${s.partial > 1 ? 's' : ''}',
  if (s.missing > 0) '${s.missing} sans donnée',
].join(', ');

String _evolution(Comparison c, String Function(num) format) => c.comparable
    ? 'évolution : ${percent(c.change!)} par rapport à la période précédente '
          '(moyenne ${format(c.previousMean!)})'
    : 'comparaison avec la période précédente non pertinente : ${c.reason}';

typedef _Windows = ({List<DayKey> current, List<DayKey> previous});

List<String> _stepsLines(StepsData d, _Windows w, DayKey today) {
  final source = defaultStepsSource(d);
  final stats = PeriodStats(stepsSeries(d, source, w.current, today));
  final previous = PeriodStats(stepsSeries(d, source, w.previous, today));
  String fmt(num v) => '${_n(v)} pas';
  return [
    'Pas (source : ${reportSourceName(source, d)}) :',
    stats.mean == null
        ? '- aucune journée complète sur la période.'
        : '- moyenne ${fmt(stats.mean!)} par jour complet ; minimum ${fmt(stats.min!)}, '
              'maximum ${fmt(stats.max!)} ; total ${fmt(stats.total)} (jours partiels compris).',
    '- couverture : ${_coverage(stats)}.',
    '- ${_evolution(compare(stats, previous), fmt)}.',
  ];
}

List<String> _sleepLines(SleepData d, _Windows w) {
  final source = defaultSleepSource(d);
  final byDay = nights(d, source);
  final stats = PeriodStats(sleepSeries(byDay, w.current));
  final previous = PeriodStats(sleepSeries(byDay, w.previous));
  final inPeriod = [for (final day in w.current) ?byDay[day]];
  final stages = <int, int>{};
  for (final n in inPeriod) {
    n.stages.forEach((k, v) => stages[k] = (stages[k] ?? 0) + v);
  }
  final staged = inPeriod.where((n) => n.stages.isNotEmpty).length;
  return [
    'Sommeil (source : ${reportSourceName(source, d)} ; chaque nuit est comptée au jour du réveil) :',
    stats.mean == null
        ? '- aucune nuit enregistrée sur la période.'
        : '- durée moyenne ${hoursMinutes(stats.mean!)} par nuit enregistrée ; minimum '
              '${hoursMinutes(stats.min!)}, maximum ${hoursMinutes(stats.max!)}.',
    '- nuits enregistrées : ${stats.complete} sur ${stats.days}'
        '${stats.missing > 0 ? ' (${stats.missing} sans donnée)' : ''}.',
    if (staged > 0)
      '- phases sur $staged nuit${staged > 1 ? 's' : ''} : '
          '${[for (final s in stages.entries) '${sleepStageNames[s.key] ?? 'phase ${s.key}'} ${hoursMinutes(s.value / staged)} en moyenne'].join(', ')}.',
    '- ${_evolution(compare(stats, previous), hoursMinutes)}.',
  ];
}

List<String> _heartLines(HeartData d, _Windows w, DayKey today) {
  final source = defaultHeartSource(d);
  if (source == null) return ['Fréquence cardiaque : aucune mesure lue.'];
  final byDay = heartDays(d, source);
  final stats = HeartStats([for (final day in w.current) ?byDay[day]]);
  final daily = PeriodStats(heartSeries(d, source, w.current, today));
  final previous = PeriodStats(heartSeries(d, source, w.previous, today));
  String fmt(num v) => '${v.round()} bpm';
  return [
    'Fréquence cardiaque (source : ${reportSourceName(source, d)}) :',
    stats.mean == null
        ? '- aucune mesure sur la période.'
        : '- moyenne ${fmt(stats.mean!)} sur ${_n(stats.count)} mesures ; minimum '
              '${fmt(stats.min!)}, maximum ${fmt(stats.max!)}.',
    '- couverture : ${stats.daysWithData} jour${stats.daysWithData > 1 ? 's' : ''} avec mesures sur '
        '${w.current.length}'
        '${stats.meanHours == null ? '' : ', ${stats.meanHours!.toStringAsFixed(1).replaceAll('.', ',')} heures couvertes par jour en moyenne'}.',
    '- ${_evolution(compare(daily, previous), fmt)} (moyennes journalières).',
  ];
}

List<String> _exerciseLines(ExerciseData d, List<DayKey> days) {
  final inPeriod = days.toSet();
  final all = [
    for (final s in d.sessions)
      if (inPeriod.contains(s.date)) s,
  ];
  final deduped = dedupeWorkouts(all);
  final kept = deduped.kept;
  final minutes = kept.fold(0, (a, s) => a + s.minutes);
  final byType = <String, int>{};
  for (final s in kept) {
    final name = exerciseName(s.type);
    byType[name] = (byType[name] ?? 0) + 1;
  }
  final distances = kept.where((s) => s.distanceMeters != null);
  final km = distances.fold<double>(0, (a, s) => a + s.distanceMeters!) / 1000;
  final weeks = weeklyWorkouts(kept, days);
  return [
    'Entraînements (toutes sources, doublons retirés) :',
    '- ${kept.length} séance${kept.length > 1 ? 's' : ''}, durée totale ${hoursMinutes(minutes)}'
        '${deduped.duplicates > 0 ? ' ; ${deduped.duplicates} doublon${deduped.duplicates > 1 ? 's' : ''} retiré${deduped.duplicates > 1 ? 's' : ''}' : ''}.',
    if (byType.isNotEmpty)
      '- types : ${[for (final t in byType.entries) '${t.key} ${t.value}'].join(', ')}.',
    if (!d.distanceGranted)
      '- distances : lecture non autorisée.'
    else if (distances.isNotEmpty)
      '- distance : ${km.toStringAsFixed(1).replaceAll('.', ',')} km sur ${distances.length} séance${distances.length > 1 ? 's' : ''} qui l’indiquent.',
    if (weeks.length > 1)
      '- par semaine (du lundi) : ${[for (final wk in weeks) '${wk.sessions} séance${wk.sessions > 1 ? 's' : ''}${wk.partial ? ' (semaine incomplète)' : ''}'].join(' ; ')}.',
  ];
}

// ----- Export ------------------------------------------------------------------

enum ExportFormat { csv, json }

class ExportFile {
  const ExportFile(this.name, this.mime, this.content);

  final String name;
  final String mime;
  final String content;
}

String _state(DayState s) => switch (s) {
  DayState.complete => 'complet',
  DayState.partial => 'partiel',
  DayState.missing => 'sans_donnee',
};

/// One row per day and category (aggregates), or one per entry and source
/// when [detailed]. Only the selected categories and days are included.
ExportFile buildExport({
  required Map<HealthCategory, RangeData?> data,
  required Set<HealthCategory> categories,
  required DayKey from,
  required DayKey to,
  required DayKey today,
  required String zone,
  required ExportFormat format,
  required bool detailed,
  required DateTime generatedAt,
  String app = 'NEXORA',
}) {
  final days = daysBetween(from, to);
  final selected = [
    for (final c in HealthCategory.values)
      if (categories.contains(c)) c,
  ];
  final sections = <Map<String, Object?>>[
    for (final c in selected) _section(c, data[c], days, today, detailed),
  ];
  final name =
      'nexora-activite-$from-$to${detailed ? '-detail' : ''}.${format.name}';
  final meta = <String, Object?>{
    'generateur': app,
    'genere_le': generatedAt.toUtc().toIso8601String(),
    'periode': {'du': from, 'au': to, 'jours': days.length},
    'fuseau': zone,
    'niveau': detailed ? 'detail' : 'agregats',
    'regles': [
      'Un jour sans donnée est marqué sans_donnee et n’est jamais compté comme zéro.',
      'Une journée partielle est en cours ou s’arrête tôt (dernière entrée avant 21 h).',
      'Une nuit est comptée au jour du réveil.',
      'Pas : une seule source par jour, jamais l’addition de plusieurs sources.',
    ],
  };
  return switch (format) {
    ExportFormat.json => ExportFile(
      name,
      'application/json',
      const JsonEncoder.withIndent(
        '  ',
      ).convert({...meta, 'categories': sections}),
    ),
    ExportFormat.csv => ExportFile(
      name,
      'text/csv',
      _csv(meta, sections, detailed),
    ),
  };
}

Map<String, Object?> _section(
  HealthCategory category,
  RangeData? d,
  List<DayKey> days,
  DayKey today,
  bool detailed,
) {
  final base = <String, Object?>{
    'categorie': category.wire,
    'libelle': category.label,
  };
  if (d == null) return {...base, 'etat': 'non_lue', 'jours': const []};
  final source = reportSource(d);
  final inPeriod = days.toSet();
  base['source'] = reportSourceName(source, d);
  base['derniere_lecture'] = d.readAt.toIso8601String();
  switch (d) {
    case StepsData():
      base['unite'] = 'pas';
      base['jours'] = [
        for (final p in stepsSeries(d, source!, days, today))
          {'date': p.day, 'etat': _state(p.state), 'valeur': p.value},
      ];
      if (detailed) {
        base['par_source'] = [
          for (final o in d.origins)
            {
              'source': o.source.app,
              'appareil': o.source.device,
              'jours': [
                for (final day in days)
                  if (o.days[day] case final v?) {'date': day, 'valeur': v},
              ],
            },
        ];
      }
    case SleepData():
      final byDay = nights(d, source!);
      base['unite'] = 'min';
      base['jours'] = [
        for (final day in days)
          if (byDay[day] case final n?)
            {
              'date': day,
              'etat': 'complet',
              'valeur': n.minutes,
              'coucher': n.bedtime,
              'reveil': n.wake,
              'phases_min': {
                for (final s in n.stages.entries)
                  sleepStageNames[s.key] ?? 'phase ${s.key}': s.value,
              },
            }
          else
            {'date': day, 'etat': 'sans_donnee', 'valeur': null},
      ];
      if (detailed) {
        base['sessions'] = [
          for (final s in d.sessions)
            if (inPeriod.contains(s.date))
              {
                'nuit_du': s.date,
                'debut': s.startLocal,
                'fin': s.endLocal,
                'duree_min': s.minutes,
                'source': s.source.app,
                'appareil': s.source.device,
              },
        ];
      }
    case HeartData():
      base['unite'] = 'bpm';
      if (source == null) {
        base['jours'] = [
          for (final day in days)
            {'date': day, 'etat': 'sans_donnee', 'valeur': null},
        ];
        break;
      }
      final byDay = heartDays(d, source);
      base['jours'] = [
        for (final p in heartSeries(d, source, days, today))
          {
            'date': p.day,
            'etat': _state(p.state),
            'valeur': p.value,
            if (byDay[p.day] case final h?) ...{
              'min': h.min,
              'max': h.max,
              'mesures': h.count,
              'heures_couvertes': h.hours,
            },
          },
      ];
      if (detailed) {
        base['par_source'] = [
          for (final o in d.origins.values)
            {
              'source': o.source.app,
              'appareil': o.source.device,
              'jours': [
                for (final h in d.days)
                  if (h.origin == o.source.origin && inPeriod.contains(h.date))
                    {
                      'date': h.date,
                      'moyenne': (h.sum / h.count).round(),
                      'min': h.min,
                      'max': h.max,
                      'mesures': h.count,
                    },
              ],
            },
        ];
      }
    case ExerciseData():
      final kept = workoutsFor(d, allSources, days);
      base['unite'] = 'min';
      base['distance_autorisee'] = d.distanceGranted;
      base['jours'] = [
        for (final day in days)
          if (kept.where((s) => s.date == day).toList() case final list
              when list.isNotEmpty)
            {
              'date': day,
              'etat': 'complet',
              'valeur': list.fold(0, (a, s) => a + s.minutes),
              'seances': list.length,
            }
          else
            {'date': day, 'etat': 'sans_donnee', 'valeur': null},
      ];
      base['seances'] = [
        for (final s
            in detailed
                ? [
                    for (final s in d.sessions)
                      if (inPeriod.contains(s.date)) s,
                  ]
                : kept.reversed)
          {
            'date': s.date,
            'type': exerciseName(s.type),
            'duree_min': s.minutes,
            'distance_km': s.distanceMeters == null
                ? null
                : double.parse((s.distanceMeters! / 1000).toStringAsFixed(2)),
            if (detailed) ...{
              'debut': s.startLocal,
              'fin': s.endLocal,
              'source': s.source.app,
              'appareil': s.source.device,
            },
          },
      ];
  }
  return base;
}

String _cell(Object? value) {
  final text = switch (value) {
    null => '',
    double v => v.toString(),
    _ => '$value',
  };
  return RegExp(r'[",\n;]').hasMatch(text)
      ? '"${text.replaceAll('"', '""')}"'
      : text;
}

String _csv(
  Map<String, Object?> meta,
  List<Map<String, Object?>> sections,
  bool detailed,
) {
  final period = meta['periode']! as Map<String, Object?>;
  final out = StringBuffer()
    ..writeln(
      '# Export NEXORA (${meta['niveau']}) du ${period['du']} au ${period['au']}, fuseau ${meta['fuseau']}',
    )
    ..writeln('# Généré le ${meta['genere_le']}');
  for (final rule in meta['regles']! as List) {
    out.writeln('# $rule');
  }
  for (final s in sections) {
    out.writeln(
      '# ${s['libelle']} : ${s['source'] ?? 'non lue'}${s['unite'] == null ? '' : ' (unité ${s['unite']})'}',
    );
  }
  out.writeln('categorie,date,etat,valeur,unite,min,max,mesures,seances');
  for (final s in sections) {
    for (final day in s['jours']! as List) {
      final row = day as Map<String, Object?>;
      out.writeln(
        [
          s['categorie'],
          row['date'],
          row['etat'],
          row['valeur'],
          s['unite'],
          row['min'],
          row['max'],
          row['mesures'],
          row['seances'],
        ].map(_cell).join(','),
      );
    }
  }
  final entries = [
    for (final s in sections)
      for (final e
          in (s['seances'] as List? ?? const []).cast<Map<String, Object?>>())
        [
          s['categorie'],
          e['date'],
          e['type'],
          e['duree_min'],
          e['distance_km'],
          e['debut'],
          e['fin'],
          e['source'],
          e['appareil'],
        ],
    if (detailed)
      for (final s in sections)
        for (final e
            in (s['sessions'] as List? ?? const [])
                .cast<Map<String, Object?>>())
          [
            s['categorie'],
            e['nuit_du'],
            'sommeil',
            e['duree_min'],
            null,
            e['debut'],
            e['fin'],
            e['source'],
            e['appareil'],
          ],
  ];
  if (entries.isNotEmpty) {
    out
      ..writeln()
      ..writeln(
        'categorie,date,type,duree_min,distance_km,debut,fin,source,appareil',
      );
    for (final e in entries) {
      out.writeln(e.map(_cell).join(','));
    }
  }
  if (detailed) {
    final perSource = [
      for (final s in sections)
        for (final o
            in (s['par_source'] as List? ?? const [])
                .cast<Map<String, Object?>>())
          for (final d in (o['jours']! as List).cast<Map<String, Object?>>())
            [
              s['categorie'],
              d['date'],
              d['valeur'] ?? d['moyenne'],
              s['unite'],
              d['min'],
              d['max'],
              d['mesures'],
              o['source'],
              o['appareil'],
            ],
    ];
    if (perSource.isNotEmpty) {
      out
        ..writeln()
        ..writeln(
          'categorie,date,valeur,unite,min,max,mesures,source,appareil',
        );
      for (final e in perSource) {
        out.writeln(e.map(_cell).join(','));
      }
    }
  }
  return out.toString();
}

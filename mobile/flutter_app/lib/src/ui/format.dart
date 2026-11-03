import 'package:intl/intl.dart';

/// Server timestamps are UTC; they are always shown in the phone's time zone.
String formatDateTime(DateTime value) =>
    DateFormat('d MMM yyyy à HH:mm', 'fr_FR').format(value.toLocal());

String formatTime(DateTime value) =>
    DateFormat('HH:mm', 'fr_FR').format(value.toLocal());

String formatShort(DateTime value, {DateTime? now}) {
  final local = value.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final sameDay =
      local.year == today.year &&
      local.month == today.month &&
      local.day == today.day;
  return sameDay ? 'aujourd’hui à ${formatTime(value)}' : formatDateTime(value);
}

String formatPercent(double value) =>
    // Non-breaking space: the unit never wraps away from its number.
    '${NumberFormat('0.0', 'fr_FR').format(value)}\u00a0%';

String formatBytes(int bytes) {
  const units = ['o', 'Ko', 'Mo', 'Go', 'To'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${NumberFormat(unit == 0 ? '0' : '0.0', 'fr_FR').format(value)} ${units[unit]}';
}

const approvalStatusLabels = {
  'pending': 'En attente',
  'approved': 'Approuvée, non exécutée',
  'rejected': 'Refusée',
  'expired': 'Expirée',
  'consumed': 'Exécutée',
};

const riskLabels = {
  'low': 'Risque faible',
  'medium': 'Risque moyen',
  'high': 'Risque élevé',
};

const executionStatusLabels = {
  'denied': 'Refusé',
  'invalid': 'Paramètres invalides',
  'pending_approval': 'En attente de validation',
  'running': 'En cours',
  'succeeded': 'Réussi',
  'failed': 'Échec',
  'timed_out': 'Délai dépassé',
};

const toolLabels = {
  'server_metrics': 'Métriques du serveur',
  'database_status': 'État de la base',
  'test_action': 'Action de test',
  'github_report': 'Projets GitHub',
};

String toolLabel(String tool) => toolLabels[tool] ?? tool;

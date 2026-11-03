import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexora/src/ui/theme.dart';

/// WCAG 2.x contrast ratio between two opaque colours.
double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final brightness in Brightness.values) {
    group('thème ${brightness.name}', () {
      final s = nexoraScheme(brightness);
      final c = brightness == Brightness.dark
          ? NexoraColors.dark
          : NexoraColors.light;
      // Body text pairs: WCAG AA, 4.5:1.
      final text = <String, (Color, Color)>{
        'texte / fond': (s.onSurface, s.surface),
        'texte / surface': (s.onSurface, s.surfaceContainer),
        'texte secondaire / fond': (s.onSurfaceVariant, s.surface),
        'texte secondaire / surface': (s.onSurfaceVariant, s.surfaceContainer),
        'bouton principal': (s.onPrimary, s.primary),
        'conteneur principal': (s.onPrimaryContainer, s.primaryContainer),
        'conteneur menthe': (s.onSecondaryContainer, s.secondaryContainer),
        'erreur': (s.onErrorContainer, s.errorContainer),
        'bulle utilisateur': (c.onUserBubble, c.userBubble),
        'bulle NEXORA': (c.onAssistantBubble, c.assistantBubble),
        'carte validation': (c.onWarningContainer, c.warningContainer),
        'bouton validation': (c.onWarning, c.warning),
        'succès': (c.onSuccessContainer, c.successContainer),
      };
      text.forEach((name, pair) {
        test('$name ≥ 4,5:1', () {
          expect(contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
        });
      });
      // Icons, outlines and the gauge: non-text contrast, 3:1.
      final graphics = <String, (Color, Color)>{
        'icône active / fond': (s.primary, s.surface),
        'menthe / surface': (s.secondary, s.surfaceContainer),
        'ambre / fond': (c.warning, s.surface),
        'ambre / carte validation': (c.warning, c.warningContainer),
        'jauge / piste': (s.primary, c.gaugeTrack),
        'contour': (s.outline, s.surface),
      };
      graphics.forEach((name, pair) {
        test('$name ≥ 3:1', () {
          expect(contrast(pair.$1, pair.$2), greaterThanOrEqualTo(3));
        });
      });
    });
  }

  test('palette sombre du brief', () {
    final s = nexoraScheme(Brightness.dark);
    expect(s.surface, const Color(0xFF101320));
    expect(s.surfaceContainer, const Color(0xFF1C2234));
    expect(s.primary, const Color(0xFFB8A8FF));
    expect(s.secondary, const Color(0xFF7FE0C2));
    expect(NexoraColors.dark.warning, const Color(0xFFF5C67B));
  });
}

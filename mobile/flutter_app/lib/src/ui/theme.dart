import 'package:flutter/material.dart';

/// Sober NEXORA identity: one deep teal seed, Material 3 tonal palettes,
/// no external images or fonts. Contrast comes from the generated schemes.
const nexoraSeed = Color(0xFF0E6E6A);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: nexoraSeed,
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
    ),
    cardTheme: const CardThemeData(margin: EdgeInsets.zero),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// Status colours used by chips and banners, readable in both themes.
({Color background, Color foreground}) toneColors(
  ColorScheme scheme,
  String tone,
) => switch (tone) {
  'ok' => (
    background: scheme.primaryContainer,
    foreground: scheme.onPrimaryContainer,
  ),
  'warning' => (
    background: scheme.tertiaryContainer,
    foreground: scheme.onTertiaryContainer,
  ),
  'error' => (
    background: scheme.errorContainer,
    foreground: scheme.onErrorContainer,
  ),
  _ => (
    background: scheme.surfaceContainerHighest,
    foreground: scheme.onSurfaceVariant,
  ),
};

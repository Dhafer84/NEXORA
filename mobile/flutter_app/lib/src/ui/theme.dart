import 'package:flutter/material.dart';

/// NEXORA visual system: night blue surfaces, lavender commands, mint for
/// positive states and amber for validation requests. Every colour, spacing,
/// radius and text style used by the screens comes from here.
abstract final class NexoraPalette {
  static const night = Color(0xFF101320);
  static const nightSurface = Color(0xFF1C2234);
  static const lavender = Color(0xFFB8A8FF);
  static const mint = Color(0xFF7FE0C2);
  static const amber = Color(0xFFF5C67B);

  /// Ink used on lavender (avatar, bubble, user messages).
  static const ink = Color(0xFF1E1442);
}

/// Spacing scale (logical pixels).
abstract final class Space {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

/// Corner radii.
abstract final class Radii {
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
  static const pill = 999.0;
}

/// Minimum touch target (Material and Android accessibility guidance).
const minTouchTarget = 48.0;

/// Colours that a [ColorScheme] does not name: success, warning, chat bubbles.
@immutable
class NexoraColors extends ThemeExtension<NexoraColors> {
  const NexoraColors({
    required this.success,
    required this.onSuccessContainer,
    required this.successContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.userBubble,
    required this.onUserBubble,
    required this.assistantBubble,
    required this.onAssistantBubble,
    required this.gaugeTrack,
  });

  final Color success;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color onWarningContainer;
  final Color userBubble;
  final Color onUserBubble;
  final Color assistantBubble;
  final Color onAssistantBubble;
  final Color gaugeTrack;

  static const dark = NexoraColors(
    success: NexoraPalette.mint,
    successContainer: Color(0xFF173A33),
    onSuccessContainer: Color(0xFFB4F3DF),
    warning: NexoraPalette.amber,
    onWarning: Color(0xFF3F2C00),
    warningContainer: Color(0xFF3A3021),
    onWarningContainer: Color(0xFFFBE0B1),
    userBubble: NexoraPalette.lavender,
    onUserBubble: NexoraPalette.ink,
    assistantBubble: Color(0xFF262D43),
    onAssistantBubble: Color(0xFFE7E9F3),
    gaugeTrack: Color(0xFF39405A),
  );

  static const light = NexoraColors(
    success: Color(0xFF006B54),
    successContainer: Color(0xFFC6F2E3),
    onSuccessContainer: Color(0xFF002118),
    warning: Color(0xFF7A5300),
    onWarning: Color(0xFFFFFFFF),
    warningContainer: Color(0xFFFFEBC7),
    onWarningContainer: Color(0xFF2A1A00),
    userBubble: Color(0xFFE3DCFF),
    onUserBubble: NexoraPalette.ink,
    assistantBubble: Color(0xFFECEAF4),
    onAssistantBubble: Color(0xFF1A1C28),
    gaugeTrack: Color(0xFFD9D6E6),
  );

  static NexoraColors of(BuildContext context) =>
      Theme.of(context).extension<NexoraColors>()!;

  @override
  NexoraColors copyWith() => this;

  @override
  NexoraColors lerp(NexoraColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return NexoraColors(
      success: mix(success, other.success),
      successContainer: mix(successContainer, other.successContainer),
      onSuccessContainer: mix(onSuccessContainer, other.onSuccessContainer),
      warning: mix(warning, other.warning),
      onWarning: mix(onWarning, other.onWarning),
      warningContainer: mix(warningContainer, other.warningContainer),
      onWarningContainer: mix(onWarningContainer, other.onWarningContainer),
      userBubble: mix(userBubble, other.userBubble),
      onUserBubble: mix(onUserBubble, other.onUserBubble),
      assistantBubble: mix(assistantBubble, other.assistantBubble),
      onAssistantBubble: mix(onAssistantBubble, other.onAssistantBubble),
      gaugeTrack: mix(gaugeTrack, other.gaugeTrack),
    );
  }
}

const _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: NexoraPalette.lavender,
  onPrimary: Color(0xFF21183F),
  primaryContainer: Color(0xFF3B3268),
  onPrimaryContainer: Color(0xFFE6DFFF),
  secondary: NexoraPalette.mint,
  onSecondary: Color(0xFF00382A),
  secondaryContainer: Color(0xFF173A33),
  onSecondaryContainer: Color(0xFFB4F3DF),
  tertiary: NexoraPalette.amber,
  onTertiary: Color(0xFF3F2C00),
  tertiaryContainer: Color(0xFF3A3021),
  onTertiaryContainer: Color(0xFFFBE0B1),
  error: Color(0xFFFFB4AB),
  onError: Color(0xFF690005),
  errorContainer: Color(0xFF7A1F1C),
  onErrorContainer: Color(0xFFFFDAD6),
  surface: NexoraPalette.night,
  onSurface: Color(0xFFE7E9F3),
  onSurfaceVariant: Color(0xFFB6BBCE),
  surfaceContainerLowest: Color(0xFF0B0E18),
  surfaceContainerLow: Color(0xFF151A29),
  surfaceContainer: NexoraPalette.nightSurface,
  surfaceContainerHigh: Color(0xFF242B40),
  surfaceContainerHighest: Color(0xFF2D3550),
  outline: Color(0xFF80869E),
  outlineVariant: Color(0xFF353C54),
  inverseSurface: Color(0xFFE7E9F3),
  onInverseSurface: NexoraPalette.nightSurface,
  inversePrimary: Color(0xFF5B47C7),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  surfaceTint: Colors.transparent,
);

const _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF5B47C7),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFE3DCFF),
  onPrimaryContainer: NexoraPalette.ink,
  secondary: Color(0xFF006B54),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFC6F2E3),
  onSecondaryContainer: Color(0xFF002118),
  tertiary: Color(0xFF7A5300),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFFFEBC7),
  onTertiaryContainer: Color(0xFF2A1A00),
  error: Color(0xFFBA1A1A),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFFDAD6),
  onErrorContainer: Color(0xFF410002),
  surface: Color(0xFFF7F6FC),
  onSurface: Color(0xFF1A1C28),
  onSurfaceVariant: Color(0xFF474A5C),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFF1F0F8),
  surfaceContainer: Color(0xFFECEAF4),
  surfaceContainerHigh: Color(0xFFE6E4EF),
  surfaceContainerHighest: Color(0xFFE0DEEA),
  outline: Color(0xFF75788C),
  outlineVariant: Color(0xFFCAC9D8),
  inverseSurface: NexoraPalette.nightSurface,
  onInverseSurface: Color(0xFFE7E9F3),
  inversePrimary: NexoraPalette.lavender,
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  surfaceTint: Colors.transparent,
);

ColorScheme nexoraScheme(Brightness brightness) =>
    brightness == Brightness.dark ? _darkScheme : _lightScheme;

ThemeData buildTheme(Brightness brightness) {
  final scheme = nexoraScheme(brightness);
  final colors = brightness == Brightness.dark
      ? NexoraColors.dark
      : NexoraColors.light;
  final base = Typography.material2021(platform: TargetPlatform.android);
  final text = (brightness == Brightness.dark ? base.white : base.black)
      .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface)
      .copyWith(
        // Brand title "NEXORA" in headers.
        titleLarge: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
        titleMedium: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        bodyLarge: const TextStyle(fontSize: 16, height: 1.4),
        bodyMedium: const TextStyle(fontSize: 14, height: 1.4),
        labelLarge: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      )
      .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);
  final stadium = WidgetStatePropertyAll<OutlinedBorder>(const StadiumBorder());
  const buttonSize = WidgetStatePropertyAll(Size(64, minTouchTarget));
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    brightness: brightness,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: text,
    extensions: [colors],
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
      shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 76,
      elevation: 0,
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.surfaceContainerHighest,
      indicatorShape: const StadiumBorder(),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 26,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => text.labelMedium?.copyWith(
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.l),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(shape: stadium, minimumSize: buttonSize),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(shape: stadium, minimumSize: buttonSize),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(shape: stadium, minimumSize: buttonSize),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: const StadiumBorder(),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.l),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.l),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.l),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      minVerticalPadding: Space.m,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.xl),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.m),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainer,
      showDragHandle: true,
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: scheme.outlineVariant),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: colors.gaugeTrack,
    ),
    badgeTheme: BadgeThemeData(
      backgroundColor: colors.warning,
      textColor: colors.onWarning,
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
    background: scheme.secondaryContainer,
    foreground: scheme.onSecondaryContainer,
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

import 'package:flutter/material.dart';

const _seed = Color(0xFF12496B);

/// The "showroom" palette: a deep blue-black ground (the same world as the
/// sign-in photograph), cards as a slightly lighter material with a hairline
/// edge, and the brand blue lifted so it reads on a dark ground.
const kShowroomGround = Color(0xFF0B1219);
const kShowroomSurface = Color(0xFF131D27);
const kShowroomSurfaceHigh = Color(0xFF192531);
const kShowroomEdge = Color(0x14FFFFFF); // white 8%
const kShowroomEdgeBright = Color(0x24FFFFFF); // white 14%

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: Brightness.dark,
  ).copyWith(
    surface: kShowroomGround,
    surfaceContainerLowest: kShowroomGround,
    surfaceContainerLow: kShowroomSurface,
    surfaceContainer: kShowroomSurface,
    surfaceContainerHigh: kShowroomSurfaceHigh,
    surfaceContainerHighest: const Color(0xFF1F2D3A),
    outlineVariant: kShowroomEdge,
    outline: const Color(0xFF6E8190),
  );

  // Tracking is size-specific: large text tightens, small labels open up.
  final base = ThemeData(useMaterial3: true, colorScheme: scheme).textTheme;
  final text = base.copyWith(
    headlineSmall: base.headlineSmall?.copyWith(
      letterSpacing: -0.4,
      height: 1.15,
      fontWeight: FontWeight.w700,
    ),
    titleLarge: base.titleLarge?.copyWith(
      letterSpacing: -0.3,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: base.titleMedium?.copyWith(letterSpacing: -0.1),
    titleSmall: base.titleSmall?.copyWith(letterSpacing: 0.4),
    labelSmall: base.labelSmall?.copyWith(letterSpacing: 0.6),
    bodySmall: base.bodySmall?.copyWith(letterSpacing: 0.1),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: text,
    scaffoldBackgroundColor: kShowroomGround,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: kShowroomGround,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardTheme(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: kShowroomSurface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kShowroomEdge),
      ),
    ),
    dialogTheme: DialogTheme(
      backgroundColor: kShowroomSurfaceHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: kShowroomSurfaceHigh,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: kShowroomSurfaceHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: kShowroomSurfaceHigh,
      contentTextStyle: TextStyle(color: scheme.onSurface),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kShowroomSurface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kShowroomEdgeBright),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kShowroomEdgeBright),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 14,
      ),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    dividerTheme: const DividerThemeData(color: kShowroomEdge, space: 1),
    chipTheme: ChipThemeData(
      side: const BorderSide(color: kShowroomEdgeBright),
      backgroundColor: kShowroomSurface,
      selectedColor: scheme.primary.withValues(alpha: 0.22),
      labelStyle: TextStyle(color: scheme.onSurface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
  );
}

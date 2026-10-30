import 'package:flutter/material.dart';

/// Bảng màu giống bản demo web (xanh lá đậm, nền xám xanh nhạt; có chế độ tối).
class AppColors {
  static const accent = Color(0xFF1C6B52);
  static const accentDark = Color(0xFF4FBF8E);
  static const income = Color(0xFF1E8A5A);
  static const incomeDark = Color(0xFF5BCB92);
  static const expense = Color(0xFFC2463B);
  static const expenseDark = Color(0xFFEE7A6E);
  static const warn = Color(0xFFB7790C);
  static const warnDark = Color(0xFFE3AE48);
}

extension ThemeX on BuildContext {
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
  Color get incomeColor => isDark ? AppColors.incomeDark : AppColors.income;
  Color get expenseColor => isDark ? AppColors.expenseDark : AppColors.expense;
  Color get warnColor => isDark ? AppColors.warnDark : AppColors.warn;
  Color get muted => Theme.of(this).colorScheme.onSurfaceVariant;
  ColorScheme get cs => Theme.of(this).colorScheme;
}

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: b,
    primary: dark ? AppColors.accentDark : AppColors.accent,
    surface: dark ? const Color(0xFF161E1B) : Colors.white,
    error: dark ? AppColors.expenseDark : AppColors.expense,
  );
  var text = ThemeData(brightness: b).textTheme.apply(fontFamily: 'BeVietnamPro');
  TextStyle? display(TextStyle? s) => s?.copyWith(fontFamily: 'Lexend', fontWeight: FontWeight.w600);
  text = text.copyWith(
    headlineLarge: display(text.headlineLarge),
    headlineMedium: display(text.headlineMedium),
    headlineSmall: display(text.headlineSmall),
    titleLarge: display(text.titleLarge),
  );
  final bg = dark ? const Color(0xFF0D1311) : const Color(0xFFEEF2EF);
  final line = dark ? const Color(0xFF2A3631) : const Color(0xFFDCE4DF);
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'BeVietnamPro',
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    textTheme: text,
    appBarTheme: AppBarTheme(backgroundColor: bg, surfaceTintColor: Colors.transparent, centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface)),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: line)),
    ),
    dividerTheme: DividerThemeData(color: line, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: line)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
          minimumSize: const Size(48, 50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

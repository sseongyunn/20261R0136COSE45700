import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const background = Color(0xFF1A1510);
  static const surface = Color(0xFF231E17);
  static const card = Color(0xFF2C2519);
  static const border = Color(0xFF3D3428);
  static const primary = Color(0xFFD4845A);
  static const primaryLight = Color(0xFFE8A070);
  static const accent = Color(0xFFF0C878);
  static const textPrimary = Color(0xFFEDE0CF);
  static const textSecondary = Color(0xFF8C7B69);
  static const textTertiary = Color(0xFF5C4E40);
  static const success = Color(0xFF7BA890);
  static const successBg = Color(0xFF1E2B25);
}

class AppTheme {
  static ThemeData get theme {
    final base = GoogleFonts.nunitoTextTheme();
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: ColorScheme.dark(
        surface: AppColors.surface,
        primary: AppColors.primary,
        secondary: AppColors.accent,
        onSurface: AppColors.textPrimary,
      ),
      textTheme: base.apply(
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        titleTextStyle: GoogleFonts.nunito(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.card,
        contentTextStyle: GoogleFonts.nunito(color: AppColors.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

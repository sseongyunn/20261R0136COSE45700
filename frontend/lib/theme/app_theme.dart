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
    final base = GoogleFonts.outfitTextTheme();
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
        titleTextStyle: GoogleFonts.outfit(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppColors.card,
        contentTextStyle: GoogleFonts.outfit(color: AppColors.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class AuthColors {
  static const charcoalButton = Color(0xFF2A2A2E);

  // 🌈 시안 A: CSS 319deg 사선 선형 그라데이션 (카키/올리브 ~ 미스티 로즈 ~ 아이보리)
  static const linearGradientPreset = LinearGradient(
    begin: Alignment.bottomRight,
    end: Alignment.topLeft,
    colors: [
      Color(0xFF525025),
      Color(0xFFFFE4E1),
      Color(0xFFFCF5E5),
    ],
    stops: [0.0, 0.37, 1.0],
  );

  // 🌈 시안 B (최종 튜닝): CSS 원형 방사 그라데이션 (피치 핑크 ~ 슬레이트 그레이 ~ 샌드 아이보리)
  static const radialGradientPreset = RadialGradient(
    center: Alignment.center,
    radius: 1.2,
    colors: [
      Color(0xFFD3AD97),
      Color(0xFFB1AFAF),
      Color(0xFFDBC9A9),
    ],
    stops: [0.0, 0.5, 1.0],
  );

  // 🌈 신규 뉴트럴 대각선 그라데이션 (밀크 오프화이트 ~ 뮤트 파치먼트 베이지)
  static const neutralGradientPreset = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFFFAF8F5),
      Color(0xFFEDE8E2),
    ],
  );
}

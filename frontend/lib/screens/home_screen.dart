import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../providers/pending_jobs_provider.dart';
import '../theme/app_theme.dart';
import 'gallery_screen.dart';
import 'upload_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _assetCount = 0;

  @override
  void initState() {
    super.initState();
    _loadAssetCount();
  }

  Future<void> _loadAssetCount() async {
    try {
      final assets = await context.read<ApiClient>().listFurnitureAssets();
      if (!mounted) return;
      setState(() => _assetCount = assets.length);
    } catch (_) {
      // Home remains usable even if the count request fails.
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = context.watch<ApiClient>();
    final runningCount = context.watch<PendingJobsProvider>().runningCount;
    final totalCount = _assetCount + runningCount;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Gap(28),
              _Logo(
                email: api.email,
                onLogout: () async {
                  await context.read<PendingJobsProvider>().clear();
                  if (!context.mounted) return;
                  await context.read<ApiClient>().logout();
                },
              ),
              const Spacer(flex: 2),
              _Headline(),
              const Gap(14),
              Text(
                'AI가 가구를 분석하고 입체 모델로 만들어드려요.\n인테리어를 상상이 아닌 눈으로 확인해보세요.',
                style: GoogleFonts.nunito(
                  fontSize: 15,
                  color: AppColors.textSecondary,
                  height: 1.65,
                ),
              ),
              const Spacer(flex: 3),
              _ActionCard(
                icon: Icons.add_photo_alternate_outlined,
                iconColor: AppColors.primary,
                iconBg: const Color(0xFF3D2518),
                title: '사진으로 3D 만들기',
                subtitle: '사진 업로드 후 VARCO 생성 요청',
                onTap: () => Navigator.push(
                  context,
                  _slide(const UploadScreen()),
                ).then((_) => _loadAssetCount()),
              ),
              const Gap(12),
              _ActionCard(
                icon: Icons.grid_view_rounded,
                iconColor: AppColors.accent,
                iconBg: const Color(0xFF352E10),
                title: '내 컬렉션',
                subtitle: runningCount > 0
                    ? '$runningCount개 모델 생성 중'
                    : '생성된 GLB 모델 모아보기',
                badge: totalCount > 0 ? '$totalCount' : null,
                onTap: () => Navigator.push(
                  context,
                  _slide(const GalleryScreen()),
                ).then((_) => _loadAssetCount()),
              ),
              const Spacer(flex: 2),
              Center(
                child: Text(
                  'AI 3D 변환 기술 탑재',
                  style: GoogleFonts.nunito(
                    fontSize: 12,
                    color: AppColors.textTertiary,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              const Gap(20),
            ],
          ),
        ),
      ),
    );
  }

  PageRouteBuilder _slide(Widget page) => PageRouteBuilder(
    pageBuilder: (context, a, secondaryAnimation) => page,
    transitionsBuilder: (context, a, secondaryAnimation, child) =>
        SlideTransition(
          position: Tween(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
    transitionDuration: const Duration(milliseconds: 320),
  );
}

class _Logo extends StatelessWidget {
  final String? email;
  final VoidCallback onLogout;

  const _Logo({required this.email, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: const Icon(
            Icons.chair_outlined,
            color: AppColors.primary,
            size: 20,
          ),
        ),
        const Gap(10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'furniFit',
                style: GoogleFonts.nunito(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              if (email != null)
                Text(
                  email!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.nunito(
                    fontSize: 11,
                    color: AppColors.textTertiary,
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          tooltip: '로그아웃',
          onPressed: onLogout,
          icon: const Icon(
            Icons.logout_rounded,
            color: AppColors.textSecondary,
            size: 20,
          ),
        ),
      ],
    );
  }
}

class _Headline extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '가구 사진 한 장으로',
          style: GoogleFonts.nunito(
            fontSize: 34,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
            height: 1.2,
          ),
        ),
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [AppColors.primary, AppColors.accent],
          ).createShader(bounds),
          child: Text(
            '나만의 3D 모델을',
            style: GoogleFonts.nunito(
              fontSize: 34,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.2,
            ),
          ),
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String subtitle;
  final String? badge;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const Gap(16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.nunito(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const Gap(2),
                  Text(
                    subtitle,
                    style: GoogleFonts.nunito(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (badge != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  badge!,
                  style: GoogleFonts.nunito(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              )
            else
              const Icon(
                Icons.arrow_forward_ios_rounded,
                color: AppColors.textTertiary,
                size: 16,
              ),
          ],
        ),
      ),
    );
  }
}

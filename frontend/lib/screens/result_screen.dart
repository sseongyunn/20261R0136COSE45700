import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/furniture_model.dart';
import '../theme/app_theme.dart';
import '../widgets/furni_image.dart';
import '../widgets/glb_model_viewer.dart';
import 'gallery_screen.dart';
import 'model_url_screen.dart';

class ResultScreen extends StatefulWidget {
  final FurnitureModel model;

  const ResultScreen({super.key, required this.model});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  void _openGallery() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const GalleryScreen()),
    );
  }

  Future<void> _copyModelUrl() async {
    final url = widget.model.modelUrl;
    if (url == null || url.isEmpty) {
      _showSnack('아직 복사할 모델 URL이 없어요');
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    _showSnack('모델 URL을 복사했어요');
  }

  void _openModelUrl() {
    final assetId = widget.model.assetId;
    if (assetId == null || assetId.isEmpty) {
      _showSnack('assetId가 없어 URL을 요청할 수 없어요');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ModelUrlScreen(
          assetId: assetId,
          initialModelUrl: widget.model.modelUrl,
        ),
      ),
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: GoogleFonts.nunito(color: AppColors.textPrimary),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.model;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('3D 모델 완성!'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
            child: Text(
              '홈으로',
              style: GoogleFonts.nunito(
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ModelViewer(model: m),
              const Gap(20),
              _DetailsCard(model: m),
              const Gap(16),
              _ActionRow(
                onShare: () => _copyModelUrl(),
                onDownload: _openModelUrl,
                onRegenerate: () => Navigator.pop(context),
              ),
              const Gap(24),
              _SaveButton(onTap: _openGallery),
              const Gap(8),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelViewer extends StatelessWidget {
  final FurnitureModel model;

  const _ModelViewer({required this.model});

  Future<void> _launchAR(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'AR을 열 수 없어요. 기기가 AR을 지원하는지 확인해 주세요.',
              style: GoogleFonts.nunito(),
            ),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'AR 실행 중 오류가 발생했어요.',
              style: GoogleFonts.nunito(),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasModel = model.modelUrl != null && model.modelUrl!.isNotEmpty;
    final modelUrl = model.modelUrl ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 3D 뷰어 (S3 → 로컬 파일 다운로드 후 렌더링) ──
        Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: hasModel
                  ? GlbModelViewer(modelUrl: modelUrl, height: 320)
                  : SizedBox(
                      height: 320,
                      child: FurniImage(imagePath: model.imagePath),
                    ),
            ),
            // 좌상단 배지
            Positioned(
              top: 12,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: hasModel ? AppColors.primary : AppColors.textTertiary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const Gap(6),
                    Text(
                      hasModel ? '3D 뷰어 · 드래그로 회전' : '2D 미리보기',
                      style: GoogleFonts.nunito(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        // ── AR 보기 버튼 ──
        if (hasModel) ...[
          const Gap(12),
          GestureDetector(
            onTap: () => _launchAR(context, modelUrl),
            child: Container(
              height: 50,
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.primary.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.view_in_ar_rounded,
                      color: AppColors.primary, size: 20),
                  const Gap(8),
                  Text(
                    'AR로 실제 공간에서 보기',
                    style: GoogleFonts.nunito(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _DetailsCard extends StatelessWidget {
  final FurnitureModel model;

  const _DetailsCard({required this.model});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  model.name,
                  style: GoogleFonts.nunito(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const Gap(12),
              _CategoryChip(label: model.category),
            ],
          ),
          const Gap(18),
          const Divider(color: AppColors.border, height: 1),
          const Gap(18),
          Row(
            children: [
              Expanded(
                child: _Detail(label: '크기', value: model.dimensions),
              ),
              const Gap(16),
              Expanded(
                child: _Detail(label: '재질', value: model.material),
              ),
            ],
          ),
          const Gap(16),
          Row(
            children: [
              Expanded(
                child: _Detail(
                  label: '처리 시간',
                  value: '${model.processingSeconds}초',
                ),
              ),
              const Gap(16),
              Expanded(
                child: _Detail(label: '생성일', value: _fmt(model.createdAt)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime dt) =>
      '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';
}

class _CategoryChip extends StatelessWidget {
  final String label;

  const _CategoryChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: GoogleFonts.nunito(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.primary,
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  final String label;
  final String value;

  const _Detail({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.nunito(
            fontSize: 12,
            color: AppColors.textTertiary,
            letterSpacing: 0.3,
          ),
        ),
        const Gap(4),
        Text(
          value,
          style: GoogleFonts.nunito(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  final VoidCallback onShare;
  final VoidCallback onDownload;
  final VoidCallback onRegenerate;

  const _ActionRow({
    required this.onShare,
    required this.onDownload,
    required this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _ActionBtn(icon: Icons.share_rounded, label: '공유', onTap: onShare),
        const Gap(10),
        _ActionBtn(
          icon: Icons.download_rounded,
          label: '다운로드',
          onTap: onDownload,
        ),
        const Gap(10),
        _ActionBtn(
          icon: Icons.refresh_rounded,
          label: '재생성',
          onTap: onRegenerate,
        ),
      ],
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            children: [
              Icon(icon, color: AppColors.textSecondary, size: 21),
              const Gap(5),
              Text(
                label,
                style: GoogleFonts.nunito(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  final VoidCallback onTap;

  const _SaveButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        height: 58,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.primary, AppColors.accent],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.grid_view_rounded,
                color: Colors.white,
                size: 20,
              ),
              const Gap(8),
              Text(
                '내 컬렉션 보기',
                style: GoogleFonts.nunito(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/furniture_model.dart';
import '../providers/collection_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/furni_image.dart';

class ResultScreen extends StatefulWidget {
  final FurnitureModel model;

  const ResultScreen({super.key, required this.model});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  bool _saved = false;

  Future<void> _save() async {
    if (_saved) return;
    await context.read<CollectionProvider>().add(widget.model);
    if (!mounted) return;
    setState(() => _saved = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '컬렉션에 저장되었어요',
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
            onPressed: () =>
                Navigator.of(context).popUntil((r) => r.isFirst),
            child: Text(
              '홈으로',
              style: GoogleFonts.nunito(
                  fontSize: 14, color: AppColors.textSecondary),
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
              _ModelImage(path: m.imagePath),
              const Gap(20),
              _DetailsCard(model: m),
              const Gap(16),
              _ActionRow(
                onShare: () {},
                onDownload: () {},
                onRegenerate: () => Navigator.pop(context),
              ),
              const Gap(24),
              _SaveButton(saved: _saved, onTap: _save),
              const Gap(8),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelImage extends StatelessWidget {
  final String path;

  const _ModelImage({required this.path});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Stack(
        children: [
          SizedBox(
            width: double.infinity,
            height: 290,
            child: FurniImage(imagePath: path),
          ),
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                    decoration: const BoxDecoration(
                      color: AppColors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const Gap(6),
                  Text(
                    '3D 모델',
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
                  child:
                      _Detail(label: '크기', value: model.dimensions)),
              const Gap(16),
              Expanded(
                  child:
                      _Detail(label: '재질', value: model.material)),
            ],
          ),
          const Gap(16),
          Row(
            children: [
              Expanded(
                child: _Detail(
                    label: '처리 시간',
                    value: '${model.processingSeconds}초'),
              ),
              const Gap(16),
              Expanded(
                child: _Detail(
                  label: '생성일',
                  value: _fmt(model.createdAt),
                ),
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
        _ActionBtn(
            icon: Icons.share_rounded, label: '공유', onTap: onShare),
        const Gap(10),
        _ActionBtn(
            icon: Icons.download_rounded,
            label: '다운로드',
            onTap: onDownload),
        const Gap(10),
        _ActionBtn(
            icon: Icons.refresh_rounded,
            label: '재생성',
            onTap: onRegenerate),
      ],
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionBtn(
      {required this.icon, required this.label, required this.onTap});

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
  final bool saved;
  final VoidCallback onTap;

  const _SaveButton({required this.saved, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: saved ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        height: 58,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: saved
                ? [AppColors.card, AppColors.card]
                : [AppColors.primary, AppColors.accent],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                saved
                    ? Icons.check_circle_rounded
                    : Icons.bookmark_add_outlined,
                color: saved ? AppColors.success : Colors.white,
                size: 20,
              ),
              const Gap(8),
              Text(
                saved ? '컬렉션에 저장됨' : '내 컬렉션에 저장하기',
                style: GoogleFonts.nunito(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: saved ? AppColors.success : Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

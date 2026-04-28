import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../models/pending_generation_job.dart';
import '../providers/pending_jobs_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/furni_image.dart';
import 'model_url_screen.dart';
import 'processing_screen.dart';
import 'upload_screen.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  List<FurnitureAsset> _assets = [];
  Timer? _timer;
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted || _refreshing) return;
    _refreshing = true;
    final showFullLoading =
        _assets.isEmpty && context.read<PendingJobsProvider>().jobs.isEmpty;
    setState(() {
      _loading = showFullLoading;
      _error = null;
    });

    try {
      final api = context.read<ApiClient>();
      final pending = context.read<PendingJobsProvider>();

      for (final job in List<PendingGenerationJob>.from(pending.jobs)) {
        if (!job.isRunning) continue;
        final remote = await api.getGenerationJob(job.jobId);
        if (!mounted) return;
        if (remote.status == 'succeeded' && remote.assetId != null) {
          await pending.remove(remote.jobId);
        } else {
          await pending.updateFromRemote(remote);
        }
      }

      final assets = await api.listFurnitureAssets();
      if (!mounted) return;
      setState(() => _assets = assets);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = context.watch<PendingJobsProvider>().jobs;
    final totalCount = _assets.length + pending.length;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('내 컬렉션'),
            if (totalCount > 0)
              Text(
                '${_assets.length}개 완료 · ${pending.where((job) => job.isRunning).length}개 생성 중',
                style: GoogleFonts.nunito(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w400,
                ),
              ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(
          context,
          PageRouteBuilder(
            pageBuilder: (context, a, secondaryAnimation) =>
                const UploadScreen(),
            transitionsBuilder: (context, a, secondaryAnimation, child) =>
                SlideTransition(
                  position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                      .animate(
                        CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
                      ),
                  child: child,
                ),
            transitionDuration: const Duration(milliseconds: 320),
          ),
        ).then((_) => _refresh()),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        child: const Icon(Icons.add_rounded),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : _error != null
          ? _ErrorState(message: _error!, onRetry: _refresh)
          : _assets.isEmpty && pending.isEmpty
          ? const _EmptyState()
          : GridView.builder(
              padding: const EdgeInsets.all(20),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.78,
              ),
              itemCount: pending.length + _assets.length,
              itemBuilder: (_, i) {
                if (i < pending.length) {
                  return _PendingJobCard(job: pending[i]);
                }
                return _AssetCard(asset: _assets[i - pending.length]);
              },
            ),
    );
  }
}

class _PendingJobCard extends StatelessWidget {
  final PendingGenerationJob job;

  const _PendingJobCard({required this.job});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: job.isRunning
          ? () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ProcessingScreen(
                  jobId: job.jobId,
                  imagePath: job.imagePath,
                  requestedName: job.name,
                  requestedCategory: job.category,
                  requestedDimensions: job.dimensions,
                ),
              ),
            )
          : null,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: job.status == 'failed'
                ? const Color(0xFF693131)
                : AppColors.primary.withValues(alpha: 0.35),
          ),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FurniImage(imagePath: job.imagePath),
                  Container(color: Colors.black.withValues(alpha: 0.35)),
                  Center(
                    child: job.status == 'failed'
                        ? const Icon(
                            Icons.error_outline_rounded,
                            color: Color(0xFFFFB8A8),
                            size: 36,
                          )
                        : const SizedBox(
                            width: 34,
                            height: 34,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: AppColors.primary,
                            ),
                          ),
                  ),
                  Positioned(
                    left: 10,
                    top: 10,
                    child: _StatusPill(status: job.status),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.name,
                    style: GoogleFonts.nunito(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Gap(5),
                  Row(
                    children: [
                      _CategoryChip(label: job.category),
                      const Spacer(),
                      Text(
                        job.status == 'failed' ? '실패' : '생성 중',
                        style: GoogleFonts.nunito(
                          fontSize: 10,
                          color: job.status == 'failed'
                              ? const Color(0xFFFFB8A8)
                              : AppColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String status;

  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final failed = status == 'failed';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: failed
            ? const Color(0xFF3A1D1D)
            : AppColors.primary.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        failed ? 'failed' : status,
        style: GoogleFonts.nunito(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _AssetCard extends StatelessWidget {
  final FurnitureAsset asset;

  const _AssetCard({required this.asset});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ModelUrlScreen(assetId: asset.assetId),
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                color: AppColors.surface,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.view_in_ar_outlined,
                      color: AppColors.primary,
                      size: 38,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    asset.displayName,
                    style: GoogleFonts.nunito(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Gap(5),
                  Row(
                    children: [
                      _CategoryChip(label: asset.displayCategory),
                      const Spacer(),
                      Text(
                        _fmt(asset.createdAt),
                        style: GoogleFonts.nunito(
                          fontSize: 10,
                          color: AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(DateTime? dt) {
    if (dt == null) return '신규';
    return '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;

  const _CategoryChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: GoogleFonts.nunito(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: AppColors.primary,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: AppColors.card,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.chair_outlined,
              color: AppColors.textTertiary,
              size: 40,
            ),
          ),
          const Gap(20),
          Text(
            '아직 생성된 모델이 없어요',
            style: GoogleFonts.nunito(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
            ),
          ),
          const Gap(8),
          Text(
            '가구 사진을 업로드해서\n첫 번째 GLB 모델을 만들어보세요',
            textAlign: TextAlign.center,
            style: GoogleFonts.nunito(
              fontSize: 14,
              color: AppColors.textTertiary,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: AppColors.primary,
              size: 42,
            ),
            const Gap(16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.nunito(
                fontSize: 14,
                color: AppColors.textSecondary,
                height: 1.45,
              ),
            ),
            const Gap(18),
            TextButton(
              onPressed: onRetry,
              child: Text(
                '다시 시도',
                style: GoogleFonts.nunito(color: AppColors.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

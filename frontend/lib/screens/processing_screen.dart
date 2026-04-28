import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../models/furniture_model.dart';
import '../providers/pending_jobs_provider.dart';
import '../theme/app_theme.dart';
import 'result_screen.dart';

class ProcessingScreen extends StatefulWidget {
  final String jobId;
  final String imagePath;
  final String requestedName;
  final String requestedCategory;
  final String requestedDimensions;

  const ProcessingScreen({
    super.key,
    required this.jobId,
    required this.imagePath,
    required this.requestedName,
    required this.requestedCategory,
    required this.requestedDimensions,
  });

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen>
    with SingleTickerProviderStateMixin {
  int _step = 0;
  String _status = 'queued';
  String? _error;
  bool _polling = false;
  bool _navigating = false;
  Timer? _timer;
  late final DateTime _startedAt;
  late final AnimationController _pulse;

  static const _steps = [
    ('이미지 업로드 완료', 'S3에 원본 이미지를 저장했어요'),
    ('생성 요청 제출', 'VARCO에 3D 생성을 요청하고 있어요'),
    ('3D 모델 생성 중', '완료될 때까지 상태를 확인하고 있어요'),
    ('마무리 중', 'GLB 다운로드 링크를 준비하고 있어요'),
  ];

  @override
  void initState() {
    super.initState();
    _startedAt = DateTime.now();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_polling || _navigating) return;

    setState(() {
      _polling = true;
      _error = null;
    });

    try {
      final api = context.read<ApiClient>();
      final pendingJobs = context.read<PendingJobsProvider>();
      final job = await api.getGenerationJob(widget.jobId);
      if (!mounted) return;
      await pendingJobs.updateFromRemote(job);
      if (!mounted) return;
      setState(() {
        _status = job.status;
        _step = _stepFor(job.status);
      });

      if (job.status == 'failed') {
        _timer?.cancel();
        setState(() => _error = job.failureReason ?? '3D 생성에 실패했습니다.');
      }

      if (job.status == 'succeeded' && job.assetId != null) {
        _timer?.cancel();
        _navigating = true;
        final modelUrl = await api.getModelUrl(job.assetId!);
        await pendingJobs.remove(widget.jobId);
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            pageBuilder: (context, a, secondaryAnimation) => ResultScreen(
              model: FurnitureModel(
                id: job.assetId!,
                assetId: job.assetId!,
                generationJobId: widget.jobId,
                modelUrl: modelUrl,
                name: widget.requestedName,
                category: widget.requestedCategory,
                imagePath: widget.imagePath,
                dimensions: widget.requestedDimensions,
                material: 'VARCO GLB',
                processingSeconds: DateTime.now()
                    .difference(_startedAt)
                    .inSeconds,
                createdAt: DateTime.now(),
              ),
            ),
            transitionsBuilder: (context, a, secondaryAnimation, child) =>
                FadeTransition(
                  opacity: CurvedAnimation(parent: a, curve: Curves.easeIn),
                  child: child,
                ),
            transitionDuration: const Duration(milliseconds: 350),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _polling = false);
    }
  }

  int _stepFor(String status) {
    switch (status) {
      case 'queued':
        return 1;
      case 'submitted':
        return 2;
      case 'processing':
        return 3;
      case 'succeeded':
        return 4;
      default:
        return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('AI 처리 중'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            children: [
              const Spacer(),
              _PulseOrb(controller: _pulse),
              const Gap(32),
              Text(
                '변환하고 있어요',
                style: GoogleFonts.nunito(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const Gap(8),
              Text(
                '현재 상태: $_status',
                style: GoogleFonts.nunito(
                  fontSize: 15,
                  color: AppColors.textSecondary,
                ),
              ),
              if (_error != null) ...[
                const Gap(14),
                _ErrorBox(message: _error!),
              ],
              const Spacer(),
              _StepList(currentStep: _step, steps: _steps),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: _polling ? null : _refresh,
                    child: Text(
                      _polling ? '확인 중' : '새로고침',
                      style: GoogleFonts.nunito(
                        fontSize: 15,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  const Gap(12),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      '닫기',
                      style: GoogleFonts.nunito(
                        fontSize: 15,
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
              const Gap(4),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulseOrb extends StatelessWidget {
  final AnimationController controller;

  const _PulseOrb({required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, child) {
        final t = sin(controller.value * 2 * pi);
        final scale = 1.0 + t * 0.07;
        final glow = 20.0 + t * 10;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF2C1810),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.35),
                  blurRadius: glow,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: AppColors.primary,
              size: 40,
            ),
          ),
        );
      },
    );
  }
}

class _StepList extends StatelessWidget {
  final int currentStep;
  final List<(String, String)> steps;

  const _StepList({required this.currentStep, required this.steps});

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
        children: List.generate(steps.length, (i) {
          final done = i < currentStep;
          final active = i == currentStep;
          final isLast = i == steps.length - 1;
          return _StepRow(
            title: steps[i].$1,
            subtitle: steps[i].$2,
            done: done,
            active: active,
            isLast: isLast,
          );
        }),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool done;
  final bool active;
  final bool isLast;

  const _StepRow({
    required this.title,
    required this.subtitle,
    required this.done,
    required this.active,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 350),
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done
                      ? AppColors.success
                      : active
                      ? AppColors.primary.withValues(alpha: 0.15)
                      : AppColors.border,
                  border: Border.all(
                    color: done
                        ? AppColors.success
                        : active
                        ? AppColors.primary
                        : AppColors.textTertiary.withValues(alpha: 0.3),
                    width: 1.5,
                  ),
                ),
                child: done
                    ? const Icon(
                        Icons.check_rounded,
                        color: Colors.white,
                        size: 15,
                      )
                    : active
                    ? const Padding(
                        padding: EdgeInsets.all(7),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.primary,
                          backgroundColor: Colors.transparent,
                        ),
                      )
                    : null,
              ),
              if (!isLast)
                Container(
                  width: 1.5,
                  height: 14,
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  color: done
                      ? AppColors.success.withValues(alpha: 0.35)
                      : AppColors.border,
                ),
            ],
          ),
          const Gap(14),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.nunito(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: done || active
                          ? AppColors.textPrimary
                          : AppColors.textTertiary,
                    ),
                  ),
                  if (active) ...[
                    const Gap(2),
                    Text(
                      subtitle,
                      style: GoogleFonts.nunito(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: done
                ? Text(
                    '완료',
                    style: GoogleFonts.nunito(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.success,
                    ),
                  )
                : active
                ? const SizedBox.shrink()
                : Text(
                    '대기',
                    style: GoogleFonts.nunito(
                      fontSize: 12,
                      color: AppColors.textTertiary,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;

  const _ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF3A1D1D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF693131)),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: GoogleFonts.nunito(
          fontSize: 13,
          color: const Color(0xFFFFB8A8),
          height: 1.35,
        ),
      ),
    );
  }
}

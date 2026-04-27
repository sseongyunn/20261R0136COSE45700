import 'dart:math';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';
import '../models/furniture_model.dart';
import '../theme/app_theme.dart';
import 'result_screen.dart';

class ProcessingScreen extends StatefulWidget {
  final String imagePath;

  const ProcessingScreen({super.key, required this.imagePath});

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen>
    with SingleTickerProviderStateMixin {
  int _step = 0;
  late final AnimationController _pulse;

  static const _steps = [
    ('이미지 분석 중', '형태와 윤곽을 파악하고 있어요'),
    ('가구 인식 중', '재질과 구조를 이해하고 있어요'),
    ('3D 모델 생성 중', '입체 모델을 빚어내고 있어요'),
    ('마무리 중', '깔끔하게 정리하고 있어요'),
  ];

  static const _durations = [2200, 2000, 3000, 1400];

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _run();
  }

  Future<void> _run() async {
    for (int i = 0; i < _steps.length; i++) {
      await Future.delayed(Duration(milliseconds: _durations[i]));
      if (!mounted) return;
      setState(() => _step = i + 1);
    }
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, a, __) => ResultScreen(model: _buildModel()),
        transitionsBuilder: (_, a, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeIn),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 350),
      ),
    );
  }

  FurnitureModel _buildModel() {
    const categories = ['소파', '의자', '테이블', '침대', '선반', '조명'];
    const materials = [
      '패브릭 / 우드 프레임',
      '가죽 / 메탈',
      '원목',
      '강화유리 / 스틸',
      '벨벳 / 우드',
      '린넨 / 오크',
    ];
    const namesByCategory = {
      '소파': ['모던 패브릭 소파', '스칸디 2인 소파', '미니멀 코너 소파'],
      '의자': ['다이닝 우드 체어', '벨벳 암체어', '라운지 체어'],
      '테이블': ['원형 커피 테이블', '오크 사이드 테이블', '글래스 다이닝 테이블'],
      '침대': ['플랫폼 킹 침대', '패브릭 헤드보드 침대', '원목 퀸 침대'],
      '선반': ['플로팅 월 선반', '오픈 북케이스', '빈티지 선반'],
      '조명': ['아크 플로어 램프', '미니멀 펜던트', '빈티지 테이블 램프'],
    };

    final rng = Random();
    final cat = categories[rng.nextInt(categories.length)];
    final names = namesByCategory[cat]!;
    final w = 60 + rng.nextInt(160);
    final d = 40 + rng.nextInt(80);
    final h = 30 + rng.nextInt(90);
    final secs = _durations.reduce((a, b) => a + b) ~/ 1000;

    return FurnitureModel(
      id: const Uuid().v4(),
      name: names[rng.nextInt(names.length)],
      category: cat,
      imagePath: widget.imagePath,
      dimensions: '$w × $d × $h cm',
      material: materials[rng.nextInt(materials.length)],
      processingSeconds: secs,
      createdAt: DateTime.now(),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
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
                '잠시만 기다려주세요',
                style: GoogleFonts.nunito(
                  fontSize: 15,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              _StepList(currentStep: _step, steps: _steps),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  '취소',
                  style: GoogleFonts.nunito(
                    fontSize: 15,
                    color: AppColors.textTertiary,
                  ),
                ),
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
                    ? const Icon(Icons.check_rounded,
                        color: Colors.white, size: 15)
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

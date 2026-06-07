import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/glb_model_viewer.dart';
import 'ar_view_screen.dart';

class ModelUrlScreen extends StatefulWidget {
  final String assetId;
  final String? initialModelUrl;
  final String modelName;

  const ModelUrlScreen({
    super.key,
    required this.assetId,
    this.initialModelUrl,
    required this.modelName,
  });

  @override
  State<ModelUrlScreen> createState() => _ModelUrlScreenState();
}

class _ModelUrlScreenState extends State<ModelUrlScreen> {
  String? _modelUrl;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _modelUrl = widget.initialModelUrl;
    _loading = widget.initialModelUrl == null;
    if (_loading) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final url = await context.read<ApiClient>().getModelUrl(widget.assetId);
      if (!mounted) return;
      setState(() => _modelUrl = url);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copy() async {
    final url = _modelUrl;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '모델 URL을 복사했어요',
          style: GoogleFonts.outfit(color: Colors.white),
        ),
      ),
    );
  }

  Future<void> _openExternal() async {
    final url = _modelUrl;
    if (url == null) return;
    final uri = Uri.parse(url);
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '외부 앱에서 모델 URL을 열 수 없어요.',
              style: GoogleFonts.outfit(color: Colors.white),
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '외부 앱 실행 중 오류가 발생했어요.',
              style: GoogleFonts.outfit(color: Colors.white),
            ),
          ),
        );
      }
    }
  }

  void _openAR() {
    final url = _modelUrl;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '3D 모델이 아직 준비되지 않았어요.',
            style: GoogleFonts.outfit(),
          ),
        ),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArViewScreen(
          modelUrl: url,
          modelName: widget.modelName,
          dimensions: '크기 정보 없음',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final width = MediaQuery.sizeOf(context).width;

    return Container(
      decoration: const BoxDecoration(
        gradient: AuthColors.radialGradientPreset,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            IconButton(
              tooltip: '새로고침',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            ),
          ],
        ),
        body: _loading
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: AppColors.primary),
                    const Gap(16),
                    Text(
                      '모델을 불러오는 중...',
                      style: GoogleFonts.outfit(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              )
            : _error != null
                ? _ErrorState(message: _error!, onRetry: _load)
                : Stack(
                    children: [
                      // 1. 추상 원형 백그라운드 라인 (Abstract Circle Line Art)
                      Positioned(
                        right: -60,
                        top: height * 0.12,
                        child: Container(
                          width: 280,
                          height: 280,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.15),
                              width: 1.5,
                            ),
                          ),
                        ),
                      ),
                      // 2. 에디토리얼 타이포그래피 (Editorial Typography)
                      Positioned(
                        left: 24,
                        top: 10,
                        right: 24,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.modelName,
                              style: GoogleFonts.poppins(
                                fontSize: 44,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                                height: 0.95,
                                letterSpacing: -1.5,
                              ),
                            ),
                            const Gap(12),
                            Text(
                              'AI가 정교하게 설계한 3D 가구 모델입니다.\n마우스/드래그로 각도를 확인해 보세요.',
                              style: GoogleFonts.outfit(
                                fontSize: 13,
                                fontWeight: FontWeight.w300,
                                color: Colors.white.withValues(alpha: 0.75),
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 3. 히어로 오브젝트 (3D 뷰어) - 중앙보다 약간 치우치게 배치하여 비대칭 강조
                      Positioned(
                        left: 0,
                        right: 0,
                        top: height * 0.22,
                        height: height * 0.40,
                        child: Center(
                          child: Container(
                            width: width * 0.9,
                            height: height * 0.38,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  Colors.white.withValues(alpha: 0.12),
                                  Colors.transparent,
                                ],
                                radius: 0.6,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(22),
                              child: GlbModelViewer(
                                modelUrl: _modelUrl!,
                                height: height * 0.38,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // 4. 슬라이딩 바텀 시트 (DraggableScrollableSheet)
                      DraggableScrollableSheet(
                        initialChildSize: 0.26,
                        minChildSize: 0.26,
                        maxChildSize: 0.75,
                        builder: (context, scrollController) {
                          return Container(
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                            ),
                            child: SingleChildScrollView(
                              controller: scrollController,
                              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 핸들바
                                  Center(
                                    child: Container(
                                      width: 40,
                                      height: 5,
                                      decoration: BoxDecoration(
                                        color: Colors.grey.shade300,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                  ),
                                  const Gap(20),
                                  // 상단 헤더 (이름, 카테고리 + AR 공간 배치 버튼)
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              widget.modelName,
                                              style: GoogleFonts.outfit(
                                                fontSize: 20,
                                                fontWeight: FontWeight.w800,
                                                color: const Color(0xFF2A211D),
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const Gap(4),
                                            Text(
                                              'Premium 3D Model',
                                              style: GoogleFonts.outfit(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: AppColors.primary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const Gap(12),
                                      GestureDetector(
                                        onTap: _openAR,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                          decoration: BoxDecoration(
                                            gradient: const LinearGradient(
                                              colors: [Color(0xFF6C63FF), Color(0xFF3ECFCF)],
                                              begin: Alignment.centerLeft,
                                              end: Alignment.centerRight,
                                            ),
                                            borderRadius: BorderRadius.circular(20),
                                            boxShadow: [
                                              BoxShadow(
                                                color: const Color(0xFF6C63FF).withValues(alpha: 0.2),
                                                blurRadius: 8,
                                                offset: const Offset(0, 3),
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(
                                                Icons.view_in_ar_rounded,
                                                color: Colors.white,
                                                size: 16,
                                              ),
                                              const Gap(6),
                                              Text(
                                                'AR 배치',
                                                style: GoogleFonts.outfit(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w800,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const Gap(16),
                                  const Divider(color: Color(0xFFECE7E0), height: 1),
                                  const Gap(16),
                                  // 가구 상세 메타데이터 목록 (바둑판식 2열 정렬)
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _buildMetaDetail('Designer', 'furniFit Studio'),
                                      ),
                                      Expanded(
                                        child: _buildMetaDetail('Rating', '★ 4.8 (128 reviews)'),
                                      ),
                                    ],
                                  ),
                                  const Gap(14),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _buildMetaDetail('Format', 'glTF Binary (.glb)'),
                                      ),
                                      Expanded(
                                        child: _buildMetaDetail('ID', widget.assetId),
                                      ),
                                    ],
                                  ),
                                  const Gap(20),
                                  const Divider(color: Color(0xFFECE7E0), height: 1),
                                  const Gap(16),
                                  // GLB 복사 영역
                                  Text(
                                    'GLB 다운로드 링크',
                                    style: GoogleFonts.outfit(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: const Color(0xFF2A211D),
                                    ),
                                  ),
                                  const Gap(8),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF5F2EB),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: const Color(0xFFE5E2DB)),
                                    ),
                                    child: SelectableText(
                                      _modelUrl ?? '',
                                      maxLines: 2,
                                      style: GoogleFonts.outfit(
                                        fontSize: 11,
                                        color: const Color(0xFF8E847A),
                                        height: 1.45,
                                      ),
                                    ),
                                  ),
                                  const Gap(24),
                                  // 5. 복사 및 웹에서 열기 버튼
                                  Row(
                                    children: [
                                      Expanded(
                                        child: GestureDetector(
                                          onTap: _copy,
                                          child: Container(
                                            height: 50,
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFF5F2EB),
                                              borderRadius: BorderRadius.circular(14),
                                              border: Border.all(color: const Color(0xFFE5E2DB)),
                                            ),
                                            child: Row(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                const Icon(
                                                  Icons.copy_rounded,
                                                  color: Color(0xFF2A211D),
                                                  size: 18,
                                                ),
                                                const Gap(8),
                                                Text(
                                                  '링크 복사',
                                                  style: GoogleFonts.outfit(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w600,
                                                    color: const Color(0xFF2A211D),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      const Gap(12),
                                      Expanded(
                                        child: GestureDetector(
                                          onTap: _openExternal,
                                          child: Container(
                                            height: 50,
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFF5F2EB),
                                              borderRadius: BorderRadius.circular(14),
                                              border: Border.all(color: const Color(0xFFE5E2DB)),
                                            ),
                                            child: Row(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                const Icon(
                                                  Icons.open_in_new_rounded,
                                                  color: Color(0xFF2A211D),
                                                  size: 18,
                                                ),
                                                const Gap(8),
                                                Text(
                                                  '웹에서 열기',
                                                  style: GoogleFonts.outfit(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w600,
                                                    color: const Color(0xFF2A211D),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _buildMetaDetail(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.outfit(
            fontSize: 12,
            color: const Color(0xFF8E847A),
            fontWeight: FontWeight.w400,
          ),
        ),
        const Gap(4),
        Text(
          value,
          style: GoogleFonts.outfit(
            fontSize: 15,
            color: const Color(0xFF2A211D),
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
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
              style: GoogleFonts.outfit(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.7),
                height: 1.45,
              ),
            ),
            const Gap(18),
            TextButton(
              onPressed: onRetry,
              child: Text(
                '다시 시도',
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

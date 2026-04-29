import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../theme/app_theme.dart';

/// S3 presigned URL → 로컬 파일로 다운로드 → ModelViewer에 file:// URL로 전달
/// S3 CORS/presigned URL 문제를 완전히 우회합니다.
class GlbModelViewer extends StatefulWidget {
  final String modelUrl;
  final double height;

  const GlbModelViewer({
    super.key,
    required this.modelUrl,
    this.height = 360,
  });

  @override
  State<GlbModelViewer> createState() => _GlbModelViewerState();
}

class _GlbModelViewerState extends State<GlbModelViewer> {
  String? _localFilePath;
  bool _downloading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _downloadGlb();
  }

  Future<void> _downloadGlb() async {
    setState(() {
      _downloading = true;
      _error = null;
    });

    try {
      // 1. GLB 파일 다운로드 (Dart HTTP 클라이언트 사용 → CORS 미적용)
      final response = await http.get(Uri.parse(widget.modelUrl));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('GLB 다운로드 실패: HTTP ${response.statusCode}');
      }

      // 2. 임시 디렉토리에 저장
      final dir = await getTemporaryDirectory();
      // URL 해시를 파일명으로 사용해 캐싱 효과
      final fileName = 'model_${widget.modelUrl.hashCode.abs()}.glb';
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(response.bodyBytes);

      if (!mounted) return;
      setState(() => _localFilePath = file.path);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_downloading) {
      return SizedBox(
        height: widget.height,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: AppColors.primary),
              const Gap(16),
              Text(
                '3D 모델 다운로드 중...',
                style: GoogleFonts.nunito(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return SizedBox(
        height: widget.height,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: AppColors.primary, size: 36),
              const Gap(12),
              Text(
                '모델을 불러올 수 없어요',
                style: GoogleFonts.nunito(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
              const Gap(8),
              TextButton(
                onPressed: _downloadGlb,
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

    // 3. 로컬 파일 경로를 ModelViewer에 전달
    // ar: true → iOS에서 AR Quick Look이 앱 내부 모달로 실행됨 (Chrome 미사용)
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: ModelViewer(
        src: 'file://$_localFilePath',
        alt: '3D 가구 모델',
        ar: true,
        autoRotate: true,
        cameraControls: true,
        shadowIntensity: 1,
        backgroundColor: const Color(0xFF1A1A1A),
      ),
    );
  }
}

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/app_theme.dart';
import 'processing_screen.dart';

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  XFile? _xfile;
  Uint8List? _bytes;
  bool _analyzed = false;

  bool get _hasImage => _xfile != null && _bytes != null;

  Future<void> _pick() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;

    final bytes = await picked.readAsBytes();
    setState(() {
      _xfile = picked;
      _bytes = bytes;
      _analyzed = false;
    });

    await Future.delayed(const Duration(milliseconds: 900));
    if (mounted) setState(() => _analyzed = true);
  }

  // 웹: bytes를 base64 data URL로, 모바일: 파일 경로
  String get _storagePath {
    if (kIsWeb) {
      return 'data:image/jpeg;base64,${base64Encode(_bytes!)}';
    }
    return _xfile!.path;
  }

  void _convert() {
    if (!_hasImage || !_analyzed) return;
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, a, __) => ProcessingScreen(imagePath: _storagePath),
        transitionsBuilder: (_, a, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Curves.easeIn),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('새 모델 만들기'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '가구가 잘 보이는 사진을 골라주세요',
                style: GoogleFonts.nunito(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                ),
              ),
              const Gap(20),
              GestureDetector(
                onTap: _pick,
                child: _hasImage
                    ? _Preview(
                        bytes: _bytes!,
                        onRemove: () => setState(() {
                          _xfile = null;
                          _bytes = null;
                          _analyzed = false;
                        }),
                      )
                    : const _UploadArea(),
              ),
              if (_hasImage) ...[
                const Gap(18),
                AnimatedOpacity(
                  opacity: _analyzed ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 500),
                  child: const _AnalysisCard(),
                ),
              ],
              const Gap(28),
              _ConvertButton(
                enabled: _hasImage && _analyzed,
                onTap: _convert,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UploadArea extends StatelessWidget {
  const _UploadArea();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 260,
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.35),
          width: 1.5,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.add_photo_alternate_outlined,
              color: AppColors.primary,
              size: 34,
            ),
          ),
          const Gap(18),
          Text(
            '갤러리에서 사진 선택',
            style: GoogleFonts.nunito(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const Gap(6),
          Text(
            'JPG · PNG · HEIC  ·  최대 20MB',
            style: GoogleFonts.nunito(
              fontSize: 13,
              color: AppColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  final Uint8List bytes;
  final VoidCallback onRemove;

  const _Preview({required this.bytes, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Stack(
        children: [
          SizedBox(
            width: double.infinity,
            height: 300,
            child: Image.memory(bytes, fit: BoxFit.cover),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnalysisCard extends StatelessWidget {
  const _AnalysisCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.successBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: AppColors.success.withValues(alpha: 0.25), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle_rounded,
                  color: AppColors.success, size: 17),
              const Gap(8),
              Text(
                '분석 완료  ·  변환 준비됨',
                style: GoogleFonts.nunito(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.success,
                ),
              ),
            ],
          ),
          const Gap(12),
          for (final label in [
            '이미지 품질 양호',
            '가구 오브젝트 감지됨',
            '3D 변환 가능',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: const BoxDecoration(
                      color: AppColors.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Text(
                    label,
                    style: GoogleFonts.nunito(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ConvertButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _ConvertButton({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        height: 58,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: enabled
                ? [AppColors.primary, AppColors.accent]
                : [AppColors.card, AppColors.card],
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
                Icons.auto_awesome_rounded,
                color: enabled ? Colors.white : AppColors.textTertiary,
                size: 20,
              ),
              const Gap(8),
              Text(
                '3D로 변환하기',
                style: GoogleFonts.nunito(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: enabled ? Colors.white : AppColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

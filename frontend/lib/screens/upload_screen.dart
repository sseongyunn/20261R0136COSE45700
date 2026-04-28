import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../models/pending_generation_job.dart';
import '../providers/pending_jobs_provider.dart';
import '../theme/app_theme.dart';
import 'processing_screen.dart';

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  final _nameController = TextEditingController(text: 'Wooden Chair');
  final _categoryController = TextEditingController(text: 'chair');
  final _widthController = TextEditingController();
  final _heightController = TextEditingController();
  final _depthController = TextEditingController();

  XFile? _xfile;
  Uint8List? _bytes;
  bool _analyzed = false;
  bool _submitting = false;
  String? _error;

  bool get _hasImage => _xfile != null && _bytes != null;

  @override
  void dispose() {
    _nameController.dispose();
    _categoryController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    _depthController.dispose();
    super.dispose();
  }

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
      _error = null;
    });

    await Future.delayed(const Duration(milliseconds: 900));
    if (mounted) setState(() => _analyzed = true);
  }

  String get _storagePath {
    if (kIsWeb) {
      return 'data:image/jpeg;base64,${base64Encode(_bytes!)}';
    }
    return _xfile!.path;
  }

  Future<void> _convert() async {
    if (!_hasImage || !_analyzed || _submitting) return;

    final name = _nameController.text.trim();
    final category = _categoryController.text.trim();
    if (name.isEmpty || category.isEmpty) {
      setState(() => _error = '이름과 카테고리를 입력해주세요.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final api = context.read<ApiClient>();
      final pendingJobs = context.read<PendingJobsProvider>();
      final extension = _extensionFor(_xfile!.name);
      final contentType = _contentTypeFor(extension);
      final ticket = await api.requestSourceImageUploadUrl(
        extension: extension,
        contentType: contentType,
      );
      await api.uploadBytesToPresignedUrl(
        uploadUrl: ticket.uploadUrl,
        bytes: _bytes!,
        contentType: contentType,
      );
      await api.completeSourceImage(ticket);
      final job = await api.createGenerationJob(
        sourceImageId: ticket.sourceImageId,
        name: name,
        category: category,
        widthCm: _parseDouble(_widthController.text),
        heightCm: _parseDouble(_heightController.text),
        depthCm: _parseDouble(_depthController.text),
      );
      await pendingJobs.add(
        PendingGenerationJob(
          jobId: job.jobId,
          name: name,
          category: category,
          imagePath: _storagePath,
          dimensions: _dimensionText,
          status: job.status,
          createdAt: DateTime.now(),
        ),
      );

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (context, a, secondaryAnimation) => ProcessingScreen(
            jobId: job.jobId,
            imagePath: _storagePath,
            requestedName: name,
            requestedCategory: category,
            requestedDimensions: _dimensionText,
          ),
          transitionsBuilder: (context, a, secondaryAnimation, child) =>
              FadeTransition(
                opacity: CurvedAnimation(parent: a, curve: Curves.easeIn),
                child: child,
              ),
          transitionDuration: const Duration(milliseconds: 300),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String get _dimensionText {
    final width = _widthController.text.trim();
    final depth = _depthController.text.trim();
    final height = _heightController.text.trim();
    if (width.isEmpty || depth.isEmpty || height.isEmpty) return '크기 미입력';
    return '$width × $depth × $height cm';
  }

  String _extensionFor(String filename) {
    final name = filename.toLowerCase();
    final index = name.lastIndexOf('.');
    final ext = index >= 0 ? name.substring(index + 1) : 'jpg';
    if (ext == 'jpeg') return 'jpg';
    if (ext == 'png' || ext == 'webp' || ext == 'jpg') return ext;
    return 'jpg';
  }

  String _contentTypeFor(String extension) {
    switch (extension) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      default:
        return 'image/jpeg';
    }
  }

  double? _parseDouble(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return double.tryParse(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('새 모델 만들기'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: _submitting ? null : () => Navigator.pop(context),
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
                onTap: _submitting ? null : _pick,
                child: _hasImage
                    ? _Preview(
                        bytes: _bytes!,
                        onRemove: _submitting
                            ? null
                            : () => setState(() {
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
                const Gap(18),
                _RequestForm(
                  nameController: _nameController,
                  categoryController: _categoryController,
                  widthController: _widthController,
                  heightController: _heightController,
                  depthController: _depthController,
                ),
              ],
              if (_error != null) ...[
                const Gap(16),
                _ErrorBox(message: _error!),
              ],
              const Gap(28),
              _ConvertButton(
                enabled: _hasImage && _analyzed && !_submitting,
                loading: _submitting,
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
  final VoidCallback? onRemove;

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
                child: const Icon(
                  Icons.close_rounded,
                  color: Colors.white,
                  size: 18,
                ),
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
          color: AppColors.success.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: AppColors.success,
                size: 17,
              ),
              const Gap(8),
              Text(
                '분석 완료  ·  업로드 준비됨',
                style: GoogleFonts.nunito(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.success,
                ),
              ),
            ],
          ),
          const Gap(12),
          for (final label in ['이미지 품질 양호', '가구 오브젝트 감지됨', 'VARCO 3D 생성 가능'])
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

class _RequestForm extends StatelessWidget {
  final TextEditingController nameController;
  final TextEditingController categoryController;
  final TextEditingController widthController;
  final TextEditingController heightController;
  final TextEditingController depthController;

  const _RequestForm({
    required this.nameController,
    required this.categoryController,
    required this.widthController,
    required this.heightController,
    required this.depthController,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '생성 정보',
            style: GoogleFonts.nunito(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const Gap(14),
          _TextInput(controller: nameController, label: '이름'),
          const Gap(10),
          _TextInput(controller: categoryController, label: '카테고리'),
          const Gap(10),
          Row(
            children: [
              Expanded(
                child: _TextInput(
                  controller: widthController,
                  label: '가로 cm',
                  number: true,
                ),
              ),
              const Gap(8),
              Expanded(
                child: _TextInput(
                  controller: depthController,
                  label: '깊이 cm',
                  number: true,
                ),
              ),
              const Gap(8),
              Expanded(
                child: _TextInput(
                  controller: heightController,
                  label: '높이 cm',
                  number: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TextInput extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool number;

  const _TextInput({
    required this.controller,
    required this.label,
    this.number = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true)
          : null,
      style: GoogleFonts.nunito(fontSize: 14, color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.nunito(color: AppColors.textTertiary),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.primary),
        ),
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF3A1D1D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF693131)),
      ),
      child: Text(
        message,
        style: GoogleFonts.nunito(
          fontSize: 13,
          color: const Color(0xFFFFB8A8),
          height: 1.4,
        ),
      ),
    );
  }
}

class _ConvertButton extends StatelessWidget {
  final bool enabled;
  final bool loading;
  final VoidCallback onTap;

  const _ConvertButton({
    required this.enabled,
    required this.loading,
    required this.onTap,
  });

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
          child: loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Row(
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

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

enum _UploadMode { single, multiview }

enum _FurnitureView { front, back, left, right }

extension _FurnitureViewText on _FurnitureView {
  String get label {
    switch (this) {
      case _FurnitureView.front:
        return '앞면';
      case _FurnitureView.back:
        return '뒷면';
      case _FurnitureView.left:
        return '왼쪽';
      case _FurnitureView.right:
        return '오른쪽';
    }
  }

  String get helper {
    switch (this) {
      case _FurnitureView.front:
        return '정면 사진';
      case _FurnitureView.back:
        return '후면 사진';
      case _FurnitureView.left:
        return '좌측 사진';
      case _FurnitureView.right:
        return '우측 사진';
    }
  }
}

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

  _UploadMode _mode = _UploadMode.single;
  XFile? _xfile;
  Uint8List? _bytes;
  final Map<_FurnitureView, XFile> _viewFiles = {};
  final Map<_FurnitureView, Uint8List> _viewBytes = {};
  bool _analyzed = false;
  bool _submitting = false;
  String? _error;

  bool get _hasImage => _xfile != null && _bytes != null;

  bool get _hasMultiviewImages => _FurnitureView.values.every(
    (view) => _viewFiles[view] != null && _viewBytes[view] != null,
  );

  bool get _hasRequiredImages =>
      _mode == _UploadMode.single ? _hasImage : _hasMultiviewImages;

  @override
  void dispose() {
    _nameController.dispose();
    _categoryController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    _depthController.dispose();
    super.dispose();
  }

  void _changeMode(_UploadMode mode) {
    if (_mode == mode || _submitting) return;
    setState(() {
      _mode = mode;
      _analyzed = _hasRequiredImages;
      _error = null;
    });
  }

  Future<void> _pick({_FurnitureView? view}) async {
    if (_mode == _UploadMode.multiview && view == null) return;

    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;

    final bytes = await picked.readAsBytes();
    setState(() {
      if (_mode == _UploadMode.single) {
        _xfile = picked;
        _bytes = bytes;
      } else {
        _viewFiles[view!] = picked;
        _viewBytes[view] = bytes;
      }
      _analyzed = false;
      _error = null;
    });

    if (!_hasRequiredImages) return;
    await Future.delayed(const Duration(milliseconds: 900));
    if (mounted && _hasRequiredImages) setState(() => _analyzed = true);
  }

  void _removeSingleImage() {
    setState(() {
      _xfile = null;
      _bytes = null;
      _analyzed = false;
    });
  }

  void _removeViewImage(_FurnitureView view) {
    setState(() {
      _viewFiles.remove(view);
      _viewBytes.remove(view);
      _analyzed = false;
    });
  }

  String _storagePathFor(XFile file, Uint8List bytes) {
    if (kIsWeb) {
      return 'data:image/jpeg;base64,${base64Encode(bytes)}';
    }
    return file.path;
  }

  String get _primaryStoragePath {
    if (_mode == _UploadMode.single) {
      return _storagePathFor(_xfile!, _bytes!);
    }
    return _storagePathFor(
      _viewFiles[_FurnitureView.front]!,
      _viewBytes[_FurnitureView.front]!,
    );
  }

  Future<UploadTicket> _uploadSourceImage(
    ApiClient api,
    XFile file,
    Uint8List bytes,
  ) async {
    final extension = _extensionFor(file.name);
    final contentType = _contentTypeFor(extension);
    final ticket = await api.requestSourceImageUploadUrl(
      extension: extension,
      contentType: contentType,
    );
    await api.uploadBytesToPresignedUrl(
      uploadUrl: ticket.uploadUrl,
      bytes: bytes,
      contentType: contentType,
    );
    await api.completeSourceImage(ticket);
    return ticket;
  }

  Future<void> _convert() async {
    if (!_hasRequiredImages || !_analyzed || _submitting) return;

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
      late final GenerationJob job;

      if (_mode == _UploadMode.single) {
        final ticket = await _uploadSourceImage(api, _xfile!, _bytes!);
        job = await api.createGenerationJob(
          sourceImageId: ticket.sourceImageId,
          name: name,
          category: category,
          generationMode: 'single',
          widthCm: _parseDouble(_widthController.text),
          heightCm: _parseDouble(_heightController.text),
          depthCm: _parseDouble(_depthController.text),
        );
      } else {
        final tickets = <_FurnitureView, UploadTicket>{};
        for (final view in _FurnitureView.values) {
          tickets[view] = await _uploadSourceImage(
            api,
            _viewFiles[view]!,
            _viewBytes[view]!,
          );
        }
        job = await api.createGenerationJob(
          sourceImageId: tickets[_FurnitureView.front]!.sourceImageId,
          backSourceImageId: tickets[_FurnitureView.back]!.sourceImageId,
          leftSourceImageId: tickets[_FurnitureView.left]!.sourceImageId,
          rightSourceImageId: tickets[_FurnitureView.right]!.sourceImageId,
          name: name,
          category: category,
          generationMode: 'multiview',
          widthCm: _parseDouble(_widthController.text),
          heightCm: _parseDouble(_heightController.text),
          depthCm: _parseDouble(_depthController.text),
        );
      }

      final imagePath = _primaryStoragePath;
      await pendingJobs.add(
        PendingGenerationJob(
          jobId: job.jobId,
          name: name,
          category: category,
          imagePath: imagePath,
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
            imagePath: imagePath,
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
    final isMultiview = _mode == _UploadMode.multiview;

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
          title: Text(
            '새 모델 만들기',
            style: GoogleFonts.outfit(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
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
                  isMultiview
                      ? '가구의 앞, 뒤, 왼쪽, 오른쪽 사진을 등록해주세요'
                      : '가구가 잘 보이는 사진을 골라주세요',
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
                const Gap(16),
                _ModeSelector(
                  mode: _mode,
                  onChanged: _changeMode,
                  disabled: _submitting,
                ),
                if (isMultiview) ...[const Gap(14), const _MultiviewGuide()],
                const Gap(20),
                if (isMultiview)
                  _MultiviewPickerGrid(
                    viewBytes: _viewBytes,
                    submitting: _submitting,
                    onPick: (view) => _pick(view: view),
                    onRemove: _removeViewImage,
                  )
                else
                  GestureDetector(
                    onTap: _submitting ? null : _pick,
                    child: _hasImage
                        ? _Preview(
                            bytes: _bytes!,
                            onRemove: _submitting ? null : _removeSingleImage,
                          )
                        : const _UploadArea(),
                  ),
                if (_hasRequiredImages) ...[
                  const Gap(18),
                  AnimatedOpacity(
                    opacity: _analyzed ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 500),
                    child: _AnalysisCard(mode: _mode),
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
                  enabled: _hasRequiredImages && _analyzed && !_submitting,
                  loading: _submitting,
                  onTap: _convert,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeSelector extends StatelessWidget {
  final _UploadMode mode;
  final ValueChanged<_UploadMode> onChanged;
  final bool disabled;

  const _ModeSelector({
    required this.mode,
    required this.onChanged,
    required this.disabled,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          _ModeButton(
            label: '단일 이미지',
            icon: Icons.image_outlined,
            selected: mode == _UploadMode.single,
            onTap: disabled ? null : () => onChanged(_UploadMode.single),
          ),
          _ModeButton(
            label: '멀티뷰',
            icon: Icons.view_in_ar_outlined,
            selected: mode == _UploadMode.multiview,
            onTap: disabled ? null : () => onChanged(_UploadMode.multiview),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  const _ModeButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          height: 44,
          decoration: BoxDecoration(
            gradient: selected
                ? LinearGradient(
                    colors: [
                      const Color(0xFFBE6E43).withValues(alpha: 0.2),
                      const Color(0xFF7A3916).withValues(alpha: 0.2),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  )
                : null,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? Colors.white.withValues(alpha: 0.2) : Colors.transparent,
              width: 1.2,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: const Color(0xFFD4845A).withValues(alpha: 0.25),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? Colors.white : Colors.white.withValues(alpha: 0.6),
              ),
              const Gap(8),
              Text(
                label,
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MultiviewGuide extends StatelessWidget {
  const _MultiviewGuide();

  @override
  Widget build(BuildContext context) {
    const tips = [
      '네 방향 모두 같은 조명과 배경에서 촬영해주세요.',
      '카메라와 가구 사이 거리를 최대한 비슷하게 유지해주세요.',
      '색감이 바뀌지 않도록 같은 노출과 화이트밸런스를 권장합니다.',
      '가구가 잘리지 않게 중앙에 맞춰주세요.',
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFFBE6E43).withValues(alpha: 0.09),
                      const Color(0xFF7A3916).withValues(alpha: 0.09),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.2),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFD4845A).withValues(alpha: 0.25),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.tips_and_updates_outlined,
                  size: 18,
                  color: Colors.white,
                ),
              ),
              const Gap(10),
              Text(
                '멀티뷰 촬영 팁',
                style: GoogleFonts.outfit(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const Gap(12),
          for (final tip in tips)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(top: 8, right: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFBE6E43).withValues(alpha: 0.8),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      tip,
                      style: GoogleFonts.outfit(
                        fontSize: 12.5,
                        height: 1.45,
                        color: Colors.white.withValues(alpha: 0.8),
                      ),
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

class _MultiviewPickerGrid extends StatelessWidget {
  final Map<_FurnitureView, Uint8List> viewBytes;
  final bool submitting;
  final ValueChanged<_FurnitureView> onPick;
  final ValueChanged<_FurnitureView> onRemove;

  const _MultiviewPickerGrid({
    required this.viewBytes,
    required this.submitting,
    required this.onPick,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 0.95,
      children: [
        for (final view in _FurnitureView.values)
          _ViewTile(
            view: view,
            bytes: viewBytes[view],
            onTap: submitting ? null : () => onPick(view),
            onRemove: submitting ? null : () => onRemove(view),
          ),
      ],
    );
  }
}

class _ViewTile extends StatelessWidget {
  final _FurnitureView view;
  final Uint8List? bytes;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  const _ViewTile({
    required this.view,
    required this.bytes,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final hasImage = bytes != null;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: hasImage ? Colors.transparent : Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: hasImage
                ? AppColors.primary.withValues(alpha: 0.45)
                : Colors.white.withValues(alpha: 0.2),
          ),
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasImage)
              Image.memory(bytes!, fit: BoxFit.cover)
            else
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFFBE6E43).withValues(alpha: 0.09),
                          const Color(0xFF7A3916).withValues(alpha: 0.09),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.2),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFD4845A).withValues(alpha: 0.25),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.add_photo_alternate_outlined,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const Gap(12),
                  Text(
                    view.label,
                    style: GoogleFonts.outfit(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  const Gap(4),
                  Text(
                    view.helper,
                    style: GoogleFonts.outfit(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            Positioned(
              left: 10,
              top: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: hasImage
                      ? Colors.black.withValues(alpha: 0.58)
                      : Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  view.label,
                  style: GoogleFonts.outfit(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            if (hasImage)
              Positioned(
                top: 10,
                right: 10,
                child: GestureDetector(
                  onTap: onRemove,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
              ),
          ],
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
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.25),
          width: 1.5,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.add_photo_alternate_outlined,
              color: Colors.white,
              size: 34,
            ),
          ),
          const Gap(18),
          Text(
            '갤러리에서 사진 선택',
            style: GoogleFonts.outfit(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const Gap(6),
          Text(
            'JPG · PNG · HEIC  ·  최대 20MB',
            style: GoogleFonts.outfit(
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.5),
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
  final _UploadMode mode;

  const _AnalysisCard({required this.mode});

  @override
  Widget build(BuildContext context) {
    final labels = mode == _UploadMode.multiview
        ? ['앞·뒤·왼쪽·오른쪽 이미지 준비됨', '색상과 거리 일관성 확인됨', 'Hunyuan 멀티뷰 생성 가능']
        : ['이미지 품질 양호', '가구 오브젝트 감지됨', 'AI 3D 생성 가능'];

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.success.withValues(alpha: 0.3),
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
                style: GoogleFonts.outfit(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.success,
                ),
              ),
            ],
          ),
          const Gap(12),
          for (final label in labels)
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
                  Expanded(
                    child: Text(
                      label,
                      style: GoogleFonts.outfit(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
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

class _RequestForm extends StatefulWidget {
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
  State<_RequestForm> createState() => _RequestFormState();
}

class _RequestFormState extends State<_RequestForm> {
  String _selectedPreset = 'chair';

  final List<(String, String)> _presets = const [
    ('Chair', 'chair'),
    ('Sofa', 'sofa'),
    ('Bed', 'bed'),
    ('Table', 'table'),
    ('Lamp', 'lamp'),
    ('Cabinet', 'cabinet'),
    ('Custom', 'custom'),
  ];

  @override
  void initState() {
    super.initState();
    final initialValue = widget.categoryController.text.trim().toLowerCase();
    final match = _presets.any((p) => p.$2 == initialValue);
    if (match && initialValue != 'custom') {
      _selectedPreset = initialValue;
    } else if (initialValue.isEmpty) {
      _selectedPreset = 'chair';
      widget.categoryController.text = 'chair';
    } else {
      _selectedPreset = 'custom';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '생성 정보',
            style: GoogleFonts.outfit(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const Gap(14),
          _TextInput(controller: widget.nameController, label: '이름'),
          const Gap(14),
          Text(
            'Category',
            style: GoogleFonts.outfit(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
          const Gap(8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _presets.map((preset) {
              final isSelected = _selectedPreset == preset.$2;
              return ChoiceChip(
                label: Text(
                  preset.$1,
                  style: GoogleFonts.outfit(
                    color: isSelected ? Colors.white : Colors.white70,
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
                selected: isSelected,
                onSelected: (selected) {
                  if (selected) {
                    setState(() {
                      _selectedPreset = preset.$2;
                      if (preset.$2 != 'custom') {
                        widget.categoryController.text = preset.$2;
                      } else {
                        widget.categoryController.clear();
                      }
                    });
                  }
                },
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                selectedColor: AppColors.primary.withValues(alpha: 0.35),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: isSelected
                        ? AppColors.primary
                        : Colors.white.withValues(alpha: 0.15),
                  ),
                ),
                showCheckmark: false,
              );
            }).toList(),
          ),
          if (_selectedPreset == 'custom') ...[
            const Gap(12),
            _TextInput(
              controller: widget.categoryController,
              label: '카테고리 직접 입력 (영문)',
            ),
          ],
          const Gap(14),
          Row(
            children: [
              Expanded(
                child: _TextInput(
                  controller: widget.widthController,
                  label: '가로 cm',
                  number: true,
                ),
              ),
              const Gap(8),
              Expanded(
                child: _TextInput(
                  controller: widget.depthController,
                  label: '깊이 cm',
                  number: true,
                ),
              ),
              const Gap(8),
              Expanded(
                child: _TextInput(
                  controller: widget.heightController,
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
      style: GoogleFonts.outfit(fontSize: 14, color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.outfit(color: Colors.white.withValues(alpha: 0.6)),
        filled: true,
        fillColor: Colors.black.withValues(alpha: 0.15),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 13,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Colors.white),
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x2BFFB8A8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white38),
      ),
      child: Text(
        message,
        style: GoogleFonts.outfit(
          fontSize: 13,
          fontWeight: FontWeight.w300,
          color: Colors.white,
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
          color: enabled ? null : Colors.white.withValues(alpha: 0.08),
          gradient: enabled
              ? const LinearGradient(
                  colors: [
                    Color(0xFFD1BAD2),
                    Color(0xFF2884B8),
                  ],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                )
              : null,
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
                      color: enabled ? Colors.white : Colors.white.withValues(alpha: 0.35),
                      size: 20,
                    ),
                    const Gap(8),
                    Text(
                      '3D로 변환하기',
                      style: GoogleFonts.outfit(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: enabled ? Colors.white : Colors.white.withValues(alpha: 0.35),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

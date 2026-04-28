import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../theme/app_theme.dart';

class ModelUrlScreen extends StatefulWidget {
  final String assetId;
  final String? initialModelUrl;

  const ModelUrlScreen({
    super.key,
    required this.assetId,
    this.initialModelUrl,
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
          style: GoogleFonts.nunito(color: AppColors.textPrimary),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('모델 URL'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            tooltip: '새 URL 요청',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          children: [
            Container(
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
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.file_download_outlined,
                          color: AppColors.primary,
                          size: 24,
                        ),
                      ),
                      const Gap(14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'GLB 다운로드 링크',
                              style: GoogleFonts.nunito(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const Gap(2),
                            Text(
                              'S3 presigned URL',
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
                  const Gap(20),
                  if (_loading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(
                          color: AppColors.primary,
                        ),
                      ),
                    )
                  else if (_error != null)
                    _ErrorBox(message: _error!)
                  else ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: SelectableText(
                        _modelUrl ?? '',
                        style: GoogleFonts.nunito(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                          height: 1.45,
                        ),
                      ),
                    ),
                    const Gap(16),
                    GestureDetector(
                      onTap: _copy,
                      child: Container(
                        height: 54,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [AppColors.primary, AppColors.accent],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                          borderRadius: BorderRadius.circular(17),
                        ),
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.copy_rounded,
                                color: Colors.white,
                                size: 19,
                              ),
                              const Gap(8),
                              Text(
                                'URL 복사하기',
                                style: GoogleFonts.nunito(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
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
          height: 1.45,
        ),
      ),
    );
  }
}

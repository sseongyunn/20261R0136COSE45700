import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Image.file는 Web에서 동작하지 않음.
/// imagePath가 'data:' 로 시작하면 base64로 처리, 아니면 파일 경로로 처리.
class FurniImage extends StatelessWidget {
  final String imagePath;
  final BoxFit fit;

  const FurniImage({super.key, required this.imagePath, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    if (imagePath.startsWith('data:')) {
      final bytes = base64Decode(imagePath.split(',').last);
      return Image.memory(bytes, fit: fit, errorBuilder: _error);
    }
    if (kIsWeb) {
      return _placeholder();
    }
    return Image.file(File(imagePath), fit: fit, errorBuilder: _error);
  }

  Widget _error(BuildContext ctx, Object e, StackTrace? s) => _placeholder();

  Widget _placeholder() => Container(
        color: AppColors.surface,
        child: const Center(
          child: Icon(Icons.image_not_supported_outlined,
              color: AppColors.textTertiary),
        ),
      );
}

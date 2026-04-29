import 'dart:io';

import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

import '../theme/app_theme.dart';

/// 앱 내부 풀스크린 AR 화면
/// - ARKit으로 카메라를 통해 실제 환경을 보여주고
/// - 평면(바닥/테이블) 감지 후 탭한 위치에 GLB 3D 모델을 배치합니다.
class ArViewScreen extends StatefulWidget {
  /// S3 presigned URL 또는 이미 다운로드된 로컬 file:// 경로
  final String modelUrl;

  /// 가구 이름 (상단 표시용)
  final String modelName;

  const ArViewScreen({
    super.key,
    required this.modelUrl,
    required this.modelName,
  });

  @override
  State<ArViewScreen> createState() => _ArViewScreenState();
}

class _ArViewScreenState extends State<ArViewScreen> {
  ARKitController? _arkitController;

  // 감지된 평면 목록
  final Map<String, ARKitPlane> _planes = {};

  // 현재 배치된 모델 노드 이름
  String? _placedNodeName;

  // GLB 로컬 파일 경로 (다운로드 완료 후 세팅)
  String? _localGlbPath;
  bool _downloading = false;
  String? _downloadError;

  // 평면 감지 여부
  bool get _planeDetected => _planes.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _downloadModel();
  }

  @override
  void dispose() {
    _arkitController?.dispose();
    super.dispose();
  }

  // ────────────────────────────────────────────────
  //  GLB 다운로드 (기존 GlbModelViewer 로직과 동일)
  // ────────────────────────────────────────────────
  Future<void> _downloadModel() async {
    setState(() {
      _downloading = true;
      _downloadError = null;
    });

    try {
      final url = widget.modelUrl;

      // 이미 로컬 파일 경로인 경우 다운로드 생략
      if (url.startsWith('file://') || url.startsWith('/')) {
        final path = url.startsWith('file://') ? url.substring(7) : url;
        if (await File(path).exists()) {
          setState(() => _localGlbPath = path);
          return;
        }
      }

      // HTTP 다운로드
      final response = await http.get(Uri.parse(url));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('GLB 다운로드 실패: HTTP ${response.statusCode}');
      }

      final dir = await getApplicationDocumentsDirectory();
      final fileName = 'ar_model_${url.hashCode.abs()}.glb';
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(response.bodyBytes);

      if (!mounted) return;
      // arkit_plugin의 AssetType.documents는 Documents 폴더 기준 상대 경로를 기대하므로 파일명만 저장
      setState(() => _localGlbPath = fileName);
    } catch (e) {
      if (mounted) setState(() => _downloadError = e.toString());
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  // ────────────────────────────────────────────────
  //  ARKit 콜백
  // ────────────────────────────────────────────────
  void _onARKitViewCreated(ARKitController controller) {
    _arkitController = controller;

    // 평면 감지 추가/업데이트
    controller.onAddNodeForAnchor = _onAnchorAdded;
    controller.onUpdateNodeForAnchor = _onAnchorUpdated;
  }

  void _onAnchorAdded(ARKitAnchor anchor) {
    if (anchor is ARKitPlaneAnchor) {
      _addPlaneNode(anchor);
    }
  }

  void _onAnchorUpdated(ARKitAnchor anchor) {
    if (anchor is ARKitPlaneAnchor) {
      _updatePlaneNode(anchor);
    }
  }

  void _addPlaneNode(ARKitPlaneAnchor anchor) {
    final plane = ARKitPlane(
      width: anchor.extent.x,
      height: anchor.extent.z,
      materials: [
        ARKitMaterial(
          diffuse: ARKitMaterialProperty.color(
            AppColors.primary.withValues(alpha: 0.25),
          ),
        ),
      ],
    );

    final node = ARKitNode(
      name: anchor.identifier,
      geometry: plane,
      position: vector.Vector3(
        anchor.center.x,
        0,
        anchor.center.z,
      ),
      eulerAngles: vector.Vector3(-1.5708, 0, 0), // -90° → 수평으로 눕힘
    );

    _arkitController?.add(node, parentNodeName: anchor.nodeName);
    _planes[anchor.identifier] = plane;

    if (mounted) setState(() {});
  }

  void _updatePlaneNode(ARKitPlaneAnchor anchor) {
    // 평면 업데이트 시 단순히 기존 평면의 크기를 조정하는 대신, 
    // 여기서는 복잡도를 줄이기 위해 업데이트 로직을 생략하거나 
    // 노드 자체를 찾아 업데이트해야 합니다. 
    // arkit_plugin 1.3.0에서는 updateFaceGeometry가 평면에는 적합하지 않습니다.
  }

  // ────────────────────────────────────────────────
  //  탭 → 모델 배치
  // ────────────────────────────────────────────────
  Future<void> _onScreenTap(Offset tapPosition) async {
    if (_localGlbPath == null || _arkitController == null) return;

    // 기존에 배치된 모델 제거
    if (_placedNodeName != null) {
      _arkitController!.remove(_placedNodeName!);
      _placedNodeName = null;
    }

    // Hit test — 감지된 평면 위의 실세계 좌표 계산
    final hitResults = await _arkitController!.performHitTest(
      x: tapPosition.dx,
      y: tapPosition.dy,
    );

    if (hitResults == null || hitResults.isEmpty) return;

    final hit = hitResults.first;
    final nodeName = 'furniture_${DateTime.now().millisecondsSinceEpoch}';

    final node = ARKitNode(
      name: nodeName,
      // GLB 모델 로드 (로컬 파일)
      geometry: ARKitBox(
        width: 0.0001,
        height: 0.0001,
        length: 0.0001,
        materials: [],
      ),
      position: vector.Vector3(
        hit.worldTransform.getColumn(3).x,
        hit.worldTransform.getColumn(3).y,
        hit.worldTransform.getColumn(3).z,
      ),
    );

    // ARKitNode는 직접 GLTF/GLB 파일 참조를 지원합니다
    final gltfNode = ARKitNode(
      name: nodeName,
      geometry: null,
      position: vector.Vector3(
        hit.worldTransform.getColumn(3).x,
        hit.worldTransform.getColumn(3).y,
        hit.worldTransform.getColumn(3).z,
      ),
    );

    try {
      // ARKitGltfNode 사용 — 로컬 파일 경로 전달 (AssetType.documents 사용)
      final gltfModel = ARKitGltfNode(
        assetType: AssetType.documents,
        url: _localGlbPath!,
        scale: vector.Vector3.all(0.3),
        position: vector.Vector3(
          hit.worldTransform.getColumn(3).x,
          hit.worldTransform.getColumn(3).y,
          hit.worldTransform.getColumn(3).z,
        ),
        name: nodeName,
      );

      _arkitController!.add(gltfModel);
      setState(() => _placedNodeName = nodeName);
    } catch (_) {
      // ARKitGltfNode 실패 시 박스로 대체 (디버그용)
      _arkitController!.add(node);
      setState(() => _placedNodeName = nodeName);
    }
  }

  // ────────────────────────────────────────────────
  //  UI
  // ────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── ARKit 카메라 뷰 ──
          GestureDetector(
            onTapUp: (details) {
              final size = MediaQuery.of(context).size;
              final pos = details.localPosition;
              // ARKit hit-test는 0~1 정규화 좌표를 사용
              _onScreenTap(
                Offset(pos.dx / size.width, pos.dy / size.height),
              );
            },
            child: ARKitSceneView(
              configuration: ARKitConfiguration.worldTracking,
              planeDetection: ARPlaneDetection.horizontal,
              onARKitViewCreated: _onARKitViewCreated,
            ),
          ),

          // ── 상단 헤더 ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopBar(
              modelName: widget.modelName,
              onClose: () => Navigator.pop(context),
            ),
          ),

          // ── 상태 오버레이 (로딩 / 에러 / 안내) ──
          if (_downloading)
            const _DownloadingOverlay()
          else if (_downloadError != null)
            _ErrorOverlay(
              message: _downloadError!,
              onRetry: _downloadModel,
            )
          else ...[
            // 평면 미감지 안내
            if (!_planeDetected)
              const _HintBadge(
                icon: Icons.screen_rotation_rounded,
                text: '카메라를 바닥이나 테이블에 향해주세요',
              ),

            // 평면 감지 후 탭 안내
            if (_planeDetected && _placedNodeName == null)
              const _HintBadge(
                icon: Icons.touch_app_rounded,
                text: '감지된 평면을 탭해서 가구를 배치하세요',
                isReady: true,
              ),

            // 배치 완료 안내
            if (_placedNodeName != null)
              const _HintBadge(
                icon: Icons.check_circle_outline_rounded,
                text: '다른 곳을 탭하면 위치를 바꿀 수 있어요',
                isSuccess: true,
              ),
          ],

          // ── 하단 컨트롤 ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _BottomBar(
              hasModel: _placedNodeName != null,
              onRemove: () {
                if (_placedNodeName != null) {
                  _arkitController?.remove(_placedNodeName!);
                  setState(() => _placedNodeName = null);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════
//  하위 위젯들
// ═══════════════════════════════════════════════

class _TopBar extends StatelessWidget {
  final String modelName;
  final VoidCallback onClose;

  const _TopBar({required this.modelName, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        bottom: 16,
        left: 16,
        right: 16,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.7),
            Colors.transparent,
          ],
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: onClose,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.close_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AR 뷰',
                  style: GoogleFonts.nunito(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.7),
                    letterSpacing: 0.5,
                  ),
                ),
                Text(
                  modelName,
                  style: GoogleFonts.nunito(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // AR 배지
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.view_in_ar_rounded,
                    color: Colors.white, size: 14),
                const SizedBox(width: 4),
                Text(
                  'ARKit',
                  style: GoogleFonts.nunito(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
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

class _BottomBar extends StatelessWidget {
  final bool hasModel;
  final VoidCallback onRemove;

  const _BottomBar({required this.hasModel, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 20,
        top: 20,
        left: 24,
        right: 24,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.65),
            Colors.transparent,
          ],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (hasModel) ...[
            _ControlBtn(
              icon: Icons.delete_outline_rounded,
              label: '제거',
              onTap: onRemove,
            ),
            const SizedBox(width: 16),
          ],
          _ControlBtn(
            icon: Icons.info_outline_rounded,
            label: '바닥/테이블을 탭해 배치',
            isWide: true,
            subtle: true,
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

class _ControlBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isWide;
  final bool subtle;

  const _ControlBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isWide = false,
    this.subtle = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isWide ? 20 : 16,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: subtle
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(40),
          border: Border.all(
            color: Colors.white.withValues(alpha: subtle ? 0.15 : 0.3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.nunito(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HintBadge extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool isReady;
  final bool isSuccess;

  const _HintBadge({
    required this.icon,
    required this.text,
    this.isReady = false,
    this.isSuccess = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSuccess
        ? Colors.greenAccent
        : isReady
            ? AppColors.primary
            : Colors.white;

    return Positioned(
      top: MediaQuery.of(context).padding.top + 80,
      left: 24,
      right: 24,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  style: GoogleFonts.nunito(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadingOverlay extends StatelessWidget {
  const _DownloadingOverlay();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.primary),
            const SizedBox(height: 16),
            Text(
              '3D 모델 준비 중...',
              style: GoogleFonts.nunito(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorOverlay extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorOverlay({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.7),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: AppColors.primary, size: 48),
              const SizedBox(height: 16),
              Text(
                '모델을 불러올 수 없어요',
                style: GoogleFonts.nunito(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: GoogleFonts.nunito(
                  color: Colors.white60,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 20),
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
      ),
    );
  }
}

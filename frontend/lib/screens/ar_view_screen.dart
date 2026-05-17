import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:collection/collection.dart';
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

  /// 가구 실제 크기 (예: "120 × 60 × 75 cm")
  final String? dimensions;

  const ArViewScreen({
    super.key,
    required this.modelUrl,
    required this.modelName,
    this.dimensions,
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

  // 중앙 Raycast 타이머
  Timer? _raycastTimer;
  // 타겟 위치 (Raycast 성공 시)
  vector.Vector3? _reticlePosition;

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
    _raycastTimer?.cancel();
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
      final dir = await getApplicationDocumentsDirectory();
      final fileName = 'ar_model_${url.hashCode.abs()}.glb';
      final file = File('${dir.path}/$fileName');

      if (url.startsWith('file://') || url.startsWith('/')) {
        final path = url.startsWith('file://') ? url.substring(7) : url;
        if (await File(path).exists()) {
          if (path != file.path) {
            await File(path).copy(file.path);
          }
          if (!mounted) return;
          setState(() {
            _localGlbPath = fileName;
          });
          return;
        } else {
          throw Exception('로컬 모델 파일을 찾을 수 없습니다.');
        }
      }

      // HTTP 다운로드
      final response = await http.get(Uri.parse(url));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('GLB 다운로드 실패: HTTP ${response.statusCode}');
      }

      await file.writeAsBytes(response.bodyBytes);

      if (!mounted) return;
      // arkit_plugin의 AssetType.documents는 Documents 폴더 기준 상대 경로를 기대하므로 파일명만 저장
      setState(() {
        _localGlbPath = fileName;
      });
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
    
    // 100ms마다 화면 중앙 Raycast
    _raycastTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _performRaycast());
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
          transparency: 0.5,
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
      rotation: vector.Vector4(1, 0, 0, -math.pi / 2),
    );

    _arkitController?.add(node, parentNodeName: anchor.nodeName);
    _planes[anchor.identifier] = plane;

    if (mounted) setState(() {});
  }

  void _updatePlaneNode(ARKitPlaneAnchor anchor) {
    final plane = _planes[anchor.identifier];
    if (plane != null) {
      plane.width.value = anchor.extent.x;
      plane.height.value = anchor.extent.z;
    }
  }

  // ────────────────────────────────────────────────
  //  탭 → 모델 배치
  // ────────────────────────────────────────────────
  void _performRaycast() async {
    if (_arkitController == null || _placedNodeName != null) return;
    
    // 화면 크기를 가져올 수 없는 초기 상태 방어
    if (!mounted) return;
    final size = MediaQuery.of(context).size;
    final hits = await _arkitController!.performHitTest(
      x: 0.5,
      y: 0.5,
    );

    final planeHit = hits.firstWhereOrNull(
      (hit) => hit.type == ARKitHitTestResultType.existingPlaneUsingExtent,
    );

    if (planeHit != null) {
      final newPos = vector.Vector3(
        planeHit.worldTransform.getColumn(3).x,
        planeHit.worldTransform.getColumn(3).y,
        planeHit.worldTransform.getColumn(3).z,
      );
      if (_reticlePosition != newPos && mounted) {
        setState(() => _reticlePosition = newPos);
      }
    } else {
      if (_reticlePosition != null && mounted) {
        setState(() => _reticlePosition = null);
      }
    }
  }

  Future<void> _placeModel() async {
    if (_reticlePosition == null || _localGlbPath == null || _arkitController == null) return;

    // 기존에 배치된 모델 제거
    if (_placedNodeName != null) {
      _arkitController!.remove(_placedNodeName!);
      _placedNodeName = null;
    }

    final nodeName = 'furniture_${DateTime.now().millisecondsSinceEpoch}';

    final position = _reticlePosition!;

    debugPrint('Hit position: $position');

    try {
      // ARKitGltfNode 사용 — 로컬 파일 경로 전달 (AssetType.documents 사용)
      final gltfModel = ARKitGltfNode(
        assetType: AssetType.documents,
        url: _localGlbPath!,
        scale: vector.Vector3.all(0.3), // 0.3배 하드코딩으로 복구
        position: position,
        name: nodeName,
      );

      _arkitController!.add(gltfModel);

      setState(() => _placedNodeName = nodeName);
    } catch (_) {
      // 실패할 경우 디버그용 빨간 상자로 대체
      final node = ARKitNode(
        name: nodeName,
        geometry: ARKitBox(
          width: 0.1,
          height: 0.1,
          length: 0.1,
          materials: [
            ARKitMaterial(
              diffuse: ARKitMaterialProperty.color(Colors.red),
            ),
          ],
        ),
        position: position,
      );
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
          ARKitSceneView(
            configuration: ARKitConfiguration.worldTracking,
            planeDetection: ARPlaneDetection.horizontal,
            enableTapRecognizer: false,
            onARKitViewCreated: _onARKitViewCreated,
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
            // 평면 미감지 (스캔 강제)
            if (!_planeDetected)
              Container(
                color: Colors.black.withValues(alpha: 0.3),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.screen_search_desktop_rounded, color: Colors.white, size: 60),
                      const SizedBox(height: 20),
                      Text(
                        '카메라를 좌우로 천천히 움직여\n바닥을 스캔해주세요',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.nunito(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // 평면 감지 후 가이드 안내
            if (_planeDetected && _placedNodeName == null)
              const _HintBadge(
                icon: Icons.center_focus_strong_rounded,
                text: '화면 중앙 과녁을 바닥에 맞추세요',
                isReady: true,
              ),

            // 배치 완료 안내
            if (_placedNodeName != null)
              const _HintBadge(
                icon: Icons.check_circle_outline_rounded,
                text: '하단의 제거 버튼을 눌러 다시 배치할 수 있어요',
                isSuccess: true,
              ),

            // 조준점 (Reticle) 오버레이 위젯
            if (_planeDetected && _placedNodeName == null)
              Center(
                child: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _reticlePosition != null
                          ? AppColors.primary
                          : Colors.white.withValues(alpha: 0.5),
                      width: 2,
                    ),
                    color: _reticlePosition != null
                        ? AppColors.primary.withValues(alpha: 0.2)
                        : Colors.transparent,
                  ),
                  child: Icon(
                    Icons.add_rounded,
                    color: _reticlePosition != null
                        ? AppColors.primary
                        : Colors.white.withValues(alpha: 0.5),
                  ),
                ),
              ),
          ],

          // ── 하단 컨트롤 ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _BottomBar(
              hasModel: _placedNodeName != null,
              canPlace: _reticlePosition != null,
              onPlace: _placeModel,
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
  final bool canPlace;
  final VoidCallback onPlace;
  final VoidCallback onRemove;

  const _BottomBar({
    required this.hasModel,
    required this.canPlace,
    required this.onPlace,
    required this.onRemove,
  });

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
          ] else ...[
            _ControlBtn(
              icon: Icons.add_box_rounded,
              label: '이 위치에 배치하기',
              isWide: true,
              subtle: !canPlace,
              onTap: canPlace ? onPlace : () {},
            ),
          ],
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

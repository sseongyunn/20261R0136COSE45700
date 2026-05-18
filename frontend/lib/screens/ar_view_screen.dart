import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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

  // 배치된 가구의 현재 Y축 회전 각도 (라디안)
  double _modelYRotation = 0.0;

  // GLB 좌표계 보정 값 (다운로드 후 진단 결과로 채움)
  vector.Vector3 _modelBaseRotation = vector.Vector3.zero();

  // ────────────────────────────────────────────────
  // 스케일 보정 관련
  // ────────────────────────────────────────────────
  double _calculatedScale = 0.3; // 기본값
  double? _physicalMaxDim; // 파싱된 목표 최대 길이 (m)

  // 드래그 힌트 표시 여부 (첫 배치 시 1회만)
  bool _showDragHint = false;

  void _parsePhysicalDimensions() {
    final dim = widget.dimensions;
    if (dim == null || dim.contains('미입력')) return;
    
    // 예: "120 × 60 × 75 cm"
    final regex = RegExp(r'([\d.]+)\s*×\s*([\d.]+)\s*×\s*([\d.]+)\s*cm');
    final match = regex.firstMatch(dim);
    if (match != null) {
      final w = double.tryParse(match.group(1)!) ?? 0;
      final d = double.tryParse(match.group(2)!) ?? 0;
      final h = double.tryParse(match.group(3)!) ?? 0;
      
      // cm -> m 변환
      final maxDim = [w, d, h].reduce(math.max) / 100.0;
      if (maxDim > 0) {
        _physicalMaxDim = maxDim;
        debugPrint('[스케일 보정] 파싱된 물리적 최대 길이: $maxDim m');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _parsePhysicalDimensions();
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
          await _diagnoseGlbCoordinateSystem(file);
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
      await _diagnoseGlbCoordinateSystem(file);
    } catch (e) {
      if (mounted) setState(() => _downloadError = e.toString());
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  // ────────────────────────────────────────────────
  //  GLB 좌표계 진단
  // ────────────────────────────────────────────────
  Future<void> _diagnoseGlbCoordinateSystem(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final data = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);

      // GLB 헤더 확인
      if (data.lengthInBytes < 20) return;
      final magic = data.getUint32(0, Endian.little);
      if (magic != 0x46546C67) {
        debugPrint('[GLB진단] 올바른 GLB 파일이 아닙니다.');
        return;
      }

      // JSON 청크 파싱
      final chunk0Length = data.getUint32(12, Endian.little);
      final chunk0Type  = data.getUint32(16, Endian.little);
      if (chunk0Type != 0x4E4F534A) {
        debugPrint('[GLB진단] JSON 청크를 찾지 못했습니다.');
        return;
      }

      final jsonBytes  = bytes.sublist(20, 20 + chunk0Length);
      final gltf = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;

      // 에셋 정보
      final asset = gltf['asset'] as Map<String, dynamic>?;
      debugPrint('[GLB진단] generator : ${asset?['generator']}');
      debugPrint('[GLB진단] version   : ${asset?['version']}');

      // 바운딩 박스(Bounding Box) 스케일 계산
      final accessors = gltf['accessors'] as List<dynamic>?;
      final meshes = gltf['meshes'] as List<dynamic>?;
      double maxModelLength = 0.0;

      if (accessors != null && meshes != null) {
        for (final mesh in meshes) {
          final primitives = mesh['primitives'] as List<dynamic>?;
          if (primitives != null) {
            for (final prim in primitives) {
              final attributes = prim['attributes'] as Map<String, dynamic>?;
              if (attributes != null && attributes.containsKey('POSITION')) {
                final accIdx = attributes['POSITION'] as int;
                final accessor = accessors[accIdx] as Map<String, dynamic>;
                final minArr = accessor['min'] as List<dynamic>?;
                final maxArr = accessor['max'] as List<dynamic>?;
                
                if (minArr != null && maxArr != null && minArr.length >= 3 && maxArr.length >= 3) {
                  final dx = ((maxArr[0] as num) - (minArr[0] as num)).abs().toDouble();
                  final dy = ((maxArr[1] as num) - (minArr[1] as num)).abs().toDouble();
                  final dz = ((maxArr[2] as num) - (minArr[2] as num)).abs().toDouble();
                  final localMax = [dx, dy, dz].reduce(math.max);
                  if (localMax > maxModelLength) maxModelLength = localMax;
                }
              }
            }
          }
        }
      }

      if (maxModelLength > 0) {
        debugPrint('[GLB진단] 3D 모델 원본 최대 길이(Max Dimension): $maxModelLength m');
        if (_physicalMaxDim != null) {
          final scale = _physicalMaxDim! / maxModelLength;
          debugPrint('[GLB진단] 스케일 배율 계산: $_physicalMaxDim / $maxModelLength = $scale');
          if (mounted) {
            setState(() => _calculatedScale = scale);
          }
        } else {
          debugPrint('[GLB진단] 실제 치수 정보가 없어 기본 스케일 유지');
        }
      }

      // 루트 노드 변환 확인
      final scenes = gltf['scenes'] as List<dynamic>?;
      final nodes  = gltf['nodes']  as List<dynamic>?;
      final defaultScene = gltf['scene'] as int? ?? 0;

      if (scenes != null && nodes != null && scenes.isNotEmpty) {
        final rootNodeIndices =
            (scenes[defaultScene]['nodes'] as List<dynamic>? ?? []).cast<int>();

        for (final idx in rootNodeIndices) {
          final node = nodes[idx] as Map<String, dynamic>;
          final name     = node['name'] ?? 'unnamed';
          final rotation = node['rotation'] as List<dynamic>?;
          final scale    = node['scale']    as List<dynamic>?;
          final matrix   = node['matrix']   as List<dynamic>?;

          debugPrint('[GLB진단] 루트노드 "$name"');
          debugPrint('  rotation : $rotation');
          debugPrint('  scale    : $scale');
          debugPrint('  matrix   : $matrix');

          // 탐지: Blender Z-up 보정 진단
          // quaternion [-0.707, 0, 0, 0.707] ≈ X축 -90° 회전 = Z-up 보정
          if (rotation != null && rotation.length == 4) {
            final rx = (rotation[0] as num).toDouble();
            final ry = (rotation[1] as num).toDouble();
            final rz = (rotation[2] as num).toDouble();
            final rw = (rotation[3] as num).toDouble();
            // X축 회전이면 ry≈0, rz≈0
            if (ry.abs() < 0.01 && rz.abs() < 0.01) {
              // X축 회전 각도 계산 (rad)
              final angle = 2 * math.asin(rx.clamp(-1.0, 1.0)) * (rw < 0 ? -1.0 : 1.0);
              debugPrint('  ↳ X축 회전 감지: ${(angle * 180 / math.pi).toStringAsFixed(1)}°');
              if ((angle + math.pi / 2).abs() < 0.1) {
                debugPrint('  ↳ ⚠️ Blender Z-up 보정(X -90°) 감지 → ARKit에서 eulerAngles.x += pi/2 필요');
                if (mounted) {
                  setState(() => _modelBaseRotation = vector.Vector3(math.pi / 2, 0, 0));
                }
              } else {
                debugPrint('  ↳ 기타 X축 회전 감지: ${(angle * 180 / math.pi).toStringAsFixed(1)}°');
              }
            } else {
              debugPrint('  ↳ 비-X축 회전 감지 (Y성분=$ry, Z성분=$rz)');
            }
          } else if (rotation == null) {
            debugPrint('  ↳ ✅ 루트노드 rotation 없음 → Y-up 정상 좌표계');
          }
        }
      }
    } catch (e) {
      debugPrint('[GLB진단] 오류: $e');
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
        scale: vector.Vector3.all(_calculatedScale), // 계산된 동적 스케일 적용
        position: position,
        eulerAngles: _modelBaseRotation, // 좌표계 보정 적용
        name: nodeName,
      );

      _arkitController!.add(gltfModel);

      setState(() {
        _placedNodeName = nodeName;
        _modelYRotation = 0.0; // 배치 시 회전 초기화
        _showDragHint = true;  // 힌트 표시
      });
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
  //  회전
  // ────────────────────────────────────────────────
  void _rotateModel(double angleDelta) {
    if (_placedNodeName == null || _arkitController == null) return;
    _modelYRotation += angleDelta;
    // SceneKit에서 eulerAngles는 직접 업데이트가 안 되므로
    // 노드를 제거하고 새 회전 각도로 다시 추가합니다.
    final position = _reticlePosition!;
    _arkitController!.remove(_placedNodeName!);
    final nodeName = _placedNodeName!;
    try {
      final gltfModel = ARKitGltfNode(
        assetType: AssetType.documents,
        url: _localGlbPath!,
        scale: vector.Vector3.all(_calculatedScale), // 계산된 스케일 유지
        position: position,
        eulerAngles: _modelBaseRotation + vector.Vector3(_modelYRotation, 0, 0),
        name: nodeName,
      );
      _arkitController!.add(gltfModel);
    } catch (_) {}
    setState(() {});
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

            // (hint badge 제거 - _DragHintOverlay가 대신 안내함)
            // 선택 링 오버레이 (배치 후)
            if (_placedNodeName != null)
              const _SelectionRing(),

            if (_showDragHint)
              Positioned(
                bottom: MediaQuery.of(context).size.width / 2 + 12,
                left: 0,
                right: 0,
                child: _DragHintOverlay(
                  onDismiss: () => setState(() => _showDragHint = false),
                ),
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
              modelRotationDeg: ((_modelYRotation * 180 / math.pi) % 360 + 360) % 360,
              onPlace: _placeModel,
              onRotateDrag: (dx) => _rotateModel(-dx * 0.013),
              onRemove: () {
                if (_placedNodeName != null) {
                  _arkitController?.remove(_placedNodeName!);
                  setState(() {
                    _placedNodeName = null;
                    _modelYRotation = 0.0;
                  });
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
  final double modelRotationDeg;
  final VoidCallback onPlace;
  final ValueChanged<double> onRotateDrag;
  final VoidCallback onRemove;

  const _BottomBar({
    required this.hasModel,
    required this.canPlace,
    required this.modelRotationDeg,
    required this.onPlace,
    required this.onRotateDrag,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    if (hasModel) {
      // 반원 핸들 + 제거 버튼 (full-width, 패딩 없음)
      return Stack(
        alignment: Alignment.bottomCenter,
        children: [
          _RotationHandle(rotationDeg: modelRotationDeg, onDragDx: onRotateDrag),
          Positioned(
            bottom: bottomPad + 12,
            child: _ControlBtn(
              icon: Icons.delete_outline_rounded,
              label: '제거',
              onTap: onRemove,
            ),
          ),
        ],
      );
    }
    // 배치 전 버튼
    return Container(
      padding: EdgeInsets.only(
        bottom: bottomPad + 20,
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
      child: Center(child: _ControlBtn(
        icon: Icons.add_box_rounded,
        label: '이 위치에 배치하기',
        isWide: true,
        subtle: !canPlace,
        onTap: canPlace ? onPlace : () {},
      )),
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

/// 반원형 회전 핸들 (화면 전체 폭)
class _RotationHandle extends StatelessWidget {
  final double rotationDeg;
  final ValueChanged<double> onDragDx;
  const _RotationHandle({required this.rotationDeg, required this.onDragDx});

  @override
  Widget build(BuildContext context) {
    final sw = MediaQuery.of(context).size.width;
    final h = sw / 2;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => onDragDx(d.delta.dx),
      child: Container(
        width: double.infinity,
        height: h,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(sw / 2),
            topRight: Radius.circular(sw / 2),
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.18),
            width: 1.5,
          ),
        ),
        child: Stack(
          children: [
            // 눈금 CustomPainter
            Positioned.fill(
              child: CustomPaint(
                painter: _SemiCircleRulerPainter(rotationDeg: rotationDeg),
              ),
            ),
            // 현재 각도 표시 (semicircle apex 근처)
            Positioned(
              top: h * 0.16,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  '${(rotationDeg > 180 ? rotationDeg - 360 : rotationDeg).round()}°',
                  style: GoogleFonts.nunito(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.92),
                    letterSpacing: 0.5,
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

/// 반원 눈금자 Painter
class _SemiCircleRulerPainter extends CustomPainter {
  final double rotationDeg;
  _SemiCircleRulerPainter({required this.rotationDeg});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height; // 원의 중심은 컨테이너 하단 가운데
    final r = size.width / 2;

    // 눈금 그리기 (알파범위 0° ← 180° 좌→우)
    for (int deg = 0; deg <= 180; deg += 5) {
      final alpha = deg * math.pi / 180;
      // 상단 반원 위 좌표
      final px = cx - r * math.cos(alpha);
      final py = cy - r * math.sin(alpha);
      // 안쪽 방향 (= 중심 방향)
      final nx = (cx - px) / r;
      final ny = (cy - py) / r;

      final isMajor = deg % 30 == 0;
      final isMid   = deg % 10 == 0;
      final tickLen = isMajor ? 20.0 : isMid ? 12.0 : 6.0;
      final alpha2  = isMajor ? 0.65  : isMid ? 0.38  : 0.2;
      final sw2     = isMajor ? 1.8   : 1.0;

      canvas.drawLine(
        Offset(px, py),
        Offset(px + nx * tickLen, py + ny * tickLen),
        Paint()
          ..color = Colors.white.withValues(alpha: alpha2)
          ..strokeWidth = sw2
          ..strokeCap = StrokeCap.round,
      );
    }

    // 위치 지시자: 0° = 반원 중앙(꼭대기), ±90° = 좌우 끝
    final displayDeg = rotationDeg > 180 ? rotationDeg - 360 : rotationDeg;
    final arcDeg = (90.0 - displayDeg).clamp(0.0, 180.0);
    final ia = arcDeg * math.pi / 180;
    final ipx = cx - r * math.cos(ia);
    final ipy = cy - r * math.sin(ia);

    // Glow
    canvas.drawCircle(
      Offset(ipx, ipy), 7,
      Paint()
        ..color = AppColors.primary.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    // 지시자 돇
    canvas.drawCircle(
      Offset(ipx, ipy), 4.5,
      Paint()..color = AppColors.primary.withValues(alpha: 0.95),
    );
  }

  @override
  bool shouldRepaint(_SemiCircleRulerPainter old) =>
      old.rotationDeg != rotationDeg;
}


/// 가구 주변 회전 가이드 링 (펄싱)
class _SelectionRing extends StatefulWidget {
  const _SelectionRing();
  @override
  State<_SelectionRing> createState() => _SelectionRingState();
}

class _SelectionRingState extends State<_SelectionRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.25, end: 0.7)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _pulse,
    builder: (context, _) => Center(
      child: Transform.translate(
        offset: const Offset(0, 60),
        child: CustomPaint(
          size: const Size(180, 60),
          painter: _SelectionRingPainter(opacity: _pulse.value),
        ),
      ),
    ),
  );
}

class _SelectionRingPainter extends CustomPainter {
  final double opacity;
  _SelectionRingPainter({required this.opacity});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.primary.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    canvas.drawOval(
      Rect.fromCenter(center: Offset(size.width / 2, size.height / 2),
          width: size.width, height: size.height),
      paint,
    );
    final arrowPaint = Paint()
      ..color = AppColors.primary.withValues(alpha: opacity * 0.9)
      ..style = PaintingStyle.fill;
    final cx = size.width / 2; final cy = size.height / 2;
    canvas.drawPath(Path()
      ..moveTo(cx - size.width * 0.38, cy)
      ..lineTo(cx - size.width * 0.38 + 8, cy - 5)
      ..lineTo(cx - size.width * 0.38 + 8, cy + 5)
      ..close(), arrowPaint);
    canvas.drawPath(Path()
      ..moveTo(cx + size.width * 0.38, cy)
      ..lineTo(cx + size.width * 0.38 - 8, cy - 5)
      ..lineTo(cx + size.width * 0.38 - 8, cy + 5)
      ..close(), arrowPaint);
  }

  @override
  bool shouldRepaint(_SelectionRingPainter old) => old.opacity != opacity;
}

/// 드래그 힌트 오버레이 (손가락 스와이프 애니메이션 → 자동 사라짐)
class _DragHintOverlay extends StatefulWidget {
  final VoidCallback onDismiss;
  const _DragHintOverlay({required this.onDismiss});
  @override
  State<_DragHintOverlay> createState() => _DragHintOverlayState();
}

class _DragHintOverlayState extends State<_DragHintOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800));
    _slide = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 0, end: 28).chain(CurveTween(curve: Curves.easeIn)), weight: 1),
      TweenSequenceItem(tween: Tween<double>(begin: 28, end: -28).chain(CurveTween(curve: Curves.easeInOut)), weight: 2),
      TweenSequenceItem(tween: Tween<double>(begin: -28, end: 0).chain(CurveTween(curve: Curves.easeOut)), weight: 1),
    ]).animate(CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.72)));
    _fade = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.72, 1.0, curve: Curves.easeOut)),
    );
    _ctrl.forward().then((_) { if (mounted) widget.onDismiss(); });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _ctrl,
    builder: (context, _) => FadeTransition(
      opacity: _fade,
      child: Align(
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.translate(
                offset: Offset(_slide.value, 0),
                child: const Icon(Icons.swipe_rounded, color: Colors.white, size: 32),
              ),
              const SizedBox(height: 8),
              Text(
                '← Drag here to rotate →',
                style: GoogleFonts.nunito(
                  color: Colors.white, fontSize: 13,
                  fontWeight: FontWeight.w600, letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
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

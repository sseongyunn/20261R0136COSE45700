import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

import '../api_client.dart';
import '../theme/app_theme.dart';

class ArViewScreen extends StatefulWidget {
  final String? modelUrl;
  final String? modelName;
  final String? dimensions;

  const ArViewScreen({
    super.key,
    this.modelUrl,
    this.modelName,
    this.dimensions,
  });

  @override
  State<ArViewScreen> createState() => _ArViewScreenState();
}

class _ArViewScreenState extends State<ArViewScreen> {
  static const _previewNodeName = 'placement_preview';
  static const _objectPickRadius = 110.0;

  ARKitController? _arkitController;
  Timer? _raycastTimer;

  final Set<String> _planeAnchorIds = {};
  final Map<String, _PreparedModel> _preparedModels = {};
  final Map<String, _PlacedModel> _placedModels = {};

  List<FurnitureAsset> _ownedAssets = [];
  bool _libraryLoading = false;
  bool _libraryOpen = true;
  bool _preparingModel = false;
  String? _libraryError;
  String? _loadingAssetId;
  String? _downloadError;
  String? _selectedNodeName;
  String? _draggingNodeName;
  vector.Vector3? _reticlePosition;
  vector.Vector3? _previewPosition;
  bool _placementEligible = false;
  bool _previewNodeAdded = false;
  bool _previewIsInvalid = true;
  String? _previewGlbPath;
  String? _statusMessage;
  bool _showDragHint = false;

  _ArAsset? _activeAsset;

  bool get _planeDetected => _planeAnchorIds.isNotEmpty;

  _PlacedModel? get _selectedModel {
    final nodeName = _selectedNodeName;
    if (nodeName == null) return null;
    return _placedModels[nodeName];
  }

  double get _selectedYawDegrees {
    final selected = _selectedModel;
    if (selected == null) return 0;
    return ((selected.zRotationRadians * 180 / math.pi) % 360 + 360) % 360;
  }

  @override
  void initState() {
    super.initState();
    _loadOwnedAssets();
    final url = widget.modelUrl;
    if (url != null && url.isNotEmpty) {
      final asset = _ArAsset(
        id: 'initial_${url.hashCode.abs()}',
        name: widget.modelName?.trim().isNotEmpty == true
            ? widget.modelName!.trim()
            : '선택한 모델',
        category: 'furniture',
        dimensions: widget.dimensions ?? '크기 미입력',
        modelUrl: url,
      );
      _activeAsset = asset;
      _prepareAsset(asset);
    }
  }

  @override
  void dispose() {
    _raycastTimer?.cancel();
    _arkitController?.dispose();
    super.dispose();
  }

  Future<void> _loadOwnedAssets() async {
    setState(() {
      _libraryLoading = true;
      _libraryError = null;
    });

    try {
      final assets = await context.read<ApiClient>().listFurnitureAssets();
      if (!mounted) return;
      setState(() => _ownedAssets = assets);
    } catch (e) {
      if (mounted) setState(() => _libraryError = e.toString());
    } finally {
      if (mounted) setState(() => _libraryLoading = false);
    }
  }

  Future<void> _selectOwnedAsset(FurnitureAsset asset) async {
    if (_loadingAssetId != null) return;
    setState(() {
      _loadingAssetId = asset.assetId;
      _downloadError = null;
      _selectedNodeName = null;
      _statusMessage = null;
    });

    try {
      final url = await context.read<ApiClient>().getModelUrl(asset.assetId);
      final arAsset = _ArAsset(
        id: asset.assetId,
        name: asset.displayName,
        category: asset.displayCategory,
        dimensions: asset.dimensions,
        modelUrl: url,
      );
      if (!mounted) return;
      setState(() => _activeAsset = arAsset);
      await _prepareAsset(arAsset);
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloadError = '모델 URL을 가져오지 못했어요: $e');
    } finally {
      if (mounted) setState(() => _loadingAssetId = null);
    }
  }

  Future<void> _prepareAsset(_ArAsset asset) async {
    if (_preparedModels.containsKey(asset.id)) return;

    setState(() {
      _preparingModel = true;
      _downloadError = null;
    });

    try {
      final dir = await getApplicationDocumentsDirectory();
      final fileName = 'ar_model_${asset.id.hashCode.abs()}.glb';
      final file = File('${dir.path}/$fileName');

      if (asset.modelUrl.startsWith('file://') ||
          asset.modelUrl.startsWith('/')) {
        final path = asset.modelUrl.startsWith('file://')
            ? asset.modelUrl.substring(7)
            : asset.modelUrl;
        final source = File(path);
        if (!await source.exists()) {
          throw Exception('로컬 모델 파일을 찾을 수 없습니다.');
        }
        if (source.path != file.path) {
          await source.copy(file.path);
        }
      } else {
        final response = await http.get(Uri.parse(asset.modelUrl));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception('GLB 다운로드 실패: HTTP ${response.statusCode}');
        }
        await file.writeAsBytes(response.bodyBytes);
      }

      final previewValidFileName =
          'ar_preview_gray_${asset.id.hashCode.abs()}.glb';
      final previewInvalidFileName =
          'ar_preview_red_${asset.id.hashCode.abs()}.glb';
      await _writePreviewGlb(
        sourceFile: file,
        targetFile: File('${dir.path}/$previewValidFileName'),
        rgba: const [0.62, 0.62, 0.62, 0.34],
      );
      await _writePreviewGlb(
        sourceFile: file,
        targetFile: File('${dir.path}/$previewInvalidFileName'),
        rgba: const [1.0, 0.12, 0.08, 0.42],
      );

      final calibration = await _inspectModelFile(file, asset.dimensions);
      if (!mounted) return;
      setState(() {
        _preparedModels[asset.id] = _PreparedModel(
          asset: asset,
          localGlbPath: fileName,
          previewValidGlbPath: previewValidFileName,
          previewInvalidGlbPath: previewInvalidFileName,
          scale: calibration.scale,
          baseRotation: calibration.baseRotation,
          previewSize: _previewSizeFromDimensions(asset.dimensions),
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _downloadError = e.toString());
    } finally {
      if (mounted) setState(() => _preparingModel = false);
    }
  }

  Future<void> _writePreviewGlb({
    required File sourceFile,
    required File targetFile,
    required List<double> rgba,
  }) async {
    final bytes = await sourceFile.readAsBytes();
    if (bytes.length < 20) {
      await sourceFile.copy(targetFile.path);
      return;
    }

    final data = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final magic = data.getUint32(0, Endian.little);
    final version = data.getUint32(4, Endian.little);
    final jsonChunkLength = data.getUint32(12, Endian.little);
    final jsonChunkType = data.getUint32(16, Endian.little);
    if (magic != 0x46546C67 || jsonChunkType != 0x4E4F534A) {
      await sourceFile.copy(targetFile.path);
      return;
    }

    final jsonBytes = bytes.sublist(20, 20 + jsonChunkLength);
    final gltf = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
    final material = <String, dynamic>{
      'name': 'AR placement preview',
      'alphaMode': 'BLEND',
      'doubleSided': true,
      'pbrMetallicRoughness': {
        'baseColorFactor': rgba,
        'metallicFactor': 0,
        'roughnessFactor': 1,
      },
    };

    final materials = (gltf['materials'] as List<dynamic>?) ?? <dynamic>[];
    if (materials.isEmpty) {
      materials.add(material);
      gltf['materials'] = materials;
    } else {
      for (var i = 0; i < materials.length; i += 1) {
        materials[i] = Map<String, dynamic>.from(material);
      }
    }

    final meshes = gltf['meshes'] as List<dynamic>?;
    if (meshes != null) {
      for (final mesh in meshes) {
        final primitives =
            (mesh as Map<String, dynamic>)['primitives'] as List<dynamic>?;
        if (primitives == null) continue;
        for (final primitive in primitives) {
          (primitive as Map<String, dynamic>)['material'] = 0;
        }
      }
    }

    final encodedJson = utf8.encode(jsonEncode(gltf));
    final paddedJsonLength = _paddedLength(encodedJson.length);
    final paddedJson = Uint8List(paddedJsonLength)
      ..setRange(0, encodedJson.length, encodedJson);
    for (var i = encodedJson.length; i < paddedJson.length; i += 1) {
      paddedJson[i] = 0x20;
    }

    final trailingChunks = bytes.sublist(20 + jsonChunkLength);
    final totalLength = 12 + 8 + paddedJson.length + trailingChunks.length;
    final output = BytesBuilder(copy: false);
    final header = ByteData(12)
      ..setUint32(0, magic, Endian.little)
      ..setUint32(4, version, Endian.little)
      ..setUint32(8, totalLength, Endian.little);
    final jsonHeader = ByteData(8)
      ..setUint32(0, paddedJson.length, Endian.little)
      ..setUint32(4, 0x4E4F534A, Endian.little);

    output
      ..add(header.buffer.asUint8List())
      ..add(jsonHeader.buffer.asUint8List())
      ..add(paddedJson)
      ..add(trailingChunks);
    await targetFile.writeAsBytes(output.takeBytes(), flush: true);
  }

  int _paddedLength(int length) => (length + 3) & ~3;

  Future<_ModelCalibration> _inspectModelFile(
    File file,
    String? dimensions,
  ) async {
    var scale = 0.3;
    var baseRotation = vector.Vector3.zero();
    final physicalMaxDim = _parsePhysicalMaxDimension(dimensions);

    try {
      final bytes = await file.readAsBytes();
      final data = ByteData.view(
        bytes.buffer,
        bytes.offsetInBytes,
        bytes.length,
      );
      if (data.lengthInBytes < 20) {
        return _ModelCalibration(scale: scale, baseRotation: baseRotation);
      }

      final magic = data.getUint32(0, Endian.little);
      if (magic != 0x46546C67) {
        return _ModelCalibration(scale: scale, baseRotation: baseRotation);
      }

      final chunk0Length = data.getUint32(12, Endian.little);
      final chunk0Type = data.getUint32(16, Endian.little);
      if (chunk0Type != 0x4E4F534A) {
        return _ModelCalibration(scale: scale, baseRotation: baseRotation);
      }

      final jsonBytes = bytes.sublist(20, 20 + chunk0Length);
      final gltf = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;

      final accessors = gltf['accessors'] as List<dynamic>?;
      final meshes = gltf['meshes'] as List<dynamic>?;
      var maxModelLength = 0.0;

      if (accessors != null && meshes != null) {
        for (final mesh in meshes) {
          final primitives =
              (mesh as Map<String, dynamic>)['primitives'] as List<dynamic>?;
          if (primitives == null) continue;
          for (final prim in primitives) {
            final attributes =
                (prim as Map<String, dynamic>)['attributes']
                    as Map<String, dynamic>?;
            if (attributes == null || !attributes.containsKey('POSITION')) {
              continue;
            }
            final accessor =
                accessors[attributes['POSITION'] as int]
                    as Map<String, dynamic>;
            final minArr = accessor['min'] as List<dynamic>?;
            final maxArr = accessor['max'] as List<dynamic>?;
            if (minArr == null ||
                maxArr == null ||
                minArr.length < 3 ||
                maxArr.length < 3) {
              continue;
            }
            final dx = ((maxArr[0] as num) - (minArr[0] as num))
                .abs()
                .toDouble();
            final dy = ((maxArr[1] as num) - (minArr[1] as num))
                .abs()
                .toDouble();
            final dz = ((maxArr[2] as num) - (minArr[2] as num))
                .abs()
                .toDouble();
            maxModelLength = math.max(
              maxModelLength,
              [dx, dy, dz].reduce(math.max),
            );
          }
        }
      }

      if (physicalMaxDim != null && maxModelLength > 0) {
        scale = physicalMaxDim / maxModelLength;
      }

      final scenes = gltf['scenes'] as List<dynamic>?;
      final nodes = gltf['nodes'] as List<dynamic>?;
      final defaultScene = gltf['scene'] as int? ?? 0;
      if (scenes != null &&
          nodes != null &&
          scenes.isNotEmpty &&
          defaultScene < scenes.length) {
        final rootNodeIndices =
            ((scenes[defaultScene] as Map<String, dynamic>)['nodes']
                        as List<dynamic>? ??
                    [])
                .cast<int>();

        for (final index in rootNodeIndices) {
          final node = nodes[index] as Map<String, dynamic>;
          final rotation = node['rotation'] as List<dynamic>?;
          if (rotation == null || rotation.length != 4) continue;
          final rx = (rotation[0] as num).toDouble();
          final ry = (rotation[1] as num).toDouble();
          final rz = (rotation[2] as num).toDouble();
          final rw = (rotation[3] as num).toDouble();
          if (ry.abs() < 0.01 && rz.abs() < 0.01) {
            final angle =
                2 * math.asin(rx.clamp(-1.0, 1.0)) * (rw < 0 ? -1.0 : 1.0);
            if ((angle + math.pi / 2).abs() < 0.1) {
              baseRotation = vector.Vector3(math.pi / 2, 0, 0);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[AR] GLB inspection skipped: $e');
    }

    return _ModelCalibration(scale: scale, baseRotation: baseRotation);
  }

  double? _parsePhysicalMaxDimension(String? dimensions) {
    if (dimensions == null || dimensions.contains('미입력')) return null;
    final regex = RegExp(r'([\d.]+)\s*×\s*([\d.]+)\s*×\s*([\d.]+)\s*cm');
    final match = regex.firstMatch(dimensions);
    if (match == null) return null;
    final values = [
      double.tryParse(match.group(1)!),
      double.tryParse(match.group(2)!),
      double.tryParse(match.group(3)!),
    ].whereType<double>().where((v) => v > 0).toList();
    if (values.isEmpty) return null;
    return values.reduce(math.max) / 100.0;
  }

  _PreviewSize _previewSizeFromDimensions(String? dimensions) {
    if (dimensions == null || dimensions.contains('미입력')) {
      return const _PreviewSize(width: 0.45, height: 0.45, depth: 0.45);
    }
    final regex = RegExp(r'([\d.]+)\s*×\s*([\d.]+)\s*×\s*([\d.]+)\s*cm');
    final match = regex.firstMatch(dimensions);
    if (match == null) {
      return const _PreviewSize(width: 0.45, height: 0.45, depth: 0.45);
    }
    double cmToM(String value, double fallback) {
      final parsed = double.tryParse(value);
      if (parsed == null || parsed <= 0) return fallback;
      return (parsed / 100.0).clamp(0.12, 2.4).toDouble();
    }

    return _PreviewSize(
      width: cmToM(match.group(1)!, 0.45),
      depth: cmToM(match.group(2)!, 0.45),
      height: cmToM(match.group(3)!, 0.45),
    );
  }

  void _onARKitViewCreated(ARKitController controller) {
    _arkitController = controller;
    controller.onAddNodeForAnchor = _onAnchorAdded;
    controller.onUpdateNodeForAnchor = _onAnchorUpdated;
    controller.onDidRemoveNodeForAnchor = _onAnchorRemoved;
    _raycastTimer = Timer.periodic(
      const Duration(milliseconds: 120),
      (_) => _performRaycast(),
    );
  }

  void _onAnchorAdded(ARKitAnchor anchor) {
    if (anchor is ARKitPlaneAnchor) {
      _planeAnchorIds.add(anchor.identifier);
      if (mounted) setState(() {});
    }
  }

  void _onAnchorUpdated(ARKitAnchor anchor) {
    if (anchor is ARKitPlaneAnchor) {
      _planeAnchorIds.add(anchor.identifier);
      if (mounted) setState(() {});
    }
  }

  void _onAnchorRemoved(ARKitAnchor anchor) {
    if (anchor is ARKitPlaneAnchor) {
      _planeAnchorIds.remove(anchor.identifier);
      if (mounted) setState(() {});
    }
  }

  Future<void> _handleSceneTapDown(TapDownDetails details) async {
    final nodeName = await _nearestModelAt(details.localPosition);
    if (nodeName == null) return;
    final model = _placedModels[nodeName];
    if (model == null || !mounted) return;
    setState(() {
      _selectedNodeName = nodeName;
      _activeAsset = model.asset;
      _statusMessage = '${model.asset.name} 선택됨';
    });
  }

  Future<void> _handleScenePanStart(DragStartDetails details) async {
    final nodeName = await _nearestModelAt(details.localPosition);
    if (nodeName == null) return;
    final model = _placedModels[nodeName];
    if (model == null || !mounted) return;
    setState(() {
      _draggingNodeName = nodeName;
      _selectedNodeName = nodeName;
      _activeAsset = model.asset;
      _statusMessage = '${model.asset.name} 이동 중';
    });
  }

  Future<void> _handleScenePanUpdate(DragUpdateDetails details) async {
    final nodeName = _draggingNodeName;
    if (nodeName == null) return;
    final model = _placedModels[nodeName];
    if (model == null) return;

    final hit = await _hitTestScreenPoint(details.localPosition);
    if (hit == null) {
      _showPlacementMessage('평평한 바닥이나 테이블 위에서만 이동할 수 있어요.');
      return;
    }

    model.position = hit;
    await _syncPlacedModelTransform(model);
  }

  void _handleScenePanEnd() {
    if (_draggingNodeName == null) return;
    setState(() {
      _draggingNodeName = null;
      _statusMessage = '이 위치에 이동했어요.';
    });
  }

  Future<String?> _nearestModelAt(Offset screenPoint) async {
    final controller = _arkitController;
    if (controller == null || _placedModels.isEmpty) return null;

    String? nearestNodeName;
    var nearestDistance = double.infinity;
    for (final entry in _placedModels.entries) {
      final model = entry.value;
      final projectedPoints = <vector.Vector3?>[
        await controller.projectPoint(model.position),
        await controller.projectPoint(
          model.position + vector.Vector3(0, model.previewSize.height / 2, 0),
        ),
      ].whereType<vector.Vector3>();
      if (projectedPoints.isEmpty) continue;
      final pickRadius =
          (_objectPickRadius *
                  math.max(
                    1.0,
                    math.max(
                          model.previewSize.width,
                          math.max(
                            model.previewSize.height,
                            model.previewSize.depth,
                          ),
                        ) /
                        0.6,
                  ))
              .clamp(80.0, 180.0)
              .toDouble();
      final distance = projectedPoints
          .map((point) => (Offset(point.x, point.y) - screenPoint).distance)
          .reduce(math.min);
      if (distance < pickRadius && distance < nearestDistance) {
        nearestDistance = distance;
        nearestNodeName = entry.key;
      }
    }
    return nearestNodeName;
  }

  Future<void> _performRaycast() async {
    if (_arkitController == null || !mounted) return;

    final hit = await _hitTestNormalized(0.5, 0.5);
    final hover = hit ?? await _cameraForwardPreviewPosition();
    if (!mounted) return;

    setState(() {
      _reticlePosition = hit;
      _previewPosition = hover;
      _placementEligible = hit != null;
    });
    await _updatePreviewNode();
  }

  Future<vector.Vector3?> _hitTestNormalized(double x, double y) async {
    final controller = _arkitController;
    if (controller == null) return null;
    final hits = await controller.performHitTest(x: x, y: y);
    final planeHit = hits.firstWhereOrNull(
      (hit) =>
          hit.type == ARKitHitTestResultType.existingPlaneUsingExtent ||
          hit.type == ARKitHitTestResultType.existingPlaneUsingGeometry,
    );
    if (planeHit == null) return null;
    final translation = planeHit.worldTransform.getColumn(3);
    return vector.Vector3(translation.x, translation.y, translation.z);
  }

  Future<vector.Vector3?> _hitTestScreenPoint(Offset point) {
    final size = MediaQuery.sizeOf(context);
    return _hitTestNormalized(
      (point.dx / size.width).clamp(0.02, 0.98).toDouble(),
      (point.dy / size.height).clamp(0.02, 0.98).toDouble(),
    );
  }

  Future<vector.Vector3?> _cameraForwardPreviewPosition() async {
    final camera = await _arkitController?.pointOfViewTransform();
    if (camera == null) return null;
    final cameraPos = camera.getTranslation();
    final zAxis = camera.getColumn(2);
    final forward = vector.Vector3(-zAxis.x, -zAxis.y, -zAxis.z);
    if (forward.length2 == 0) return cameraPos;
    forward.normalize();
    return cameraPos + forward.scaled(1.1) + vector.Vector3(0, -0.12, 0);
  }

  Future<void> _updatePreviewNode() async {
    final controller = _arkitController;
    final activeAsset = _activeAsset;
    final position = _previewPosition;
    final prepared = activeAsset == null
        ? null
        : _preparedModels[activeAsset.id];
    if (controller == null ||
        activeAsset == null ||
        prepared == null ||
        position == null ||
        _selectedModel != null) {
      if (_previewNodeAdded) {
        await controller?.remove(_previewNodeName);
        _previewNodeAdded = false;
        _previewGlbPath = null;
      }
      return;
    }

    final invalid = !_placementEligible;
    final previewPath = invalid
        ? prepared.previewInvalidGlbPath
        : prepared.previewValidGlbPath;

    if (_previewNodeAdded &&
        _previewIsInvalid == invalid &&
        _previewGlbPath == previewPath) {
      final node = ARKitGltfNode(
        name: _previewNodeName,
        assetType: AssetType.documents,
        url: previewPath,
        scale: vector.Vector3.all(prepared.scale),
        position: position,
        eulerAngles: prepared.baseRotation,
      );
      await controller.update(_previewNodeName, node: node);
      return;
    }

    if (_previewNodeAdded) {
      await controller.remove(_previewNodeName);
    }
    final node = ARKitGltfNode(
      name: _previewNodeName,
      assetType: AssetType.documents,
      url: previewPath,
      scale: vector.Vector3.all(prepared.scale),
      position: position,
      eulerAngles: prepared.baseRotation,
    );
    await controller.add(node);
    _previewNodeAdded = true;
    _previewIsInvalid = invalid;
    _previewGlbPath = previewPath;
  }

  Future<void> _placeActiveModel() async {
    final active = _activeAsset;
    if (active == null) {
      _showPlacementMessage('오른쪽 목록에서 배치할 모델을 먼저 선택해 주세요.');
      return;
    }
    final prepared = _preparedModels[active.id];
    if (prepared == null) {
      await _prepareAsset(active);
      return;
    }
    final position = _reticlePosition;
    if (position == null || !_placementEligible) {
      _showPlacementMessage('평평한 바닥이나 테이블 위에만 배치할 수 있어요.');
      return;
    }

    final nodeName = 'furniture_${DateTime.now().microsecondsSinceEpoch}';
    final model = _PlacedModel(
      nodeName: nodeName,
      asset: active,
      localGlbPath: prepared.localGlbPath,
      scale: prepared.scale,
      baseRotation: prepared.baseRotation,
      previewSize: prepared.previewSize,
      position: position,
    );

    await _addPlacedModel(model);
    if (!mounted) return;
    setState(() {
      _placedModels[nodeName] = model;
      _selectedNodeName = nodeName;
      _showDragHint = true;
      _statusMessage = '${active.name} 배치됨';
    });
  }

  Future<void> _addPlacedModel(_PlacedModel model) async {
    final controller = _arkitController;
    if (controller == null) return;

    try {
      await controller.add(_gltfNodeFor(model));
    } catch (e) {
      final fallback = ARKitNode(
        name: model.nodeName,
        geometry: ARKitBox(
          width: 0.18,
          height: 0.18,
          length: 0.18,
          materials: [
            ARKitMaterial(
              transparency: 0.55,
              diffuse: ARKitMaterialProperty.color(Colors.redAccent),
            ),
          ],
        ),
        position: model.position + vector.Vector3(0, 0.09, 0),
      );
      await controller.add(fallback);
    }
  }

  Future<void> _rebuildPlacedModel(_PlacedModel model) async {
    final controller = _arkitController;
    if (controller == null) return;
    await controller.remove(model.nodeName);
    await _addPlacedModel(model);
    if (mounted) setState(() {});
  }

  ARKitGltfNode _gltfNodeFor(_PlacedModel model) {
    return ARKitGltfNode(
      assetType: AssetType.documents,
      url: model.localGlbPath,
      scale: vector.Vector3.all(model.scale),
      position: model.position,
      eulerAngles: model.eulerAngles,
      name: model.nodeName,
    );
  }

  Future<void> _syncPlacedModelTransform(_PlacedModel model) async {
    final controller = _arkitController;
    if (controller == null) return;
    try {
      await controller.update(model.nodeName, node: _gltfNodeFor(model));
    } catch (_) {
      await _rebuildPlacedModel(model);
      return;
    }
    if (mounted) setState(() {});
  }

  Future<void> _rotateSelected(double angleDelta) async {
    final selected = _selectedModel;
    if (selected == null) return;
    selected.zRotationRadians += angleDelta;
    await _syncPlacedModelTransform(selected);
  }

  Future<void> _rotateSelectedXQuarter() async {
    final selected = _selectedModel;
    if (selected == null) return;
    selected.xQuarterTurns = (selected.xQuarterTurns + 1) % 4;
    await _syncPlacedModelTransform(selected);
    _showPlacementMessage('X축을 90도 회전했어요.');
  }

  Future<void> _rotateSelectedYQuarter() async {
    final selected = _selectedModel;
    if (selected == null) return;
    selected.yQuarterTurns = (selected.yQuarterTurns + 1) % 4;
    await _syncPlacedModelTransform(selected);
    _showPlacementMessage('Y축을 90도 회전했어요.');
  }

  Future<void> _removeSelected() async {
    final nodeName = _selectedNodeName;
    if (nodeName == null || _arkitController == null) return;
    await _arkitController!.remove(nodeName);
    if (!mounted) return;
    setState(() {
      _placedModels.remove(nodeName);
      _selectedNodeName = _placedModels.keys.firstOrNull;
      _statusMessage = '선택한 모델을 제거했어요.';
    });
  }

  void _showPlacementMessage(String message) {
    if (!mounted) return;
    setState(() => _statusMessage = message);
  }

  @override
  Widget build(BuildContext context) {
    final activeName =
        _selectedModel?.asset.name ?? _activeAsset?.name ?? 'AR 공간';
    final hasSelectedObject = _selectedModel != null;
    final canShowPlacement = _activeAsset != null && !hasSelectedObject;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          ARKitSceneView(
            configuration: ARKitConfiguration.worldTracking,
            planeDetection: ARPlaneDetection.horizontal,
            enableTapRecognizer: false,
            enablePanRecognizer: false,
            showFeaturePoints: false,
            onARKitViewCreated: _onARKitViewCreated,
          ),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapDown: _handleSceneTapDown,
              onPanStart: _handleScenePanStart,
              onPanUpdate: _handleScenePanUpdate,
              onPanEnd: (_) => _handleScenePanEnd(),
              onPanCancel: _handleScenePanEnd,
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopBar(
              modelName: activeName,
              placedCount: _placedModels.length,
              onClose: () => Navigator.pop(context),
            ),
          ),
          if (_libraryError != null)
            _HintBadge(
              icon: Icons.error_outline_rounded,
              text: '모델 목록을 불러오지 못했어요.',
              color: Colors.redAccent,
            )
          else if (_downloadError != null)
            _HintBadge(
              icon: Icons.error_outline_rounded,
              text: _downloadError!,
              color: Colors.redAccent,
            )
          else if (!_planeDetected)
            _HintBadge(
              icon: Icons.screen_search_desktop_rounded,
              text: '카메라를 천천히 움직여 평평한 바닥이나 테이블을 스캔해 주세요.',
              color: Colors.white,
            )
          else if (_activeAsset == null)
            const _HintBadge(
              icon: Icons.inventory_2_outlined,
              text: '오른쪽 목록에서 배치할 모델을 선택해 주세요.',
              color: AppColors.primaryLight,
            )
          else if (!_placementEligible && !hasSelectedObject)
            const _HintBadge(
              icon: Icons.warning_amber_rounded,
              text: '평평한 표면 위에만 배치할 수 있어요.',
              color: Colors.redAccent,
            )
          else if (_statusMessage != null)
            _HintBadge(
              icon: Icons.info_outline_rounded,
              text: _statusMessage!,
              color: AppColors.primaryLight,
            ),
          if (_preparingModel)
            const _PreparingOverlay()
          else if (canShowPlacement)
            _PlacementReticle(isValid: _placementEligible),
          if (hasSelectedObject) const _SelectionRing(),
          if (_showDragHint)
            Positioned(
              bottom: MediaQuery.of(context).size.width / 2 + 20,
              left: 0,
              right: 0,
              child: _DragHintOverlay(
                onDismiss: () => setState(() => _showDragHint = false),
              ),
            ),
          _LibraryHandle(
            isOpen: _libraryOpen,
            onTap: () => setState(() => _libraryOpen = !_libraryOpen),
          ),
          _AssetSidebar(
            isOpen: _libraryOpen,
            loading: _libraryLoading,
            assets: _ownedAssets,
            activeAssetId: _activeAsset?.id,
            loadingAssetId: _loadingAssetId,
            onRefresh: _loadOwnedAssets,
            onSelect: _selectOwnedAsset,
            onDragEnd: (velocity) {
              if (velocity < -250) setState(() => _libraryOpen = true);
              if (velocity > 250) setState(() => _libraryOpen = false);
            },
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _BottomBar(
              hasSelectedObject: hasSelectedObject,
              canPlace: _activeAsset != null && _placementEligible,
              modelRotationDeg: _selectedYawDegrees,
              xRotationDeg: ((_selectedModel?.xQuarterTurns ?? 0) * 90) % 360,
              yRotationDeg: ((_selectedModel?.yQuarterTurns ?? 0) * 90) % 360,
              onPlace: _placeActiveModel,
              onRotateDrag: (dx) => _rotateSelected(-dx * 0.013),
              onRotateXQuarter: _rotateSelectedXQuarter,
              onRotateYQuarter: _rotateSelectedYQuarter,
              onRemove: _removeSelected,
            ),
          ),
        ],
      ),
    );
  }
}

class _ArAsset {
  final String id;
  final String name;
  final String category;
  final String dimensions;
  final String modelUrl;

  const _ArAsset({
    required this.id,
    required this.name,
    required this.category,
    required this.dimensions,
    required this.modelUrl,
  });
}

class _PreparedModel {
  final _ArAsset asset;
  final String localGlbPath;
  final String previewValidGlbPath;
  final String previewInvalidGlbPath;
  final double scale;
  final vector.Vector3 baseRotation;
  final _PreviewSize previewSize;

  const _PreparedModel({
    required this.asset,
    required this.localGlbPath,
    required this.previewValidGlbPath,
    required this.previewInvalidGlbPath,
    required this.scale,
    required this.baseRotation,
    required this.previewSize,
  });
}

class _PlacedModel {
  final String nodeName;
  final _ArAsset asset;
  final String localGlbPath;
  final double scale;
  final vector.Vector3 baseRotation;
  final _PreviewSize previewSize;
  vector.Vector3 position;
  double zRotationRadians;
  int xQuarterTurns;
  int yQuarterTurns;

  _PlacedModel({
    required this.nodeName,
    required this.asset,
    required this.localGlbPath,
    required this.scale,
    required this.baseRotation,
    required this.previewSize,
    required this.position,
  }) : zRotationRadians = 0,
       xQuarterTurns = 0,
       yQuarterTurns = 0;

  vector.Vector3 get eulerAngles =>
      baseRotation +
      vector.Vector3(
        xQuarterTurns * math.pi / 2,
        zRotationRadians,
        yQuarterTurns * math.pi / 2,
      );
}

class _ModelCalibration {
  final double scale;
  final vector.Vector3 baseRotation;

  const _ModelCalibration({required this.scale, required this.baseRotation});
}

class _PreviewSize {
  final double width;
  final double height;
  final double depth;

  const _PreviewSize({
    required this.width,
    required this.height,
    required this.depth,
  });
}

class _TopBar extends StatelessWidget {
  final String modelName;
  final int placedCount;
  final VoidCallback onClose;

  const _TopBar({
    required this.modelName,
    required this.placedCount,
    required this.onClose,
  });

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
          colors: [Colors.black.withValues(alpha: 0.76), Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton.filled(
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.15),
              foregroundColor: Colors.white,
            ),
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  placedCount == 0 ? 'AR 배치 공간' : '$placedCount개 배치됨',
                  style: GoogleFonts.nunito(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
                Text(
                  modelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.nunito(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.86),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.view_in_ar_rounded,
                  color: Colors.white,
                  size: 14,
                ),
                const SizedBox(width: 5),
                Text(
                  'ARKit',
                  style: GoogleFonts.nunito(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
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

class _HintBadge extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _HintBadge({
    required this.icon,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 80,
      left: 20,
      right: 86,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 17),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  style: GoogleFonts.nunito(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
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

class _PreparingOverlay extends StatelessWidget {
  const _PreparingOverlay();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.48),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.64),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: AppColors.primary),
              const SizedBox(height: 14),
              Text(
                '3D 모델 준비 중...',
                style: GoogleFonts.nunito(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlacementReticle extends StatelessWidget {
  final bool isValid;

  const _PlacementReticle({required this.isValid});

  @override
  Widget build(BuildContext context) {
    final color = isValid ? AppColors.primaryLight : Colors.redAccent;
    return Center(
      child: IgnorePointer(
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.13),
            border: Border.all(color: color.withValues(alpha: 0.78), width: 2),
          ),
          child: Icon(
            isValid ? Icons.add_rounded : Icons.close_rounded,
            color: color,
            size: 28,
          ),
        ),
      ),
    );
  }
}

class _LibraryHandle extends StatelessWidget {
  final bool isOpen;
  final VoidCallback onTap;

  const _LibraryHandle({required this.isOpen, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: isOpen ? 190 : 0,
      top: MediaQuery.of(context).size.height * 0.45,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 72,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.58),
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(16),
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          ),
          child: Icon(
            isOpen ? Icons.chevron_right_rounded : Icons.chevron_left_rounded,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _AssetSidebar extends StatelessWidget {
  final bool isOpen;
  final bool loading;
  final List<FurnitureAsset> assets;
  final String? activeAssetId;
  final String? loadingAssetId;
  final VoidCallback onRefresh;
  final ValueChanged<FurnitureAsset> onSelect;
  final ValueChanged<double> onDragEnd;

  const _AssetSidebar({
    required this.isOpen,
    required this.loading,
    required this.assets,
    required this.activeAssetId,
    required this.loadingAssetId,
    required this.onRefresh,
    required this.onSelect,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      top: MediaQuery.of(context).padding.top + 86,
      right: isOpen ? 0 : -190,
      bottom: MediaQuery.of(context).padding.bottom + 148,
      width: 190,
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          onDragEnd(details.primaryVelocity ?? 0);
        },
        child: ClipRRect(
          borderRadius: const BorderRadius.horizontal(
            left: Radius.circular(18),
          ),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                border: Border(
                  left: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                  bottom: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 8, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '내 모델',
                            style: GoogleFonts.nunito(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '새로고침',
                          onPressed: loading ? null : onRefresh,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          color: Colors.white70,
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: loading
                        ? const Center(
                            child: CircularProgressIndicator(
                              color: AppColors.primary,
                              strokeWidth: 2,
                            ),
                          )
                        : assets.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(18),
                              child: Text(
                                '생성된 모델이 없어요',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.nunito(
                                  color: Colors.white60,
                                  fontSize: 12,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                            itemBuilder: (context, index) {
                              final asset = assets[index];
                              final selected = asset.assetId == activeAssetId;
                              final busy = asset.assetId == loadingAssetId;
                              return _SidebarAssetTile(
                                asset: asset,
                                selected: selected,
                                busy: busy,
                                onTap: () => onSelect(asset),
                              );
                            },
                            separatorBuilder: (context, index) =>
                                const SizedBox(height: 8),
                            itemCount: assets.length,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarAssetTile extends StatelessWidget {
  final FurnitureAsset asset;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;

  const _SidebarAssetTile({
    required this.asset,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.24)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? AppColors.primaryLight.withValues(alpha: 0.74)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.primary.withValues(alpha: 0.28)
                    : Colors.white.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(
                      Icons.view_in_ar_outlined,
                      color: Colors.white,
                      size: 19,
                    ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    asset.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.nunito(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    asset.displayCategory,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.nunito(
                      color: Colors.white60,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final bool hasSelectedObject;
  final bool canPlace;
  final double modelRotationDeg;
  final int xRotationDeg;
  final int yRotationDeg;
  final VoidCallback onPlace;
  final ValueChanged<double> onRotateDrag;
  final VoidCallback onRotateXQuarter;
  final VoidCallback onRotateYQuarter;
  final VoidCallback onRemove;

  const _BottomBar({
    required this.hasSelectedObject,
    required this.canPlace,
    required this.modelRotationDeg,
    required this.xRotationDeg,
    required this.yRotationDeg,
    required this.onPlace,
    required this.onRotateDrag,
    required this.onRotateXQuarter,
    required this.onRotateYQuarter,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    if (hasSelectedObject) {
      return Stack(
        alignment: Alignment.bottomCenter,
        children: [
          _RotationHandle(
            rotationDeg: modelRotationDeg,
            onDragDx: onRotateDrag,
          ),
          Positioned(
            bottom: bottomPad + 12,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ControlBtn(
                  icon: Icons.rotate_90_degrees_ccw_rounded,
                  label: 'X $xRotationDeg°',
                  onTap: onRotateXQuarter,
                ),
                const SizedBox(width: 8),
                _ControlBtn(
                  icon: Icons.rotate_90_degrees_cw_rounded,
                  label: 'Y $yRotationDeg°',
                  onTap: onRotateYQuarter,
                ),
                const SizedBox(width: 8),
                _ControlBtn(
                  icon: Icons.delete_outline_rounded,
                  label: '제거',
                  onTap: onRemove,
                ),
              ],
            ),
          ),
        ],
      );
    }

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
          colors: [Colors.black.withValues(alpha: 0.68), Colors.transparent],
        ),
      ),
      child: Center(
        child: _ControlBtn(
          icon: Icons.add_box_rounded,
          label: '이 위치에 배치하기',
          isWide: true,
          subtle: !canPlace,
          onTap: onPlace,
        ),
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
          horizontal: isWide ? 20 : 15,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: subtle
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.21),
          borderRadius: BorderRadius.circular(40),
          border: Border.all(
            color: Colors.white.withValues(alpha: subtle ? 0.15 : 0.32),
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
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RotationHandle extends StatelessWidget {
  final double rotationDeg;
  final ValueChanged<double> onDragDx;

  const _RotationHandle({required this.rotationDeg, required this.onDragDx});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = width / 2;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) => onDragDx(details.delta.dx),
      child: Container(
        width: double.infinity,
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.46),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(width / 2),
            topRight: Radius.circular(width / 2),
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.18),
            width: 1.5,
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _SemiCircleRulerPainter(rotationDeg: rotationDeg),
              ),
            ),
            Positioned(
              top: height * 0.12,
              left: 0,
              right: 0,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Z축 자유 회전',
                      style: GoogleFonts.nunito(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Colors.white.withValues(alpha: 0.64),
                      ),
                    ),
                    Text(
                      '${(rotationDeg > 180 ? rotationDeg - 360 : rotationDeg).round()}°',
                      style: GoogleFonts.nunito(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: Colors.white.withValues(alpha: 0.92),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SemiCircleRulerPainter extends CustomPainter {
  final double rotationDeg;

  _SemiCircleRulerPainter({required this.rotationDeg});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height;
    final radius = size.width / 2;

    for (var deg = 0; deg <= 180; deg += 5) {
      final alpha = deg * math.pi / 180;
      final px = cx - radius * math.cos(alpha);
      final py = cy - radius * math.sin(alpha);
      final nx = (cx - px) / radius;
      final ny = (cy - py) / radius;
      final isMajor = deg % 30 == 0;
      final isMid = deg % 10 == 0;
      final tickLen = isMajor
          ? 20.0
          : isMid
          ? 12.0
          : 6.0;
      final opacity = isMajor
          ? 0.65
          : isMid
          ? 0.38
          : 0.2;
      canvas.drawLine(
        Offset(px, py),
        Offset(px + nx * tickLen, py + ny * tickLen),
        Paint()
          ..color = Colors.white.withValues(alpha: opacity)
          ..strokeWidth = isMajor ? 1.8 : 1.0
          ..strokeCap = StrokeCap.round,
      );
    }

    final displayDeg = rotationDeg > 180 ? rotationDeg - 360 : rotationDeg;
    final arcDeg = (90.0 - displayDeg).clamp(0.0, 180.0);
    final indicatorAngle = arcDeg * math.pi / 180;
    final ipx = cx - radius * math.cos(indicatorAngle);
    final ipy = cy - radius * math.sin(indicatorAngle);

    canvas.drawCircle(
      Offset(ipx, ipy),
      7,
      Paint()
        ..color = AppColors.primary.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(
      Offset(ipx, ipy),
      4.5,
      Paint()..color = AppColors.primary.withValues(alpha: 0.95),
    );
  }

  @override
  bool shouldRepaint(_SemiCircleRulerPainter oldDelegate) =>
      oldDelegate.rotationDeg != rotationDeg;
}

class _SelectionRing extends StatefulWidget {
  const _SelectionRing();

  @override
  State<_SelectionRing> createState() => _SelectionRingState();
}

class _SelectionRingState extends State<_SelectionRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _pulse = Tween<double>(
      begin: 0.25,
      end: 0.7,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
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
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: size.width,
        height: size.height,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SelectionRingPainter oldDelegate) =>
      oldDelegate.opacity != opacity;
}

class _DragHintOverlay extends StatefulWidget {
  final VoidCallback onDismiss;

  const _DragHintOverlay({required this.onDismiss});

  @override
  State<_DragHintOverlay> createState() => _DragHintOverlayState();
}

class _DragHintOverlayState extends State<_DragHintOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _slide;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    _slide =
        TweenSequence<double>([
          TweenSequenceItem(
            tween: Tween<double>(
              begin: 0,
              end: 28,
            ).chain(CurveTween(curve: Curves.easeIn)),
            weight: 1,
          ),
          TweenSequenceItem(
            tween: Tween<double>(
              begin: 28,
              end: -28,
            ).chain(CurveTween(curve: Curves.easeInOut)),
            weight: 2,
          ),
          TweenSequenceItem(
            tween: Tween<double>(
              begin: -28,
              end: 0,
            ).chain(CurveTween(curve: Curves.easeOut)),
            weight: 1,
          ),
        ]).animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.0, 0.72),
          ),
        );
    _fade = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.72, 1.0, curve: Curves.easeOut),
      ),
    );
    _controller.forward().then((_) {
      if (mounted) widget.onDismiss();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => FadeTransition(
        opacity: _fade,
        child: Align(
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.58),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.translate(
                  offset: Offset(_slide.value, 0),
                  child: const Icon(
                    Icons.swipe_rounded,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '모델을 누른 뒤 드래그해서 이동',
                  style: GoogleFonts.nunito(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

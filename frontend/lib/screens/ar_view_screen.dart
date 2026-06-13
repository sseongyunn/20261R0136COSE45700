import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  static const _globalLightPrefix = 'room_light_';
  static const _shadowSuffix = '__contact_shadow';

  // Room-light tracking. ARKit's ambientIntensity is ~1000 lm in a well-lit
  // room. The wide clamp (especially the low floor) plus a >1 response
  // exponent make dark rooms render clearly dark instead of hovering near
  // "normal", and bright rooms brighten past neutral.
  static const _lightEstimateMin = 40.0;
  static const _lightEstimateMax = 2200.0;
  static const _lightResponseExponent = 1.35;
  static const _lightSmoothing = 0.3;
  // GLB materials load as SceneKit physically-based, which IGNORES ambient
  // lights — the rigs must be built from directional lights only.
  static const _keyLightShare = 0.85;
  static const _fillLightShare = 0.42;
  static const _bounceLightShare = 0.18;

  // Per-position light sampling. Each placed object's spot is sampled from
  // the raw camera image (center + ring around the footprint); the local
  // luminance is divided by the frame average so the factor is independent of
  // camera auto-exposure and of where the phone happens to point.
  static const _defaultLightCategory = 1; // SceneKit default node category.
  static const _localSampleRingCount = 8;
  static const _localRatioMin = 0.25;
  static const _localRatioMax = 1.9;
  // <1 softens the dark/bright spread to limit damage when a dark *surface*
  // (rather than a dark spot) is mistaken for shade.
  static const _localResponseExponent = 0.8;
  static const _localFactorSmoothing = 0.35;
  static const _yawSnapStep = math.pi / 12; // 15° detents
  static const _yawSnapWindow = math.pi / 45; // ±4° sticky zone
  // Soft "upright" assist window. Lean is otherwise completely free (any
  // direction, any angle) so models authored lying down can be stood up.
  static const _uprightWindow = 5 * math.pi / 180; // ±5° upright assist

  ARKitController? _arkitController;
  Timer? _raycastTimer;
  Timer? _lightTimer;
  Timer? _statusClearTimer;

  final Set<String> _planeAnchorIds = {};
  final Map<String, _PreparedModel> _preparedModels = {};
  final Map<String, _PlacedModel> _placedModels = {};

  bool _lightRigReady = false;
  double _ambientIntensity = 1000;
  double _ambientTemperature = 6500;
  bool _lightEstimateActive = false;
  // Last values pushed over the platform channel, used to skip no-op updates.
  double? _appliedLightIntensity;
  double? _appliedLightTemperature;
  // Light-category bits currently assigned to placed models.
  final Set<int> _usedLightBits = {};

  int? _yawDetentForHaptic;
  bool _tiltSnappedForHaptic = false;

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

  AssetRenderProfile? get _activeRenderProfile =>
      _selectedModel?.asset.renderProfile ?? _activeAsset?.renderProfile;

  _PlacedModel? get _selectedModel {
    final nodeName = _selectedNodeName;
    if (nodeName == null) return null;
    return _placedModels[nodeName];
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
        renderProfile: null,
      );
      _activeAsset = asset;
      _prepareAsset(asset);
    }
  }

  @override
  void dispose() {
    _raycastTimer?.cancel();
    _lightTimer?.cancel();
    _statusClearTimer?.cancel();
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
      final api = context.read<ApiClient>();
      final url = await api.getModelUrl(asset.assetId);
      var renderProfile = asset.renderProfile;
      if (renderProfile == null) {
        try {
          renderProfile = await api.getAssetRenderProfile(asset.assetId);
        } catch (e) {
          debugPrint('[AR] render profile fetch skipped: $e');
        }
      }
      final arAsset = _ArAsset(
        id: asset.assetId,
        name: asset.displayName,
        category: asset.displayCategory,
        dimensions: asset.dimensions,
        modelUrl: url,
        renderProfile: renderProfile,
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

      final renderFileName = 'ar_render_${asset.id.hashCode.abs()}.glb';
      final renderFile = File('${dir.path}/$renderFileName');
      await _writeRenderableGlb(
        sourceFile: file,
        targetFile: renderFile,
        profile: asset.renderProfile,
      );

      final previewValidFileName =
          'ar_preview_gray_${asset.id.hashCode.abs()}.glb';
      final previewInvalidFileName =
          'ar_preview_red_${asset.id.hashCode.abs()}.glb';
      await _writePreviewGlb(
        sourceFile: renderFile,
        targetFile: File('${dir.path}/$previewValidFileName'),
        rgba: const [0.62, 0.62, 0.62, 0.34],
      );
      await _writePreviewGlb(
        sourceFile: renderFile,
        targetFile: File('${dir.path}/$previewInvalidFileName'),
        rgba: const [1.0, 0.12, 0.08, 0.42],
      );

      final calibration = await _inspectModelFile(renderFile, asset.dimensions);
      if (!mounted) return;
      setState(() {
        _preparedModels[asset.id] = _PreparedModel(
          asset: asset,
          localGlbPath: renderFileName,
          previewValidGlbPath: previewValidFileName,
          previewInvalidGlbPath: previewInvalidFileName,
          scale: calibration.scale,
          baseRotation: calibration.baseRotation,
          bounds: calibration.bounds,
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

  /// Bakes a one-time color normalization into the GLB and clamps material
  /// properties so the model responds correctly to the estimate-driven light
  /// rig:
  /// - baseColor is normalized toward the input photo's color baseline;
  /// - emissive is capped near zero (emissive glows regardless of room light,
  ///   which would break the dark-room response);
  /// - metallic is capped and roughness floored because without image-based
  ///   lighting highly metallic surfaces render nearly black.
  Future<void> _writeRenderableGlb({
    required File sourceFile,
    required File targetFile,
    required AssetRenderProfile? profile,
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
    final materials = (gltf['materials'] as List<dynamic>?) ?? <dynamic>[];
    if (materials.isEmpty) {
      materials.add(<String, dynamic>{});
      gltf['materials'] = materials;
      _assignDefaultMaterialToPrimitives(gltf);
    }

    final tint = profile == null
        ? const [1.0, 1.0, 1.0]
        : _profileTint(profile);
    final exposure = profile == null ? 1.0 : _profileTextureExposure(profile);

    for (var i = 0; i < materials.length; i += 1) {
      final material = Map<String, dynamic>.from(
        (materials[i] as Map?) ?? const <String, dynamic>{},
      );
      final pbr = Map<String, dynamic>.from(
        (material['pbrMetallicRoughness'] as Map?) ?? const <String, dynamic>{},
      );
      final base = _baseColorFactor(pbr['baseColorFactor']);
      final adjustedBase = <double>[
        (base[0] * exposure * tint[0]).clamp(0.0, 1.0).toDouble(),
        (base[1] * exposure * tint[1]).clamp(0.0, 1.0).toDouble(),
        (base[2] * exposure * tint[2]).clamp(0.0, 1.0).toDouble(),
        base[3].clamp(0.0, 1.0).toDouble(),
      ];
      pbr['baseColorFactor'] = adjustedBase;

      // glTF defaults metallicFactor to 1.0 when missing; without IBL that
      // renders nearly black under directional lights, so cap it low.
      final metallic =
          (pbr['metallicFactor'] as num?)?.toDouble() ??
          (profile?.metallicMean ?? 0.0);
      pbr['metallicFactor'] = metallic.clamp(0.0, 0.25).toDouble();
      final roughness =
          (pbr['roughnessFactor'] as num?)?.toDouble() ??
          (profile?.roughnessMean ?? 0.82);
      pbr['roughnessFactor'] = roughness.clamp(0.4, 1.0).toDouble();

      material['pbrMetallicRoughness'] = pbr;
      material['doubleSided'] = material['doubleSided'] ?? true;

      // Emissive is light-independent and would keep the object glowing in a
      // dark room; allow at most a trace of it.
      final emissive = _rgbFactor(material['emissiveFactor']);
      if (emissive.any((channel) => channel > 0.04)) {
        material['emissiveFactor'] = <double>[
          emissive[0].clamp(0.0, 0.04).toDouble(),
          emissive[1].clamp(0.0, 0.04).toDouble(),
          emissive[2].clamp(0.0, 0.04).toDouble(),
        ];
      }

      materials[i] = material;
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

  void _assignDefaultMaterialToPrimitives(Map<String, dynamic> gltf) {
    final meshes = gltf['meshes'] as List<dynamic>?;
    if (meshes == null) return;
    for (final mesh in meshes) {
      final primitives =
          (mesh as Map<String, dynamic>)['primitives'] as List<dynamic>?;
      if (primitives == null) continue;
      for (final primitive in primitives) {
        (primitive as Map<String, dynamic>)['material'] = 0;
      }
    }
  }

  List<double> _baseColorFactor(Object? raw) {
    if (raw is List && raw.length >= 4) {
      return [
        (raw[0] as num?)?.toDouble() ?? 1.0,
        (raw[1] as num?)?.toDouble() ?? 1.0,
        (raw[2] as num?)?.toDouble() ?? 1.0,
        (raw[3] as num?)?.toDouble() ?? 1.0,
      ];
    }
    return const [1.0, 1.0, 1.0, 1.0];
  }

  List<double> _rgbFactor(Object? raw) {
    if (raw is List && raw.length >= 3) {
      return [
        (raw[0] as num?)?.toDouble() ?? 0.0,
        (raw[1] as num?)?.toDouble() ?? 0.0,
        (raw[2] as num?)?.toDouble() ?? 0.0,
      ];
    }
    return const [0.0, 0.0, 0.0];
  }

  /// One-time tint that nudges the generated texture back toward the input
  /// photo's color baseline. Room warmth is intentionally NOT baked in here —
  /// it comes from the live light rig's color temperature so it can change
  /// with the room.
  List<double> _profileTint(AssetRenderProfile profile) {
    final input = profile.inputColorProfile;
    final targetR = input?.targetMeanR;
    final targetG = input?.targetMeanG;
    final targetB = input?.targetMeanB;
    final modelR = profile.albedoMeanR;
    final modelG = profile.albedoMeanG;
    final modelB = profile.albedoMeanB;
    if (targetR != null &&
        targetG != null &&
        targetB != null &&
        modelR != null &&
        modelG != null &&
        modelB != null) {
      double channel(double target, double model) {
        final ratio = (target.clamp(0.02, 1.0) / model.clamp(0.02, 1.0))
            .clamp(0.45, 2.3)
            .toDouble();
        return math.pow(ratio, 0.55).clamp(0.72, 1.38).toDouble();
      }

      return [
        channel(targetR, modelR),
        channel(targetG, modelG),
        channel(targetB, modelB),
      ];
    }

    final r = targetR ?? profile.albedoMeanR;
    final g = targetG ?? profile.albedoMeanG;
    final b = targetB ?? profile.albedoMeanB;
    if (r == null || g == null || b == null) {
      return const [1.0, 1.0, 1.0];
    }

    final mean = ((r + g + b) / 3).clamp(0.001, 1.0).toDouble();
    double channel(double value) {
      final albedoBias = 1 + ((value / mean) - 1) * 0.08;
      return albedoBias.clamp(0.9, 1.1).toDouble();
    }

    return [channel(r), channel(g), channel(b)];
  }

  double _profileTextureExposure(AssetRenderProfile profile) {
    final input = profile.inputColorProfile;
    final targetLuma =
        input?.processedLuminanceMean ??
        input?.targetLuminance ??
        input?.originalLuminanceMean ??
        0.56;
    final modelLuma = profile.textureLuminanceMean;
    final textureGain = modelLuma == null || modelLuma <= 0.03
        ? 1.0
        : (targetLuma / modelLuma).clamp(0.65, 2.05).toDouble();
    final preprocessGain = 1 + ((input?.exposureGain ?? 1.0) - 1) * 0.42;
    final baselineGain = math.max(
      profile.suggestedExposureGain,
      math.max(textureGain, preprocessGain),
    );
    return baselineGain.clamp(0.76, 1.95).toDouble();
  }

  int _paddedLength(int length) => (length + 3) & ~3;

  Future<_ModelCalibration> _inspectModelFile(
    File file,
    String? dimensions,
  ) async {
    var scale = 0.3;
    var baseRotation = vector.Vector3.zero();
    _ModelBounds? bounds;
    final physicalMaxDim = _parsePhysicalMaxDimension(dimensions);

    try {
      final bytes = await file.readAsBytes();
      final data = ByteData.view(
        bytes.buffer,
        bytes.offsetInBytes,
        bytes.length,
      );
      if (data.lengthInBytes < 20) {
        return _ModelCalibration(
          scale: scale,
          baseRotation: baseRotation,
          bounds: bounds,
        );
      }

      final magic = data.getUint32(0, Endian.little);
      if (magic != 0x46546C67) {
        return _ModelCalibration(
          scale: scale,
          baseRotation: baseRotation,
          bounds: bounds,
        );
      }

      final chunk0Length = data.getUint32(12, Endian.little);
      final chunk0Type = data.getUint32(16, Endian.little);
      if (chunk0Type != 0x4E4F534A) {
        return _ModelCalibration(
          scale: scale,
          baseRotation: baseRotation,
          bounds: bounds,
        );
      }

      final jsonBytes = bytes.sublist(20, 20 + chunk0Length);
      final gltf = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;

      final accessors = gltf['accessors'] as List<dynamic>?;
      final meshes = gltf['meshes'] as List<dynamic>?;
      var maxModelLength = 0.0;
      vector.Vector3? boundsMin;
      vector.Vector3? boundsMax;

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
            final localMin = vector.Vector3(
              (minArr[0] as num).toDouble(),
              (minArr[1] as num).toDouble(),
              (minArr[2] as num).toDouble(),
            );
            final localMax = vector.Vector3(
              (maxArr[0] as num).toDouble(),
              (maxArr[1] as num).toDouble(),
              (maxArr[2] as num).toDouble(),
            );
            boundsMin = boundsMin == null
                ? localMin
                : vector.Vector3(
                    math.min(boundsMin.x, localMin.x),
                    math.min(boundsMin.y, localMin.y),
                    math.min(boundsMin.z, localMin.z),
                  );
            boundsMax = boundsMax == null
                ? localMax
                : vector.Vector3(
                    math.max(boundsMax.x, localMax.x),
                    math.max(boundsMax.y, localMax.y),
                    math.max(boundsMax.z, localMax.z),
                  );
            maxModelLength = math.max(
              maxModelLength,
              [dx, dy, dz].reduce(math.max),
            );
          }
        }
      }

      if (boundsMin != null && boundsMax != null) {
        bounds = _ModelBounds(min: boundsMin, max: boundsMax);
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

    return _ModelCalibration(
      scale: scale,
      baseRotation: baseRotation,
      bounds: bounds,
    );
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
    controller.addCoachingOverlay(CoachingOverlayGoal.horizontalPlane);
    controller.onAddNodeForAnchor = _onAnchorAdded;
    controller.onUpdateNodeForAnchor = _onAnchorUpdated;
    controller.onDidRemoveNodeForAnchor = _onAnchorRemoved;
    _raycastTimer = Timer.periodic(
      const Duration(milliseconds: 120),
      (_) => _performRaycast(),
    );
    _setupLightRig();
    _lightTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _syncLightingWithRoom(),
    );
  }

  /// The placed GLBs use SceneKit's physically-based lighting model, which
  /// ignores ambient lights entirely — so every rig is three *directional*
  /// lights: a key light from above-front, a softer fill from the opposite
  /// side, and a faint floor bounce from below.
  ///
  /// Lighting is two-layered:
  /// - a *global* rig (category 1) lights the placement preview and any
  ///   non-categorized content, following ARKit's room-wide estimate;
  /// - each placed object gets its *own* rig scoped via categoryBitMask, with
  ///   intensity = global estimate x that object's local light factor sampled
  ///   from the camera image at its position. An object under a table is lit
  ///   darker than one standing in a bright patch.
  List<({String id, double share, vector.Vector3 euler})> get _rigSpecs => [
    (
      id: 'key',
      share: _keyLightShare,
      euler: vector.Vector3(-1.05, -0.45, 0),
    ),
    (
      id: 'fill',
      share: _fillLightShare,
      euler: vector.Vector3(-0.85, 2.35, 0),
    ),
    (
      id: 'bounce',
      share: _bounceLightShare,
      euler: vector.Vector3(1.15, 0.55, 0),
    ),
  ];

  ARKitNode _rigLightNode({
    required String name,
    required ({String id, double share, vector.Vector3 euler}) spec,
    required double intensity,
    required int category,
  }) => ARKitNode(
    name: name,
    light: ARKitLight(
      type: ARKitLightType.directional,
      temperature: _ambientTemperature,
      intensity: intensity * spec.share,
      categoryBitMask: category,
    ),
    eulerAngles: spec.euler,
  );

  Future<void> _setupLightRig() async {
    final controller = _arkitController;
    if (controller == null || _lightRigReady) return;
    try {
      for (final spec in _rigSpecs) {
        await controller.add(
          _rigLightNode(
            name: '$_globalLightPrefix${spec.id}',
            spec: spec,
            intensity: _effectiveLightIntensity(),
            category: _defaultLightCategory,
          ),
        );
      }
      _lightRigReady = true;
    } catch (e) {
      debugPrint('[AR] light rig setup failed: $e');
    }
  }

  /// Maps the smoothed estimate to the rig intensity. The exponent stretches
  /// the perceived range: lights-off drives the object visibly dark while a
  /// bright room pushes it past neutral.
  double _effectiveLightIntensity() {
    final normalized = (_ambientIntensity / 1000.0).clamp(0.0, 3.0);
    return 1000.0 *
        math.pow(normalized, _lightResponseExponent).toDouble();
  }

  Future<void> _syncLightingWithRoom() async {
    final controller = _arkitController;
    if (controller == null) return;
    final estimate = await controller.getLightEstimate();
    if (estimate == null || !mounted) return;

    final targetIntensity = estimate.ambientIntensity.clamp(
      _lightEstimateMin,
      _lightEstimateMax,
    );
    final targetTemperature = estimate.ambientColorTemperature.clamp(
      3000.0,
      8000.0,
    );

    // Ease toward the estimate so lighting transitions smoothly instead of
    // flickering frame to frame.
    _ambientIntensity += (targetIntensity - _ambientIntensity) * _lightSmoothing;
    _ambientTemperature +=
        (targetTemperature - _ambientTemperature) * _lightSmoothing;

    if (!_lightRigReady) return;

    final effective = _effectiveLightIntensity();
    final intensityDelta = _appliedLightIntensity == null
        ? double.infinity
        : (effective - _appliedLightIntensity!).abs();
    final temperatureDelta = _appliedLightTemperature == null
        ? double.infinity
        : (_ambientTemperature - _appliedLightTemperature!).abs();
    // Skip global-rig updates when the change is imperceptible.
    final globalChanged =
        intensityDelta >= math.max(6.0, effective * 0.015) ||
        temperatureDelta >= 30;

    if (globalChanged) {
      try {
        for (final spec in _rigSpecs) {
          await controller.update(
            '$_globalLightPrefix${spec.id}',
            node: _rigLightNode(
              name: '$_globalLightPrefix${spec.id}',
              spec: spec,
              intensity: effective,
              category: _defaultLightCategory,
            ),
          );
        }
        _appliedLightIntensity = effective;
        _appliedLightTemperature = _ambientTemperature;
      } catch (e) {
        debugPrint('[AR] light rig update failed: $e');
      }
    }

    await _updateLocalLightFactors(controller);
    await _syncModelRigs(force: globalChanged);
    await _syncShadowsWithLight();

    if (!_lightEstimateActive && mounted) {
      setState(() => _lightEstimateActive = true);
    }
  }

  /// Estimates each placed object's local light by sampling the *raw camera
  /// image* (virtual content excluded, so our own renders can't feed back) at
  /// the object's center plus a ring around its footprint. Dividing the local
  /// luminance by the frame average cancels camera auto-exposure and keeps
  /// the factor stable while the phone moves. Off-screen objects keep their
  /// last factor.
  Future<void> _updateLocalLightFactors(ARKitController controller) async {
    if (_placedModels.isEmpty) return;
    final models = _placedModels.values.toList();
    final points = <double>[];
    for (final model in models) {
      final half = _footprintHalfExtents(model);
      final radius = (math.max(half.x, half.z) * 1.7 + 0.06)
          .clamp(0.15, 0.9)
          .toDouble();
      final ground = model.groundPosition;
      points
        ..add(ground.x)
        ..add(ground.y + 0.01)
        ..add(ground.z);
      for (var i = 0; i < _localSampleRingCount; i += 1) {
        final angle = i * 2 * math.pi / _localSampleRingCount;
        points
          ..add(ground.x + radius * math.cos(angle))
          ..add(ground.y + 0.01)
          ..add(ground.z + radius * math.sin(angle));
      }
    }

    Map<String, dynamic>? response;
    try {
      response = await controller.sampleCameraLuminance(points);
    } catch (e) {
      debugPrint('[AR] camera luminance sampling failed: $e');
      return;
    }
    if (response == null) return;
    final samples = (response['samples'] as List?)?.cast<num>();
    final frameAverage = (response['frameAverage'] as num?)?.toDouble() ?? -1;
    if (samples == null || frameAverage <= 0.02) return;

    const perModel = 1 + _localSampleRingCount;
    for (var m = 0; m < models.length; m += 1) {
      final start = m * perModel;
      if (start + perModel > samples.length) break;
      final valid = <double>[
        for (var i = start; i < start + perModel; i += 1)
          if (samples[i] >= 0) samples[i].toDouble(),
      ];
      // Mostly off-screen: hold the previous factor so pointing the phone
      // away from an object doesn't change how it is lit.
      if (valid.length < 3) continue;
      valid.sort();
      // Trimmed mean rejects stray highlights/occluders in the ring.
      final drop = valid.length >= 5 ? (valid.length * 0.2).floor() : 0;
      final usable = valid.sublist(drop, valid.length - drop);
      final localLuma = usable.reduce((a, b) => a + b) / usable.length;
      final ratio = (localLuma / frameAverage)
          .clamp(_localRatioMin, _localRatioMax)
          .toDouble();
      final target = math.pow(ratio, _localResponseExponent).toDouble();

      final model = models[m];
      if (!model.localFactorSeeded) {
        model.localLightFactor = target;
        model.localFactorSeeded = true;
      } else {
        model.localLightFactor +=
            (target - model.localLightFactor) * _localFactorSmoothing;
      }
    }
  }

  int _allocateLightBit() {
    for (var bit = 2; bit <= 30; bit += 1) {
      if (!_usedLightBits.contains(bit)) {
        _usedLightBits.add(bit);
        return bit;
      }
    }
    // More than 29 concurrent objects: share a bit (lighting still works,
    // those objects just share one local factor's rig).
    return 2;
  }

  String _modelLightName(_PlacedModel model, String specId) =>
      '${model.nodeName}__light_$specId';

  Future<void> _addModelRig(_PlacedModel model) async {
    final controller = _arkitController;
    if (controller == null) return;
    final intensity = _effectiveLightIntensity() * model.localLightFactor;
    try {
      for (final spec in _rigSpecs) {
        await controller.add(
          _rigLightNode(
            name: _modelLightName(model, spec.id),
            spec: spec,
            intensity: intensity,
            category: model.lightCategory,
          ),
        );
      }
      model.appliedRigIntensity = intensity;
      model.appliedRigTemperature = _ambientTemperature;
    } catch (e) {
      debugPrint('[AR] model light rig add failed: $e');
    }
  }

  Future<void> _syncModelRigs({required bool force}) async {
    for (final model in _placedModels.values) {
      await _syncModelRig(model, force: force);
    }
  }

  Future<void> _syncModelRig(_PlacedModel model, {bool force = false}) async {
    final controller = _arkitController;
    if (controller == null) return;
    final intensity = _effectiveLightIntensity() * model.localLightFactor;
    final applied = model.appliedRigIntensity;
    if (!force &&
        applied != null &&
        (intensity - applied).abs() < math.max(6.0, intensity * 0.015)) {
      return;
    }
    try {
      for (final spec in _rigSpecs) {
        await controller.update(
          _modelLightName(model, spec.id),
          node: _rigLightNode(
            name: _modelLightName(model, spec.id),
            spec: spec,
            intensity: intensity,
            category: model.lightCategory,
          ),
        );
      }
      model.appliedRigIntensity = intensity;
      model.appliedRigTemperature = _ambientTemperature;
    } catch (e) {
      debugPrint('[AR] model light rig update failed: $e');
    }
  }

  Future<void> _removeModelRig(_PlacedModel model) async {
    final controller = _arkitController;
    _usedLightBits.remove(model.lightBit);
    if (controller == null) return;
    for (final spec in _rigSpecs) {
      try {
        await controller.remove(_modelLightName(model, spec.id));
      } catch (e) {
        debugPrint('[AR] model light rig remove failed: $e');
      }
    }
  }

  /// Contact shadows track the light at the object's own spot: strong light
  /// means a crisp dark disc, shade or a dark room fades it out.
  double _shadowAlphaFor(_PlacedModel model) {
    final normalized =
        (_effectiveLightIntensity() * model.localLightFactor / 1000.0)
            .clamp(0.0, 1.0);
    return (0.10 + 0.26 * normalized).clamp(0.10, 0.36).toDouble();
  }

  Future<void> _syncShadowsWithLight() async {
    for (final model in _placedModels.values) {
      final alpha = _shadowAlphaFor(model);
      if (model.appliedShadowAlpha != null &&
          (alpha - model.appliedShadowAlpha!).abs() < 0.02) {
        continue;
      }
      model.appliedShadowAlpha = alpha;
      await _syncShadow(model);
    }
  }

  /// World-space half extents (x, z) of the model footprint at its current
  /// orientation, used to size the contact shadow under it.
  ({double x, double z}) _footprintHalfExtents(_PlacedModel model) {
    final bounds = model.bounds ?? _fallbackBounds(model.previewSize);
    final orientation = _orientationMatrixForModel(model);
    var minX = double.infinity, maxX = double.negativeInfinity;
    var minZ = double.infinity, maxZ = double.negativeInfinity;
    for (final corner in bounds.corners) {
      final transformed = orientation.transform3(
        vector.Vector3(
          corner.x * model.scale,
          corner.y * model.scale,
          corner.z * model.scale,
        ),
      );
      minX = math.min(minX, transformed.x);
      maxX = math.max(maxX, transformed.x);
      minZ = math.min(minZ, transformed.z);
      maxZ = math.max(maxZ, transformed.z);
    }
    if (!minX.isFinite || !minZ.isFinite) {
      return (x: model.previewSize.width / 2, z: model.previewSize.depth / 2);
    }
    return (x: (maxX - minX) / 2, z: (maxZ - minZ) / 2);
  }

  String _shadowNodeName(_PlacedModel model) =>
      '${model.nodeName}$_shadowSuffix';

  /// A flat, dark, translucent ellipse sized to the model's footprint. Using a
  /// solid color (rather than a texture) keeps it reliable across devices while
  /// still anchoring the object visually to the floor.
  ARKitNode _shadowNodeFor(_PlacedModel model) {
    final half = _footprintHalfExtents(model);
    final radiusX = (half.x * 1.3).clamp(0.05, 2.5).toDouble();
    final radiusZ = (half.z * 1.3).clamp(0.05, 2.5).toDouble();
    final material = ARKitMaterial(
      diffuse: ARKitMaterialProperty.color(Colors.black),
      lightingModelName: ARKitLightingModel.constant,
      blendMode: ARKitBlendMode.alpha,
      transparency: _shadowAlphaFor(model),
      writesToDepthBuffer: false,
      doubleSided: true,
    );
    // A thin cylinder lies flat in the XZ plane; scale it into an ellipse that
    // matches the footprint, and lift it a hair to avoid z-fighting.
    return ARKitNode(
      name: _shadowNodeName(model),
      geometry: ARKitCylinder(
        radius: 1.0,
        height: 0.002,
        materials: [material],
      ),
      scale: vector.Vector3(radiusX, 1, radiusZ),
      position: model.groundPosition + vector.Vector3(0, 0.003, 0),
      renderingOrder: -10,
    );
  }

  Future<void> _addShadow(_PlacedModel model) async {
    final controller = _arkitController;
    if (controller == null) return;
    try {
      await controller.add(_shadowNodeFor(model));
    } catch (e) {
      debugPrint('[AR] shadow add failed: $e');
    }
  }

  Future<void> _syncShadow(_PlacedModel model) async {
    final controller = _arkitController;
    if (controller == null) return;
    try {
      await controller.update(
        _shadowNodeName(model),
        node: _shadowNodeFor(model),
      );
    } catch (_) {
      await _addShadow(model);
    }
  }

  Future<void> _removeShadow(_PlacedModel model) async {
    await _arkitController?.remove(_shadowNodeName(model));
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
    _syncHapticTrackers(model);
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
    _syncHapticTrackers(model);
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

    _setModelGroundPosition(model, hit);
    await _syncPlacedModelTransform(model);
  }

  void _handleScenePanEnd() {
    if (_draggingNodeName == null) return;
    setState(() => _draggingNodeName = null);
    _showStatus('이 위치로 옮겼어요.');
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

    final hit = await _hitTestNormalized(0.5, 0.5, strictPlane: true);
    final featureHit = await _hitTestNormalized(0.5, 0.5, strictPlane: false);
    final hover = hit ?? featureHit ?? await _cameraForwardPreviewPosition();

    if (!mounted) return;

    setState(() {
      _reticlePosition = hit;
      _previewPosition = hover;
      _placementEligible = hit != null;
    });
    await _updatePreviewNode();
  }

  Future<vector.Vector3?> _hitTestNormalized(double x, double y, {bool strictPlane = true}) async {
    final controller = _arkitController;
    if (controller == null) return null;
    final hits = await controller.performHitTest(x: x, y: y);
    final bestHit = hits.firstWhereOrNull(
      (hit) {
        if (strictPlane) {
          return hit.type == ARKitHitTestResultType.existingPlaneUsingExtent ||
                 hit.type == ARKitHitTestResultType.existingPlaneUsingGeometry;
        } else {
          return (hit.type == ARKitHitTestResultType.existingPlaneUsingExtent ||
                  hit.type == ARKitHitTestResultType.existingPlaneUsingGeometry ||
                  hit.type == ARKitHitTestResultType.estimatedHorizontalPlane ||
                  hit.type == ARKitHitTestResultType.estimatedVerticalPlane ||
                  hit.type == ARKitHitTestResultType.featurePoint) &&
                 hit.distance >= 0.3;
        }
      },
    );
    if (bestHit == null) return null;
    final translation = bestHit.worldTransform.getColumn(3);
    return vector.Vector3(translation.x, translation.y, translation.z);
  }

  Future<vector.Vector3?> _hitTestScreenPoint(Offset point) {
    final size = MediaQuery.sizeOf(context);
    return _hitTestNormalized(
      (point.dx / size.width).clamp(0.02, 0.98).toDouble(),
      (point.dy / size.height).clamp(0.02, 0.98).toDouble(),
      strictPlane: true,
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

    // Lift the preview so its base rests on the surface, matching how the model
    // will sit once placed (instead of sinking halfway into the floor).
    final lift = _verticalLift(
      prepared.bounds,
      prepared.previewSize,
      prepared.scale,
      _baseRotationMatrix(prepared.baseRotation),
    );
    final liftedPosition = position + vector.Vector3(0, lift, 0);

    if (_previewNodeAdded &&
        _previewIsInvalid == invalid &&
        _previewGlbPath == previewPath) {
      final node = ARKitGltfNode(
        name: _previewNodeName,
        assetType: AssetType.documents,
        url: previewPath,
        scale: vector.Vector3.all(prepared.scale),
        position: liftedPosition,
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
      position: liftedPosition,
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
      bounds: prepared.bounds,
      previewSize: prepared.previewSize,
      groundPosition: position,
      lightBit: _allocateLightBit(),
    );
    _setModelGroundPosition(model, position);

    await _addPlacedModel(model);
    await _addModelRig(model);
    if (!mounted) return;
    _yawDetentForHaptic = 0;
    _tiltSnappedForHaptic = true;
    setState(() {
      _placedModels[nodeName] = model;
      _selectedNodeName = nodeName;
      _showDragHint = true;
    });
    _showStatus('${active.name} 배치됨 · 실측 크기로 표시 중');
    HapticFeedback.mediumImpact();
  }

  void _setModelGroundPosition(_PlacedModel model, vector.Vector3 ground) {
    model.groundPosition = ground;
    model.position =
        ground + vector.Vector3(0, _verticalLiftForModel(model), 0);
  }

  double _verticalLiftForModel(_PlacedModel model) => _verticalLift(
    model.bounds,
    model.previewSize,
    model.scale,
    _orientationMatrixForModel(model),
  );

  /// How far to raise a model so its lowest point rests exactly on the ground
  /// given its current orientation.
  double _verticalLift(
    _ModelBounds? rawBounds,
    _PreviewSize size,
    double scale,
    vector.Matrix4 orientation,
  ) {
    final bounds = rawBounds ?? _fallbackBounds(size);

    var minY = double.infinity;
    for (final corner in bounds.corners) {
      final scaledCorner = vector.Vector3(
        corner.x * scale,
        corner.y * scale,
        corner.z * scale,
      );
      final transformed = orientation.transform3(scaledCorner);
      minY = math.min(minY, transformed.y);
    }

    if (!minY.isFinite) return 0;
    return math.max(0, -minY);
  }

  _ModelBounds _fallbackBounds(_PreviewSize size) {
    return _ModelBounds(
      min: vector.Vector3(-size.width / 2, 0, -size.depth / 2),
      max: vector.Vector3(size.width / 2, size.height, size.depth / 2),
    );
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
        categoryBitMask: model.lightCategory,
      );
      await controller.add(fallback);
    }
    await _addShadow(model);
  }

  Future<void> _rebuildPlacedModel(_PlacedModel model) async {
    final controller = _arkitController;
    if (controller == null) return;
    await controller.remove(model.nodeName);
    await _removeShadow(model);
    await _addPlacedModel(model);
    if (mounted) setState(() {});
  }

  ARKitGltfNode _gltfNodeFor(_PlacedModel model) {
    final node = ARKitGltfNode(
      assetType: AssetType.documents,
      url: model.localGlbPath,
      name: model.nodeName,
      // Scopes the model to its private light rig (see _addModelRig).
      categoryBitMask: model.lightCategory,
    );
    node.transform = _transformForModel(model);
    return node;
  }

  vector.Matrix4 _transformForModel(_PlacedModel model) {
    return _orientationMatrixForModel(model)
      ..scaleByVector3(vector.Vector3.all(model.scale))
      ..setTranslation(model.position);
  }

  vector.Matrix4 _orientationMatrixForModel(_PlacedModel model) {
    return _userRotationMatrix(
      model,
    ).multiplied(_baseRotationMatrix(model.baseRotation));
  }

  /// Heading (yaw, about world up) combined with a free-form lean. The lean is
  /// applied in world space on top of the heading, so it can tip the object to
  /// any angle in any direction (full rotational freedom).
  vector.Matrix4 _userRotationMatrix(_PlacedModel model) {
    final yaw = vector.Matrix4.identity()..rotateY(model.userYaw);
    return model.leanRotation.multiplied(yaw);
  }

  /// Among the model's six axis directions, finds the one currently pointing
  /// most upward (in world space) and the angle between it and vertical.
  /// Rotating that axis to vertical is the minimal correction that makes the
  /// object rest flat on the floor, regardless of how the model was authored.
  ({vector.Vector3 worldDir, double tilt}) _nearestUprightAxis(
    _PlacedModel model,
  ) {
    final s = _orientationMatrixForModel(model).storage;
    var best = vector.Vector3(0, 1, 0);
    var bestUp = -2.0;
    for (final local in const [
      [1.0, 0.0, 0.0],
      [-1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
      [0.0, -1.0, 0.0],
      [0.0, 0.0, 1.0],
      [0.0, 0.0, -1.0],
    ]) {
      // Rotation-only transform of the local axis into world space.
      final w = vector.Vector3(
        s[0] * local[0] + s[4] * local[1] + s[8] * local[2],
        s[1] * local[0] + s[5] * local[1] + s[9] * local[2],
        s[2] * local[0] + s[6] * local[1] + s[10] * local[2],
      );
      if (w.y > bestUp) {
        bestUp = w.y;
        best = w;
      }
    }
    return (worldDir: best, tilt: math.acos(bestUp.clamp(-1.0, 1.0)));
  }

  /// How far the object is tipped from resting flat on the ground (radians).
  double _groundTilt(_PlacedModel model) => _nearestUprightAxis(model).tilt;

  bool _isAlignedToGround(_PlacedModel model) =>
      _groundTilt(model) < _uprightWindow;

  int _groundTiltDegrees(_PlacedModel model) =>
      (_groundTilt(model) * 180 / math.pi).round();

  /// Horizontal axis (in world space) perpendicular to the viewer's line of
  /// sight, used so a vertical drag tips the object toward/away from the user.
  /// Walking around the object lets the user lean it in any direction.
  Future<vector.Vector3> _cameraHorizontalRightAxis() async {
    final camera = await _arkitController?.pointOfViewTransform();
    if (camera == null) return vector.Vector3(1, 0, 0);
    final column = camera.getColumn(0);
    final axis = vector.Vector3(column.x, 0, column.z);
    if (axis.length2 < 0.0001) return vector.Vector3(1, 0, 0);
    axis.normalize();
    return axis;
  }

  vector.Matrix4 _baseRotationMatrix(vector.Vector3 eulerAngles) {
    return vector.Matrix4.identity()
      ..rotateX(eulerAngles.x)
      ..rotateY(eulerAngles.y)
      ..rotateZ(eulerAngles.z);
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
    await _syncShadow(model);
    if (mounted) setState(() {});
  }

  Future<void> _rotateSelectedFromWheel(Offset delta) async {
    final selected = _selectedModel;
    if (selected == null) return;

    // Horizontal drag spins the object (yaw, with 15° detents); vertical drag
    // tips it over with no limit, about a camera-relative horizontal axis.
    selected.rawYaw -= delta.dx * 0.011;
    _applyYawSnapping(selected, haptics: true);

    final leanDelta = -delta.dy * 0.0085;
    if (leanDelta != 0) {
      final axis = await _cameraHorizontalRightAxis();
      final increment = vector.Matrix4.identity()..rotate(axis, leanDelta);
      selected.leanRotation = increment.multiplied(selected.leanRotation);
      _handleUprightHaptic(selected);
    }

    _setModelGroundPosition(selected, selected.groundPosition);
    await _syncPlacedModelTransform(selected);
  }

  /// Snaps the heading to the nearest 15° detent when close, for a "magnetic"
  /// feel, while leaving the full range reachable.
  void _applyYawSnapping(_PlacedModel model, {required bool haptics}) {
    final nearestDetent = (model.rawYaw / _yawSnapStep).round();
    final snappedYawTarget = nearestDetent * _yawSnapStep;
    final yawSnapped = (model.rawYaw - snappedYawTarget).abs() < _yawSnapWindow;
    model.userYaw = yawSnapped ? snappedYawTarget : model.rawYaw;

    if (!haptics) return;
    if (yawSnapped && _yawDetentForHaptic != nearestDetent) {
      HapticFeedback.selectionClick();
    }
    _yawDetentForHaptic = yawSnapped ? nearestDetent : null;
  }

  void _handleUprightHaptic(_PlacedModel model) {
    final aligned = _isAlignedToGround(model);
    if (aligned && !_tiltSnappedForHaptic) {
      HapticFeedback.lightImpact();
    }
    _tiltSnappedForHaptic = aligned;
  }

  void _onRotationGestureEnd() {
    final selected = _selectedModel;
    if (selected == null) return;
    // Settle yaw onto its snap target so the next drag continues smoothly.
    selected.rawYaw = selected.userYaw;
    final aligned = _isAlignedToGround(selected);
    _showStatus(
      aligned
          ? '${_yawDegrees(selected)}° 회전 · 바닥에 정렬됨'
          : '${_yawDegrees(selected)}° 회전 · ${_groundTiltDegrees(selected)}° 기울어짐',
    );
  }

  /// Stand the selected object up onto the floor via the *shortest* path: take
  /// whichever of the object's faces is currently closest to facing up and
  /// rotate by the minimal angle so it rests flat. This adapts to however the
  /// object is currently tipped (and to models authored lying down), rather
  /// than snapping to one fixed pose.
  Future<void> _straightenSelected() async {
    final selected = _selectedModel;
    if (selected == null) return;
    if (_isAlignedToGround(selected)) {
      _showStatus('이미 바닥에 똑바로 서 있어요.');
      return;
    }

    final nearest = _nearestUprightAxis(selected);
    final worldUp = vector.Vector3(0, 1, 0);
    var axis = nearest.worldDir.cross(worldUp);
    if (axis.length2 < 1e-8) {
      // Already vertical, or pointing straight down: any horizontal axis works.
      axis = vector.Vector3(1, 0, 0);
    } else {
      axis.normalize();
    }
    // Apply the world-space correction on top of the current orientation.
    final correction = vector.Matrix4.identity()..rotate(axis, nearest.tilt);
    selected.leanRotation = correction.multiplied(selected.leanRotation);

    _syncHapticTrackers(selected);
    HapticFeedback.mediumImpact();
    _setModelGroundPosition(selected, selected.groundPosition);
    await _syncPlacedModelTransform(selected);
    _showStatus('가장 가까운 방향으로 바닥에 세웠어요.');
  }

  int _yawDegrees(_PlacedModel model) {
    var deg = (model.userYaw * 180 / math.pi).round() % 360;
    if (deg < 0) deg += 360;
    return deg;
  }

  bool _isYawSnapped(_PlacedModel model) {
    final ratio = model.userYaw / _yawSnapStep;
    return (ratio - ratio.round()).abs() < 0.01;
  }

  Future<void> _removeSelected() async {
    final nodeName = _selectedNodeName;
    if (nodeName == null || _arkitController == null) return;
    final removed = _placedModels[nodeName];
    await _arkitController!.remove(nodeName);
    if (removed != null) {
      await _removeShadow(removed);
      await _removeModelRig(removed);
    }
    if (!mounted) return;
    setState(() {
      _placedModels.remove(nodeName);
      _selectedNodeName = null;
      _draggingNodeName = null;
      if (removed != null) {
        _activeAsset = removed.asset;
      }
    });
    _showStatus('선택한 모델을 제거했어요.');
  }

  Future<void> _clearAllModels() async {
    if (_placedModels.isEmpty) return;
    final count = _placedModels.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          '전체 삭제',
          style: GoogleFonts.nunito(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          '배치한 $count개의 모델을 모두 제거할까요?',
          style: GoogleFonts.nunito(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              '취소',
              style: GoogleFonts.nunito(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              '모두 제거',
              style: GoogleFonts.nunito(
                color: Colors.redAccent,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final controller = _arkitController;
    if (controller != null) {
      for (final model in _placedModels.values) {
        await controller.remove(model.nodeName);
        await _removeShadow(model);
        await _removeModelRig(model);
      }
    }
    if (!mounted) return;
    setState(() {
      _placedModels.clear();
      _selectedNodeName = null;
      _draggingNodeName = null;
    });
    _showStatus('배치한 모델을 모두 제거했어요.');
  }

  String? _roomLightLabel() {
    if (!_lightEstimateActive) return null;
    final brightness = _ambientIntensity < 500
        ? '어두움'
        : _ambientIntensity < 1100
        ? '보통'
        : '밝음';
    final warmth = _ambientTemperature < 4600
        ? '따뜻함'
        : _ambientTemperature < 6200
        ? '중간'
        : '시원함';
    final parts = <String>[brightness, warmth];

    // Local light at the selected object's spot (sampled from the camera).
    final selected = _selectedModel;
    if (selected != null && selected.localFactorSeeded) {
      if (selected.localLightFactor < 0.78) {
        parts.add('그늘');
      } else if (selected.localLightFactor > 1.22) {
        parts.add('밝은 자리');
      }
    }

    final profile = _activeRenderProfile;
    if (profile != null && profile.needsColorLift) parts.add('색보정');
    return parts.join(' · ');
  }

  Color _roomLightColor() {
    if (_ambientTemperature < 4600) return AppColors.accent;
    if (_ambientTemperature > 6200) return const Color(0xFF8FB7E8);
    return Colors.white;
  }

  void _showPlacementMessage(String message) => _showStatus(message);

  void _showStatus(String message, {bool transient = true}) {
    if (!mounted) return;
    _statusClearTimer?.cancel();
    setState(() => _statusMessage = message);
    if (transient) {
      _statusClearTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && _statusMessage == message) {
          setState(() => _statusMessage = null);
        }
      });
    }
  }

  void _syncHapticTrackers(_PlacedModel model) {
    final detent = (model.rawYaw / _yawSnapStep).round();
    final yawSnapped =
        (model.rawYaw - detent * _yawSnapStep).abs() < _yawSnapWindow;
    _yawDetentForHaptic = yawSnapped ? detent : null;
    _tiltSnappedForHaptic = _isAlignedToGround(model);
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
            // No environment probes: image-based lighting is captured from the
            // camera while the room is bright and does NOT dim when the light
            // changes, which kept objects glowing in dark rooms. The
            // estimate-driven directional rig is the single light source, so
            // object brightness tracks the real room deterministically.
            environmentTexturing:
                ARWorldTrackingConfigurationEnvironmentTexturing.none,
            autoenablesDefaultLighting: false,
            enableTapRecognizer: false,
            enablePanRecognizer: false,
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
              dimensions: _activeAsset?.dimensions,
              lightLabel: _roomLightLabel(),
              lightColor: _roomLightColor(),
              onClose: () => Navigator.pop(context),
              onClearAll: _placedModels.isNotEmpty ? _clearAllModels : null,
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
              yawDegrees: _selectedModel != null
                  ? _yawDegrees(_selectedModel!)
                  : 0,
              yawRadians: _selectedModel?.userYaw ?? 0,
              isUpright: _selectedModel == null
                  ? true
                  : _isAlignedToGround(_selectedModel!),
              isYawSnapped:
                  _selectedModel != null && _isYawSnapped(_selectedModel!),
              onPlace: _placeActiveModel,
              onRotateDrag: _rotateSelectedFromWheel,
              onRotateEnd: _onRotationGestureEnd,
              onStraighten: _straightenSelected,
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
  final AssetRenderProfile? renderProfile;

  const _ArAsset({
    required this.id,
    required this.name,
    required this.category,
    required this.dimensions,
    required this.modelUrl,
    required this.renderProfile,
  });
}

class _PreparedModel {
  final _ArAsset asset;
  final String localGlbPath;
  final String previewValidGlbPath;
  final String previewInvalidGlbPath;
  final double scale;
  final vector.Vector3 baseRotation;
  final _ModelBounds? bounds;
  final _PreviewSize previewSize;

  const _PreparedModel({
    required this.asset,
    required this.localGlbPath,
    required this.previewValidGlbPath,
    required this.previewInvalidGlbPath,
    required this.scale,
    required this.baseRotation,
    required this.bounds,
    required this.previewSize,
  });
}

class _PlacedModel {
  final String nodeName;
  final _ArAsset asset;
  final String localGlbPath;
  final double scale;
  final vector.Vector3 baseRotation;
  final _ModelBounds? bounds;
  final _PreviewSize previewSize;

  /// Bit index identifying this object's private light category. The model
  /// node and its dedicated light rig share `1 << lightBit`, so the rig
  /// illuminates only this object.
  final int lightBit;

  vector.Vector3 groundPosition;
  vector.Vector3 position;

  /// Heading about world up. [rawYaw] is the unsnapped gesture accumulation;
  /// [userYaw] is what is actually applied (snapped to 15° detents when close).
  double rawYaw;
  double userYaw;

  /// Free-form lean accumulated in world space about camera-relative axes.
  /// Unbounded so the object can be tipped over or stood up from any pose.
  vector.Matrix4 leanRotation;

  /// Light multiplier for the spot this object stands on, estimated from the
  /// camera image (1 = as bright as the frame average). Drives this object's
  /// private rig so a model under a table reads darker than one in sunlight.
  double localLightFactor;
  bool localFactorSeeded;

  /// Last values pushed to the platform channel, for no-op skipping.
  double? appliedRigIntensity;
  double? appliedRigTemperature;
  double? appliedShadowAlpha;

  int get lightCategory => 1 << lightBit;

  _PlacedModel({
    required this.nodeName,
    required this.asset,
    required this.localGlbPath,
    required this.scale,
    required this.baseRotation,
    required this.bounds,
    required this.previewSize,
    required this.groundPosition,
    required this.lightBit,
  }) : position = groundPosition,
       rawYaw = 0,
       userYaw = 0,
       leanRotation = vector.Matrix4.identity(),
       localLightFactor = 1.0,
       localFactorSeeded = false;
}

class _ModelCalibration {
  final double scale;
  final vector.Vector3 baseRotation;
  final _ModelBounds? bounds;

  const _ModelCalibration({
    required this.scale,
    required this.baseRotation,
    required this.bounds,
  });
}

class _ModelBounds {
  final vector.Vector3 min;
  final vector.Vector3 max;

  const _ModelBounds({required this.min, required this.max});

  Iterable<vector.Vector3> get corners sync* {
    for (final x in [min.x, max.x]) {
      for (final y in [min.y, max.y]) {
        for (final z in [min.z, max.z]) {
          yield vector.Vector3(x, y, z);
        }
      }
    }
  }
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
  final String? dimensions;
  final String? lightLabel;
  final Color lightColor;
  final VoidCallback onClose;
  final VoidCallback? onClearAll;

  const _TopBar({
    required this.modelName,
    required this.placedCount,
    required this.dimensions,
    required this.lightLabel,
    required this.lightColor,
    required this.onClose,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    final dims = dimensions;
    final hasRealSize = dims != null && !dims.contains('미입력');
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
        crossAxisAlignment: CrossAxisAlignment.start,
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
                if (dims != null) ...[
                  const SizedBox(height: 3),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.straighten_rounded,
                        size: 12,
                        color: hasRealSize
                            ? AppColors.accent
                            : Colors.white.withValues(alpha: 0.5),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          hasRealSize ? '실측 $dims' : dims,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.nunito(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: hasRealSize
                                ? AppColors.accent
                                : Colors.white.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (onClearAll != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.13),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(40, 40),
                ),
                tooltip: '전체 삭제',
                onPressed: onClearAll,
                icon: const Icon(Icons.delete_sweep_rounded, size: 19),
              ),
            ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
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
              if (lightLabel != null) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: lightColor.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wb_sunny_rounded, color: lightColor, size: 12),
                      const SizedBox(width: 4),
                      Text(
                        lightLabel!,
                        style: GoogleFonts.nunito(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
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
  final int yawDegrees;
  final double yawRadians;
  final bool isUpright;
  final bool isYawSnapped;
  final VoidCallback onPlace;
  final ValueChanged<Offset> onRotateDrag;
  final VoidCallback onRotateEnd;
  final VoidCallback onStraighten;
  final VoidCallback onRemove;

  const _BottomBar({
    required this.hasSelectedObject,
    required this.canPlace,
    required this.yawDegrees,
    required this.yawRadians,
    required this.isUpright,
    required this.isYawSnapped,
    required this.onPlace,
    required this.onRotateDrag,
    required this.onRotateEnd,
    required this.onStraighten,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    if (hasSelectedObject) {
      return Stack(
        alignment: Alignment.bottomCenter,
        clipBehavior: Clip.none,
        children: [
          _RotationHandle(onDragDelta: onRotateDrag, onDragEnd: onRotateEnd),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomPad + 142,
            child: IgnorePointer(
              child: Center(
                child: _RotationReadout(
                  yawDegrees: yawDegrees,
                  isUpright: isUpright,
                  isYawSnapped: isYawSnapped,
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomPad + 72,
            child: IgnorePointer(
              child: Center(
                child: _CompassDial(
                  yaw: yawRadians,
                  aligned: isUpright && isYawSnapped,
                ),
              ),
            ),
          ),
          Positioned(
            bottom: bottomPad + 12,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _ControlBtn(
                  icon: Icons.straighten_rounded,
                  label: '바로 세우기',
                  highlight: !isUpright,
                  onTap: onStraighten,
                ),
                const SizedBox(width: 10),
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
  final bool highlight;

  const _ControlBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isWide = false,
    this.subtle = false,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final background = highlight
        ? AppColors.primary.withValues(alpha: 0.92)
        : subtle
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.21);
    final borderColor = highlight
        ? AppColors.primaryLight.withValues(alpha: 0.9)
        : Colors.white.withValues(alpha: subtle ? 0.15 : 0.32);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isWide ? 20 : 15,
          vertical: 12,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(40),
          border: Border.all(color: borderColor),
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
  final ValueChanged<Offset> onDragDelta;
  final VoidCallback? onDragEnd;

  const _RotationHandle({required this.onDragDelta, this.onDragEnd});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = width / 2;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) => onDragDelta(details.delta),
      onPanEnd: (_) => onDragEnd?.call(),
      onPanCancel: () => onDragEnd?.call(),
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
              child: CustomPaint(painter: _SemiCircleRulerPainter()),
            ),
          ],
        ),
      ),
    );
  }
}

class _RotationReadout extends StatelessWidget {
  final int yawDegrees;
  final bool isUpright;
  final bool isYawSnapped;

  const _RotationReadout({
    required this.yawDegrees,
    required this.isUpright,
    required this.isYawSnapped,
  });

  @override
  Widget build(BuildContext context) {
    final aligned = isUpright && isYawSnapped;
    final color = !isUpright
        ? Colors.amberAccent
        : aligned
        ? AppColors.accent
        : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: color.withValues(alpha: aligned ? 0.85 : 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.rotate_right_rounded, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            '$yawDegrees°',
            style: GoogleFonts.nunito(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 8),
          Container(width: 1, height: 14, color: Colors.white24),
          const SizedBox(width: 8),
          Icon(
            isUpright
                ? Icons.check_circle_rounded
                : Icons.report_problem_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            isUpright ? '바닥에 정렬됨' : '기울어짐',
            style: GoogleFonts.nunito(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompassDial extends StatelessWidget {
  final double yaw;
  final bool aligned;

  const _CompassDial({required this.yaw, required this.aligned});

  @override
  Widget build(BuildContext context) {
    final color = aligned ? AppColors.accent : AppColors.primaryLight;
    return Container(
      width: 62,
      height: 62,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withValues(alpha: 0.5),
        border: Border.all(
          color: color.withValues(alpha: aligned ? 0.9 : 0.45),
          width: 1.5,
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Fixed reference notch marking the viewer's "front" (0°).
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white60,
                ),
              ),
            ),
          ),
          // Arrow that orbits the dial to show the object's facing direction.
          Transform.rotate(
            angle: yaw,
            child: SizedBox(
              width: 62,
              height: 62,
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Icon(Icons.navigation_rounded, size: 22, color: color),
                ),
              ),
            ),
          ),
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _SemiCircleRulerPainter extends CustomPainter {
  _SemiCircleRulerPainter();

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

    final center = Offset(cx, size.height * 0.56);
    canvas.drawLine(
      Offset(cx - radius * 0.33, center.dy),
      Offset(cx + radius * 0.33, center.dy),
      Paint()
        ..color = AppColors.primary.withValues(alpha: 0.45)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      Offset(cx, size.height * 0.34),
      Offset(cx, size.height * 0.78),
      Paint()
        ..color = AppColors.accent.withValues(alpha: 0.45)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      center,
      9,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.drawCircle(
      center,
      4.8,
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_SemiCircleRulerPainter oldDelegate) => false;
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

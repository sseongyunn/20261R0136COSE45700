import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;

  const ApiException(this.statusCode, this.message);

  @override
  String toString() => message;
}

class UploadTicket {
  final String sourceImageId;
  final String uploadUrl;
  final String s3Bucket;
  final String s3Key;

  const UploadTicket({
    required this.sourceImageId,
    required this.uploadUrl,
    required this.s3Bucket,
    required this.s3Key,
  });

  factory UploadTicket.fromJson(Map<String, dynamic> json) => UploadTicket(
    sourceImageId: json['sourceImageId'] as String,
    uploadUrl: json['uploadUrl'] as String,
    s3Bucket: json['s3Bucket'] as String,
    s3Key: json['s3Key'] as String,
  );
}

class GenerationJob {
  final String jobId;
  final String status;
  final String? provider;
  final String? generationMode;
  final String? providerRequestId;
  final String? assetId;
  final String? failureReason;

  const GenerationJob({
    required this.jobId,
    required this.status,
    this.provider,
    this.generationMode,
    this.providerRequestId,
    this.assetId,
    this.failureReason,
  });

  factory GenerationJob.fromJson(Map<String, dynamic> json) => GenerationJob(
    jobId: json['jobId'] as String,
    status: json['status'] as String,
    provider: json['provider'] as String?,
    generationMode: json['generationMode'] as String?,
    providerRequestId: json['providerRequestId'] as String?,
    assetId: json['assetId'] as String?,
    failureReason: json['failureReason'] as String?,
  );
}

class SourceColorProfile {
  final String? sourceProfileId;
  final double? originalMeanR;
  final double? originalMeanG;
  final double? originalMeanB;
  final double? originalLuminanceMean;
  final double? originalSaturationMean;
  final double? processedMeanR;
  final double? processedMeanG;
  final double? processedMeanB;
  final double? processedLuminanceMean;
  final double? processedSaturationMean;
  final double? targetLuminance;
  final double? exposureGain;
  final double? gamma;
  final double? saturationGain;
  final double? contrastGain;
  final double? redGain;
  final double? greenGain;
  final double? blueGain;

  const SourceColorProfile({
    this.sourceProfileId,
    this.originalMeanR,
    this.originalMeanG,
    this.originalMeanB,
    this.originalLuminanceMean,
    this.originalSaturationMean,
    this.processedMeanR,
    this.processedMeanG,
    this.processedMeanB,
    this.processedLuminanceMean,
    this.processedSaturationMean,
    this.targetLuminance,
    this.exposureGain,
    this.gamma,
    this.saturationGain,
    this.contrastGain,
    this.redGain,
    this.greenGain,
    this.blueGain,
  });

  factory SourceColorProfile.fromJson(Map<String, dynamic> json) {
    double? asDouble(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is num) return value.toDouble();
      return double.tryParse(value.toString());
    }

    return SourceColorProfile(
      sourceProfileId: json['sourceProfileId'] as String?,
      originalMeanR: asDouble('originalMeanR'),
      originalMeanG: asDouble('originalMeanG'),
      originalMeanB: asDouble('originalMeanB'),
      originalLuminanceMean: asDouble('originalLuminanceMean'),
      originalSaturationMean: asDouble('originalSaturationMean'),
      processedMeanR: asDouble('processedMeanR'),
      processedMeanG: asDouble('processedMeanG'),
      processedMeanB: asDouble('processedMeanB'),
      processedLuminanceMean: asDouble('processedLuminanceMean'),
      processedSaturationMean: asDouble('processedSaturationMean'),
      targetLuminance: asDouble('targetLuminance'),
      exposureGain: asDouble('exposureGain'),
      gamma: asDouble('gamma'),
      saturationGain: asDouble('saturationGain'),
      contrastGain: asDouble('contrastGain'),
      redGain: asDouble('redGain'),
      greenGain: asDouble('greenGain'),
      blueGain: asDouble('blueGain'),
    );
  }

  double? get targetMeanR => processedMeanR ?? originalMeanR;
  double? get targetMeanG => processedMeanG ?? originalMeanG;
  double? get targetMeanB => processedMeanB ?? originalMeanB;

  bool get hasColorBaseline =>
      targetMeanR != null && targetMeanG != null && targetMeanB != null;

  bool get needsColorLift =>
      (exposureGain ?? 1.0) > 1.05 ||
      (processedLuminanceMean ?? originalLuminanceMean ?? 1.0) <
          (targetLuminance ?? 0.52) - 0.04;
}

class AssetRenderProfile {
  final int profileVersion;
  final String source;
  final double? albedoMeanR;
  final double? albedoMeanG;
  final double? albedoMeanB;
  final double? textureLuminanceMean;
  final double? textureSaturationMean;
  final double? roughnessMean;
  final double? metallicMean;
  final double suggestedExposureGain;
  final double suggestedEmissiveLift;
  final bool hasEmbeddedTextures;
  final bool hasExternalTextures;
  final bool hasNormalMap;
  final bool hasOcclusionMap;
  final bool hasEmissive;
  final int materialCount;
  final int textureCount;
  final String? notes;
  final SourceColorProfile? inputColorProfile;

  const AssetRenderProfile({
    required this.profileVersion,
    required this.source,
    required this.suggestedExposureGain,
    required this.suggestedEmissiveLift,
    required this.hasEmbeddedTextures,
    required this.hasExternalTextures,
    required this.hasNormalMap,
    required this.hasOcclusionMap,
    required this.hasEmissive,
    required this.materialCount,
    required this.textureCount,
    this.albedoMeanR,
    this.albedoMeanG,
    this.albedoMeanB,
    this.textureLuminanceMean,
    this.textureSaturationMean,
    this.roughnessMean,
    this.metallicMean,
    this.notes,
    this.inputColorProfile,
  });

  factory AssetRenderProfile.fromJson(Map<String, dynamic> json) {
    double? asDouble(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is num) return value.toDouble();
      return double.tryParse(value.toString());
    }

    int asInt(String key) {
      final value = json[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    bool asBool(String key) => json[key] == true;

    final inputColorJson = json['inputColorProfile'];
    return AssetRenderProfile(
      profileVersion: asInt('profileVersion'),
      source: (json['source'] ?? 'fallback').toString(),
      albedoMeanR: asDouble('albedoMeanR'),
      albedoMeanG: asDouble('albedoMeanG'),
      albedoMeanB: asDouble('albedoMeanB'),
      textureLuminanceMean: asDouble('textureLuminanceMean'),
      textureSaturationMean: asDouble('textureSaturationMean'),
      roughnessMean: asDouble('roughnessMean'),
      metallicMean: asDouble('metallicMean'),
      suggestedExposureGain: asDouble('suggestedExposureGain') ?? 1.0,
      suggestedEmissiveLift: asDouble('suggestedEmissiveLift') ?? 0.0,
      hasEmbeddedTextures: asBool('hasEmbeddedTextures'),
      hasExternalTextures: asBool('hasExternalTextures'),
      hasNormalMap: asBool('hasNormalMap'),
      hasOcclusionMap: asBool('hasOcclusionMap'),
      hasEmissive: asBool('hasEmissive'),
      materialCount: asInt('materialCount'),
      textureCount: asInt('textureCount'),
      notes: json['notes'] as String?,
      inputColorProfile: inputColorJson is Map<String, dynamic>
          ? SourceColorProfile.fromJson(inputColorJson)
          : null,
    );
  }

  bool get needsColorLift =>
      suggestedExposureGain > 1.08 ||
      suggestedEmissiveLift > 0.02 ||
      (inputColorProfile?.needsColorLift ?? false);
}

class FurnitureAsset {
  final String assetId;
  final String generationJobId;
  final String? name;
  final String? category;
  final double? widthCm;
  final double? heightCm;
  final double? depthCm;
  final String modelS3Bucket;
  final String modelS3Key;
  final DateTime? createdAt;
  final AssetRenderProfile? renderProfile;

  const FurnitureAsset({
    required this.assetId,
    required this.generationJobId,
    required this.modelS3Bucket,
    required this.modelS3Key,
    this.name,
    this.category,
    this.widthCm,
    this.heightCm,
    this.depthCm,
    this.createdAt,
    this.renderProfile,
  });

  factory FurnitureAsset.fromJson(Map<String, dynamic> json) {
    double? asDouble(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is num) return value.toDouble();
      return double.tryParse(value.toString());
    }

    final profileJson = json['renderProfile'];
    return FurnitureAsset(
      assetId: json['assetId'] as String,
      generationJobId: json['generationJobId'] as String,
      name: json['name'] as String?,
      category: json['category'] as String?,
      widthCm: asDouble('widthCm'),
      heightCm: asDouble('heightCm'),
      depthCm: asDouble('depthCm'),
      modelS3Bucket: json['modelS3Bucket'] as String,
      modelS3Key: json['modelS3Key'] as String,
      createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()),
      renderProfile: profileJson is Map<String, dynamic>
          ? AssetRenderProfile.fromJson(profileJson)
          : null,
    );
  }

  String get displayName =>
      name?.trim().isNotEmpty == true ? name!.trim() : 'Untitled model';

  String get displayCategory =>
      category?.trim().isNotEmpty == true ? category!.trim() : 'furniture';

  String get dimensions {
    final values = [widthCm, depthCm, heightCm];
    if (values.every((v) => v != null)) {
      String fmt(double v) =>
          v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
      return '${fmt(widthCm!)} × ${fmt(depthCm!)} × ${fmt(heightCm!)} cm';
    }
    return '크기 미입력';
  }
}

class ApiClient extends ChangeNotifier {
  String? _accessToken;
  String? _email;

  bool get isAuthenticated => _accessToken != null && _accessToken!.isNotEmpty;
  String? get email => _email;

  Future<void> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('accessToken');
    _email = prefs.getString('userEmail');
  }

  Future<void> signup(String email, String password) async {
    final json = await _postJson('/auth/signup', {
      'email': email,
      'password': password,
    }, auth: false);
    await _saveAuth(json, fallbackEmail: email);
  }

  Future<void> login(String email, String password) async {
    final json = await _postJson('/auth/login', {
      'email': email,
      'password': password,
    }, auth: false);
    await _saveAuth(json, fallbackEmail: email);
  }

  Future<void> logout() async {
    _accessToken = null;
    _email = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('accessToken');
    await prefs.remove('userEmail');
    notifyListeners();
  }

  Future<UploadTicket> requestSourceImageUploadUrl({
    required String extension,
    required String contentType,
  }) async {
    final json = await _postJson('/uploads/source-image-url', {
      'extension': extension,
      'contentType': contentType,
    });
    return UploadTicket.fromJson(json);
  }

  Future<void> uploadBytesToPresignedUrl({
    required String uploadUrl,
    required Uint8List bytes,
    required String contentType,
  }) async {
    final response = await http.put(
      Uri.parse(uploadUrl),
      headers: {'Content-Type': contentType},
      body: bytes,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, response.body);
    }
  }

  Future<void> completeSourceImage(UploadTicket ticket) async {
    await _postJson('/source-images/complete', {
      'sourceImageId': ticket.sourceImageId,
      's3Bucket': ticket.s3Bucket,
      's3Key': ticket.s3Key,
    });
  }

  Future<GenerationJob> createGenerationJob({
    required String sourceImageId,
    required String name,
    required String category,
    String generationMode = 'single',
    String? backSourceImageId,
    String? leftSourceImageId,
    String? rightSourceImageId,
    double? widthCm,
    double? heightCm,
    double? depthCm,
  }) async {
    final body = <String, dynamic>{
      'sourceImageId': sourceImageId,
      'generationMode': generationMode,
      'name': name,
      'category': category,
      'widthCm': widthCm,
      'heightCm': heightCm,
      'depthCm': depthCm,
    };
    if (backSourceImageId != null) {
      body['backSourceImageId'] = backSourceImageId;
    }
    if (leftSourceImageId != null) {
      body['leftSourceImageId'] = leftSourceImageId;
    }
    if (rightSourceImageId != null) {
      body['rightSourceImageId'] = rightSourceImageId;
    }

    final json = await _postJson('/generation-jobs', body);
    return GenerationJob.fromJson(json);
  }

  Future<GenerationJob> getGenerationJob(String jobId) async {
    final json = await _getJson('/generation-jobs/$jobId');
    return GenerationJob.fromJson(json);
  }

  Future<List<FurnitureAsset>> listFurnitureAssets() async {
    final json = await _getList('/furniture-assets');
    return json
        .map((item) => FurnitureAsset.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<String> getModelUrl(String assetId) async {
    final json = await _getJson('/furniture-assets/$assetId/model-url');
    return json['modelUrl'] as String;
  }

  Future<AssetRenderProfile?> getAssetRenderProfile(String assetId) async {
    try {
      final json = await _getJson('/furniture-assets/$assetId/render-profile');
      return AssetRenderProfile.fromJson(json);
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> _saveAuth(
    Map<String, dynamic> json, {
    required String fallbackEmail,
  }) async {
    _accessToken = json['accessToken'] as String;
    final user = json['user'];
    _email = user is Map<String, dynamic>
        ? (user['email'] as String? ?? fallbackEmail)
        : fallbackEmail;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('accessToken', _accessToken!);
    await prefs.setString('userEmail', _email!);
    notifyListeners();
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body, {
    bool auth = true,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl$path'),
      headers: _headers(auth: auth),
      body: jsonEncode(body),
    );
    return _decodeMap(response);
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final response = await http.get(
      Uri.parse('$baseUrl$path'),
      headers: _headers(auth: true),
    );
    return _decodeMap(response);
  }

  Future<List<dynamic>> _getList(String path) async {
    final response = await http.get(
      Uri.parse('$baseUrl$path'),
      headers: _headers(auth: true),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, _errorMessage(response));
    }
    return jsonDecode(response.body) as List<dynamic>;
  }

  Map<String, String> _headers({required bool auth}) {
    final headers = {'Content-Type': 'application/json'};
    if (auth && _accessToken != null) {
      headers['Authorization'] = 'Bearer $_accessToken';
    }
    return headers;
  }

  Map<String, dynamic> _decodeMap(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(response.statusCode, _errorMessage(response));
    }
    if (response.body.isEmpty) return <String, dynamic>{};
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  String _errorMessage(http.Response response) {
    if (response.body.isEmpty) return response.reasonPhrase ?? 'Request failed';
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic> && body['detail'] != null) {
        return body['detail'].toString();
      }
    } catch (_) {
      return response.body;
    }
    return response.body;
  }
}

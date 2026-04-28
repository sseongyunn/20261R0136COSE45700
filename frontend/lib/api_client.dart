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
  final String? providerRequestId;
  final String? assetId;
  final String? failureReason;

  const GenerationJob({
    required this.jobId,
    required this.status,
    this.providerRequestId,
    this.assetId,
    this.failureReason,
  });

  factory GenerationJob.fromJson(Map<String, dynamic> json) => GenerationJob(
    jobId: json['jobId'] as String,
    status: json['status'] as String,
    providerRequestId: json['providerRequestId'] as String?,
    assetId: json['assetId'] as String?,
    failureReason: json['failureReason'] as String?,
  );
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
  });

  factory FurnitureAsset.fromJson(Map<String, dynamic> json) {
    double? asDouble(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is num) return value.toDouble();
      return double.tryParse(value.toString());
    }

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
    double? widthCm,
    double? heightCm,
    double? depthCm,
  }) async {
    final json = await _postJson('/generation-jobs', {
      'sourceImageId': sourceImageId,
      'name': name,
      'category': category,
      'widthCm': widthCm,
      'heightCm': heightCm,
      'depthCm': depthCm,
    });
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

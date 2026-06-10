class PendingGenerationJob {
  final String jobId;
  final String name;
  final String category;
  final String imagePath;
  final String dimensions;
  final String status;
  final String? assetId;
  final String? failureReason;
  final DateTime createdAt;

  const PendingGenerationJob({
    required this.jobId,
    required this.name,
    required this.category,
    required this.imagePath,
    required this.dimensions,
    required this.status,
    required this.createdAt,
    this.assetId,
    this.failureReason,
  });

  bool get isRunning => status != 'succeeded' && status != 'failed';

  PendingGenerationJob copyWith({
    String? status,
    String? assetId,
    String? failureReason,
  }) {
    return PendingGenerationJob(
      jobId: jobId,
      name: name,
      category: category,
      imagePath: imagePath,
      dimensions: dimensions,
      status: status ?? this.status,
      assetId: assetId ?? this.assetId,
      failureReason: failureReason ?? this.failureReason,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'jobId': jobId,
    'name': name,
    'category': category,
    'imagePath': imagePath,
    'dimensions': dimensions,
    'status': status,
    'assetId': assetId,
    'failureReason': failureReason,
    'createdAt': createdAt.toIso8601String(),
  };

  factory PendingGenerationJob.fromJson(Map<String, dynamic> json) {
    return PendingGenerationJob(
      jobId: json['jobId'] as String,
      name: (json['name'] ?? 'Untitled model') as String,
      category: (json['category'] ?? 'furniture') as String,
      imagePath: (json['imagePath'] ?? '') as String,
      dimensions: (json['dimensions'] ?? '크기 미입력') as String,
      status: (json['status'] ?? 'queued') as String,
      assetId: json['assetId'] as String?,
      failureReason: json['failureReason'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

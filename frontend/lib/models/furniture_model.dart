class FurnitureModel {
  final String id;
  final String name;
  final String category;
  final String imagePath;
  final String dimensions;
  final String material;
  final int processingSeconds;
  final DateTime createdAt;
  final String? assetId;
  final String? generationJobId;
  final String? modelUrl;

  const FurnitureModel({
    required this.id,
    required this.name,
    required this.category,
    required this.imagePath,
    required this.dimensions,
    required this.material,
    required this.processingSeconds,
    required this.createdAt,
    this.assetId,
    this.generationJobId,
    this.modelUrl,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'category': category,
    'imagePath': imagePath,
    'dimensions': dimensions,
    'material': material,
    'processingSeconds': processingSeconds,
    'createdAt': createdAt.toIso8601String(),
    'assetId': assetId,
    'generationJobId': generationJobId,
    'modelUrl': modelUrl,
  };

  factory FurnitureModel.fromJson(Map<String, dynamic> json) => FurnitureModel(
    id: json['id'] as String,
    name: (json['name'] ?? 'Untitled model') as String,
    category: (json['category'] ?? 'furniture') as String,
    imagePath: (json['imagePath'] ?? '') as String,
    dimensions: (json['dimensions'] ?? '크기 미입력') as String,
    material: (json['material'] ?? 'GLB model') as String,
    processingSeconds: (json['processingSeconds'] ?? 0) as int,
    createdAt: DateTime.parse(json['createdAt'] as String),
    assetId: json['assetId'] as String?,
    generationJobId: json['generationJobId'] as String?,
    modelUrl: json['modelUrl'] as String?,
  );
}

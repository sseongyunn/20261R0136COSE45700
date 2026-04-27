class FurnitureModel {
  final String id;
  final String name;
  final String category;
  final String imagePath;
  final String dimensions;
  final String material;
  final int processingSeconds;
  final DateTime createdAt;

  const FurnitureModel({
    required this.id,
    required this.name,
    required this.category,
    required this.imagePath,
    required this.dimensions,
    required this.material,
    required this.processingSeconds,
    required this.createdAt,
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
      };

  factory FurnitureModel.fromJson(Map<String, dynamic> json) => FurnitureModel(
        id: json['id'] as String,
        name: json['name'] as String,
        category: json['category'] as String,
        imagePath: json['imagePath'] as String,
        dimensions: json['dimensions'] as String,
        material: json['material'] as String,
        processingSeconds: json['processingSeconds'] as int,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}

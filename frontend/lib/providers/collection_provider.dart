import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/furniture_model.dart';

class CollectionProvider extends ChangeNotifier {
  List<FurnitureModel> _models = [];

  List<FurnitureModel> get models => List.unmodifiable(_models);
  int get count => _models.length;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('furnifit_models') ?? [];
    _models = raw
        .map((e) => FurnitureModel.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();
    notifyListeners();
  }

  Future<void> add(FurnitureModel model) async {
    _models.insert(0, model);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'furnifit_models',
      _models.map((m) => jsonEncode(m.toJson())).toList(),
    );
  }
}

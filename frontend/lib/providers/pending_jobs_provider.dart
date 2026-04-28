import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart';
import '../models/pending_generation_job.dart';

class PendingJobsProvider extends ChangeNotifier {
  static const _storageKey = 'furni3d_pending_jobs';

  List<PendingGenerationJob> _jobs = [];

  List<PendingGenerationJob> get jobs => List.unmodifiable(_jobs);
  int get runningCount => _jobs.where((job) => job.isRunning).length;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storageKey) ?? [];
    _jobs = raw
        .map(
          (item) => PendingGenerationJob.fromJson(
            jsonDecode(item) as Map<String, dynamic>,
          ),
        )
        .toList();
    notifyListeners();
  }

  Future<void> add(PendingGenerationJob job) async {
    _jobs.removeWhere((item) => item.jobId == job.jobId);
    _jobs.insert(0, job);
    await _persist();
    notifyListeners();
  }

  Future<void> updateFromRemote(GenerationJob remote) async {
    final index = _jobs.indexWhere((job) => job.jobId == remote.jobId);
    if (index < 0) return;
    _jobs[index] = _jobs[index].copyWith(
      status: remote.status,
      assetId: remote.assetId,
      failureReason: remote.failureReason,
    );
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String jobId) async {
    _jobs.removeWhere((job) => job.jobId == jobId);
    await _persist();
    notifyListeners();
  }

  Future<void> clear() async {
    _jobs = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _storageKey,
      _jobs.map((job) => jsonEncode(job.toJson())).toList(),
    );
  }
}

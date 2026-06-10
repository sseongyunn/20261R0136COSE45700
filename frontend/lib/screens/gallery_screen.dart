import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../models/pending_generation_job.dart';
import '../providers/pending_jobs_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/furni_image.dart';
import 'model_url_screen.dart';
import 'processing_screen.dart';
import 'upload_screen.dart';
import 'ar_view_screen.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final List<String> baseCategories = const ["All", "Chairs", "Sofas", "Beds", "Tables", "Lamps", "Cabinets"];
  List<String> activeCategories = ["All", "Chairs", "Sofas", "Beds", "Tables", "Lamps", "Cabinets"];
  String selectedCategory = "All";

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = "";
  Timer? _debounceTimer;

  List<FurnitureAsset> _assets = [];
  Timer? _timer;
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 600), () {
        if (mounted) {
          setState(() {
            _searchQuery = _searchController.text.toLowerCase();
          });
        }
      });
    });
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounceTimer?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  String _normalizeCategory(String? raw) {
    if (raw == null || raw.trim().isEmpty) return 'Others';
    final clean = raw.trim().toLowerCase();
    if (clean == 'chair' || clean == 'chairs') return 'Chairs';
    if (clean == 'sofa' || clean == 'sofas' || clean == 'couch') return 'Sofas';
    if (clean == 'bed' || clean == 'beds') return 'Beds';
    if (clean == 'table' || clean == 'tables' || clean == 'desk') return 'Tables';
    if (clean == 'lamp' || clean == 'lamps' || clean == 'light') return 'Lamps';
    if (clean == 'cabinet' || clean == 'cabinets' || clean == 'sideboard') return 'Cabinets';

    final capitalized = raw.trim()[0].toUpperCase() + raw.trim().substring(1);
    if (capitalized.toLowerCase().endsWith('s')) {
      return capitalized;
    }
    return '${capitalized}s';
  }

  Future<void> _refresh() async {
    if (!mounted || _refreshing) return;
    _refreshing = true;
    final showFullLoading =
        _assets.isEmpty && context.read<PendingJobsProvider>().jobs.isEmpty;
    setState(() {
      _loading = showFullLoading;
      _error = null;
    });

    try {
      final api = context.read<ApiClient>();
      final pending = context.read<PendingJobsProvider>();

      for (final job in List<PendingGenerationJob>.from(pending.jobs)) {
        if (!job.isRunning) continue;
        final remote = await api.getGenerationJob(job.jobId);
        if (!mounted) return;
        if (remote.status == 'succeeded' && remote.assetId != null) {
          await pending.remove(remote.jobId);
        } else {
          await pending.updateFromRemote(remote);
        }
      }

      final assets = await api.listFurnitureAssets();
      if (!mounted) return;

      final Set<String> customCats = {};
      for (final asset in assets) {
        final norm = _normalizeCategory(asset.category);
        if (!baseCategories.contains(norm)) {
          customCats.add(norm);
        }
      }

      setState(() {
        _assets = assets;
        activeCategories = [...baseCategories, ...customCats.toList()..sort()];
        if (!activeCategories.contains(selectedCategory)) {
          selectedCategory = "All";
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
      _refreshing = false;
    }
  }

  bool _matchesSearchQuery(String target, String query) {
    if (query.isEmpty) return true;
    const chosungs = ["ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"];
    const jongToCho = {1: 0, 2: 1, 4: 2, 7: 3, 8: 5, 16: 6, 17: 7, 19: 9, 20: 10, 21: 11, 22: 12, 23: 14, 24: 15, 25: 16, 26: 17, 27: 18};
    
    String pattern = "";
    for (int i = 0; i < query.length; i++) {
      String c = query[i];
      int code = c.codeUnitAt(0);

      if (code >= 0x3131 && code <= 0x314E) {
        int index = chosungs.indexOf(c);
        if (index != -1) {
          int start = 0xAC00 + index * 588;
          int end = start + 587;
          pattern += "[$c${String.fromCharCode(start)}-${String.fromCharCode(end)}]";
        } else {
          pattern += RegExp.escape(c);
        }
      } else if (code >= 0xAC00 && code <= 0xD7A3) {
        int offset = code - 0xAC00;
        int jong = offset % 28;
        int choJung = code - jong;
        
        if (jong == 0) {
          pattern += "[$c-${String.fromCharCode(code + 27)}]";
        } else {
          String exact = RegExp.escape(c);
          if (jongToCho.containsKey(jong)) {
            int choIndex = jongToCho[jong]!;
            int nextChoStart = 0xAC00 + choIndex * 588;
            int nextChoEnd = nextChoStart + 587;
            String nextRegex = "[${chosungs[choIndex]}${String.fromCharCode(nextChoStart)}-${String.fromCharCode(nextChoEnd)}]";
            String charChoJung = String.fromCharCode(choJung);
            pattern += "(?:$exact|[$charChoJung-${String.fromCharCode(choJung + 27)}]$nextRegex)";
          } else {
            pattern += exact;
          }
        }
      } else {
        pattern += RegExp.escape(c);
      }
    }

    try {
      final regExp = RegExp(pattern, caseSensitive: false);
      return regExp.hasMatch(target);
    } catch (e) {
      return target.toLowerCase().contains(query.toLowerCase());
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = context.watch<PendingJobsProvider>().jobs;

    final filteredPending = pending.where((job) {
      if (selectedCategory != "All") {
        final norm = _normalizeCategory(job.category);
        if (norm != selectedCategory) return false;
      }
      if (_searchQuery.isNotEmpty) {
        final matchName = _matchesSearchQuery(job.name, _searchQuery);
        final matchCategory = _matchesSearchQuery(job.category, _searchQuery);
        if (!matchName && !matchCategory) {
          return false;
        }
      }
      return true;
    }).toList();

    final filteredAssets = _assets.where((asset) {
      if (selectedCategory != "All") {
        final norm = _normalizeCategory(asset.category);
        if (norm != selectedCategory) return false;
      }
      if (_searchQuery.isNotEmpty) {
        final matchName = _matchesSearchQuery(asset.displayName, _searchQuery);
        final matchCategory = asset.category != null ? _matchesSearchQuery(asset.category!, _searchQuery) : false;
        if (!matchName && !matchCategory) {
          return false;
        }
      }
      return true;
    }).toList();

    final totalCount = filteredAssets.length + filteredPending.length;

    return Container(
      decoration: const BoxDecoration(
        gradient: AuthColors.radialGradientPreset,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '내 컬렉션',
                style: GoogleFonts.outfit(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              if (totalCount > 0) ...[
                const Gap(2),
                Text(
                  '${filteredAssets.length}개 완료 · ${filteredPending.where((job) => job.isRunning).length}개 생성 중',
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.65),
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            IconButton(
              tooltip: '새로고침',
              onPressed: _loading ? null : _refresh,
              icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            ),
          ],
        ),
        floatingActionButton: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF6C63FF), Color(0xFF3ECFCF)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF6C63FF).withValues(alpha: 0.35),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: FloatingActionButton(
            onPressed: () => Navigator.push(
              context,
              PageRouteBuilder(
                pageBuilder: (context, a, secondaryAnimation) =>
                    const UploadScreen(),
                transitionsBuilder: (context, a, secondaryAnimation, child) =>
                    SlideTransition(
                      position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                          .animate(
                            CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
                          ),
                      child: child,
                    ),
                transitionDuration: const Duration(milliseconds: 320),
              ),
            ).then((_) => _refresh()),
            backgroundColor: Colors.transparent,
            elevation: 0,
            highlightElevation: 0,
            foregroundColor: Colors.white,
            child: const Icon(Icons.add_rounded, size: 28),
          ),
        ),
        body: Column(
          children: [
            // 검색창 (캡슐 스타일)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                height: 52,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.white.withValues(alpha: 0.12),
                      Colors.white.withValues(alpha: 0.06),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.15),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.02),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    )
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search, color: Colors.white70, size: 22),
                    const Gap(12),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.w400, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: "Search your 3D models...",
                          hintStyle: GoogleFonts.outfit(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontWeight: FontWeight.w300,
                            fontSize: 14,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                        cursorColor: const Color(0xFFD3AD97),
                      ),
                    ),
                    if (_searchQuery.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          _searchController.clear();
                          FocusScope.of(context).unfocus();
                        },
                        child: const Icon(Icons.close, color: Colors.white70, size: 20),
                      ),
                    if (_searchQuery.isEmpty)
                      const Icon(Icons.tune, color: Colors.white70, size: 22),
                  ],
                ),
              ),
            ),
            const Gap(8),
            // 카테고리 탭 영역
            _CategoryTabs(
              categories: activeCategories,
              selectedCategory: selectedCategory,
              onCategorySelected: (category) {
                setState(() {
                  selectedCategory = category;
                });
              },
              highlight: const Color(0xFFD3AD97),
            ),
            const Gap(12),
            Expanded(
              child: _loading
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(color: AppColors.primary),
                          const Gap(16),
                          Text(
                            '컬렉션을 불러오는 중...',
                            style: GoogleFonts.outfit(
                              color: Colors.white.withValues(alpha: 0.75),
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    )
                  : _error != null
                      ? _ErrorState(message: _error!, onRetry: _refresh)
                      : filteredAssets.isEmpty && filteredPending.isEmpty
                          ? (_searchQuery.isNotEmpty ? const _SearchEmptyState() : const _EmptyState())
                          : GridView.builder(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                                childAspectRatio: 0.78,
                              ),
                              itemCount: filteredPending.length + filteredAssets.length,
                              itemBuilder: (_, i) {
                                if (i < filteredPending.length) {
                                  return _PendingJobCard(job: filteredPending[i]);
                                }
                                return _AssetCard(asset: filteredAssets[i - filteredPending.length]);
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingJobCard extends StatelessWidget {
  final PendingGenerationJob job;

  const _PendingJobCard({required this.job});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: job.isRunning
          ? () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ProcessingScreen(
                    jobId: job.jobId,
                    imagePath: job.imagePath,
                    requestedName: job.name,
                    requestedCategory: job.category,
                    requestedDimensions: job.dimensions,
                  ),
                ),
              )
          : null,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: job.status == 'failed'
                ? const Color(0xFF693131).withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.15),
          ),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FurniImage(imagePath: job.imagePath),
                  Container(color: Colors.black.withValues(alpha: 0.3)),
                  Center(
                    child: job.status == 'failed'
                        ? const Icon(
                            Icons.error_outline_rounded,
                            color: Color(0xFFFFB8A8),
                            size: 32,
                          )
                        : const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: AppColors.primary,
                            ),
                          ),
                  ),
                  Positioned(
                    left: 10,
                    top: 10,
                    child: _StatusPill(status: job.status),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.name,
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Gap(6),
                  Row(
                    children: [
                      _CategoryChip(label: job.category),
                      const Spacer(),
                      Text(
                        job.status == 'failed' ? '실패' : '생성 중',
                        style: GoogleFonts.outfit(
                          fontSize: 10,
                          color: job.status == 'failed'
                              ? const Color(0xFFFFB8A8)
                              : Colors.white.withValues(alpha: 0.8),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
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

class _StatusPill extends StatelessWidget {
  final String status;

  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final failed = status == 'failed';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: failed ? const Color(0xFF5E2B2B) : const Color(0xFF6C63FF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        failed ? 'failed' : status,
        style: GoogleFonts.outfit(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _AssetCard extends StatefulWidget {
  final FurnitureAsset asset;

  const _AssetCard({required this.asset});

  @override
  State<_AssetCard> createState() => _AssetCardState();
}

class _AssetCardState extends State<_AssetCard> {
  bool _openingAR = false;

  Future<void> _openAR() async {
    if (_openingAR) return;
    setState(() => _openingAR = true);
    try {
      final url = await context.read<ApiClient>().getModelUrl(widget.asset.assetId);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ArViewScreen(
            modelUrl: url,
            modelName: widget.asset.displayName,
            dimensions: widget.asset.dimensions,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('URL을 가져오지 못했어요.', style: GoogleFonts.outfit()),
        ),
      );
    } finally {
      if (mounted) setState(() => _openingAR = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ModelUrlScreen(
            assetId: widget.asset.assetId,
            modelName: widget.asset.displayName,
          ),
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    width: double.infinity,
                    color: Colors.white.withValues(alpha: 0.05),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                        ),
                        child: const Icon(
                          Icons.view_in_ar_outlined,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                    ),
                  ),
                  // AR 버튼 오버레이
                  Positioned(
                    top: 8,
                    right: 8,
                    child: GestureDetector(
                      onTap: _openAR,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF6C63FF), Color(0xFF3ECFCF)],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: _openingAR
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 12),
                                  const Gap(4),
                                  Text(
                                    'AR',
                                    style: GoogleFonts.outfit(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.asset.displayName,
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Gap(6),
                  Row(
                    children: [
                      _CategoryChip(label: widget.asset.displayCategory),
                      const Spacer(),
                      Text(
                        _fmt(widget.asset.createdAt),
                        style: GoogleFonts.outfit(
                          fontSize: 10,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(DateTime? dt) {
    if (dt == null) return '신규';
    return '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;

  const _CategoryChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: GoogleFonts.outfit(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.chair_outlined,
                color: Colors.white,
                size: 36,
              ),
            ),
            const Gap(20),
            Text(
              '아직 생성된 모델이 없어요',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            const Gap(10),
            Text(
              '가구 사진을 업로드해서\n첫 번째 3D GLB 모델을 만들어보세요',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 13,
                fontWeight: FontWeight.w300,
                color: Colors.white.withValues(alpha: 0.7),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.search_off_rounded,
                color: Colors.white,
                size: 36,
              ),
            ),
            const Gap(20),
            Text(
              '검색된 모델이 없어요',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            const Gap(10),
            Text(
              '다른 검색어를 입력해 보세요',
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 13,
                fontWeight: FontWeight.w300,
                color: Colors.white.withValues(alpha: 0.7),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: AppColors.primary,
              size: 42,
            ),
            const Gap(16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.7),
                height: 1.45,
              ),
            ),
            const Gap(18),
            TextButton(
              onPressed: onRetry,
              child: Text(
                '다시 시도',
                style: GoogleFonts.outfit(
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryTabs extends StatefulWidget {
  final List<String> categories;
  final String selectedCategory;
  final ValueChanged<String> onCategorySelected;
  final Color highlight;

  const _CategoryTabs({
    required this.categories,
    required this.selectedCategory,
    required this.onCategorySelected,
    required this.highlight,
  });

  @override
  State<_CategoryTabs> createState() => _CategoryTabsState();
}

class _CategoryTabsState extends State<_CategoryTabs> {
  final GlobalKey _parentKey = GlobalKey();
  List<GlobalKey> _tabKeys = [];
  double _indicatorLeft = 0;
  double _indicatorWidth = 0;

  @override
  void initState() {
    super.initState();
    _tabKeys = List.generate(widget.categories.length, (_) => GlobalKey());
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateIndicator());
  }

  @override
  void didUpdateWidget(covariant _CategoryTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedCategory != widget.selectedCategory ||
        oldWidget.categories != widget.categories) {
      if (oldWidget.categories.length != widget.categories.length) {
        _tabKeys = List.generate(widget.categories.length, (_) => GlobalKey());
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateIndicator());
    }
  }

  void _updateIndicator() {
    if (!mounted) return;
    final index = widget.categories.indexOf(widget.selectedCategory);
    if (index == -1 || _tabKeys.length <= index) return;

    final RenderBox? parentRenderBox = _parentKey.currentContext?.findRenderObject() as RenderBox?;
    final RenderBox? tabRenderBox = _tabKeys[index].currentContext?.findRenderObject() as RenderBox?;

    if (parentRenderBox != null && tabRenderBox != null) {
      final position = tabRenderBox.localToGlobal(Offset.zero, ancestor: parentRenderBox);
      setState(() {
        _indicatorLeft = position.dx;
        _indicatorWidth = tabRenderBox.size.width;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isReady = _indicatorWidth > 0;

    return ShaderMask(
      shaderCallback: (Rect bounds) {
        return const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0.0, 0.85, 1.0],
        ).createShader(bounds);
      },
      blendMode: BlendMode.dstIn,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.only(left: 20, right: 40),
        child: Stack(
          alignment: Alignment.bottomLeft,
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                key: _parentKey,
                children: widget.categories.map((category) {
                  final isSelected = widget.selectedCategory == category;
                  final index = widget.categories.indexOf(category);
                  return GestureDetector(
                    key: _tabKeys[index],
                    onTap: () => widget.onCategorySelected(category),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      child: Text(
                        category,
                        style: GoogleFonts.jost(
                          fontSize: isSelected ? 15 : 14,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w300,
                          color: isSelected
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            AnimatedPositioned(
              duration: isReady ? const Duration(milliseconds: 250) : Duration.zero,
              curve: Curves.easeInOutCubic,
              left: _indicatorLeft,
              width: _indicatorWidth,
              bottom: 2,
              child: Opacity(
                opacity: isReady ? 1.0 : 0.0,
                child: Center(
                  child: Container(
                    width: 14,
                    height: 3.5,
                    decoration: BoxDecoration(
                      color: widget.highlight,
                      borderRadius: BorderRadius.circular(2),
                    ),
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

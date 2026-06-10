import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../providers/pending_jobs_provider.dart';
import '../theme/app_theme.dart';
import 'ar_view_screen.dart';
import 'upload_screen.dart';
import 'model_url_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String selectedCategory = "Chairs";

  // 기본 컬러 시스템 (유저 사양 및 기존 톤앤매너 유지)
  final Color mainDark = const Color(0xFF2A211D);     // 에스프레소 차콜
  final Color highlight = const Color(0xFFD3AD97);    // 웜 토프 베이지
  final Color bgParchment = const Color(0xFFF5F2EB);   // 파치먼트 배경색
  final Color iconBoxBg = const Color(0xFFEFEAE4).withValues(alpha: 0.4);     // 소프트 애시 베이지
  final Color secondaryText = const Color(0xFF8E847A); // 뮤트 타우프 그레이

  final List<String> baseCategories = const ["Chairs", "Sofas", "Beds", "Tables", "Lamps", "Cabinets"];
  List<String> activeCategories = ["Chairs", "Sofas", "Beds", "Tables", "Lamps", "Cabinets"];
  List<FurnitureAsset> _assets = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAssets();
  }

  Future<void> _loadAssets() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<ApiClient>();
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
          selectedCategory = activeCategories.isNotEmpty ? activeCategories[0] : "Chairs";
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
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

  bool _matchesCategory(FurnitureAsset asset, String category) {
    final normAsset = _normalizeCategory(asset.category);
    return normAsset == category;
  }

  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          '로그아웃',
          style: GoogleFonts.jost(
            fontWeight: FontWeight.w700,
            color: mainDark,
          ),
        ),
        content: Text(
          '정말 로그아웃 하시겠습니까?',
          style: GoogleFonts.jost(
            fontWeight: FontWeight.w300,
            color: secondaryText,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              '취소',
              style: GoogleFonts.jost(
                color: secondaryText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await context.read<PendingJobsProvider>().clear();
              if (!context.mounted) return;
              await context.read<ApiClient>().logout();
            },
            child: Text(
              '확인',
              style: GoogleFonts.jost(
                color: highlight,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final api = context.watch<ApiClient>();

    final currentAssets = _assets.where((asset) => _matchesCategory(asset, selectedCategory)).toList();

    // 사용자 이름 파싱 (이메일 앞자리)
    final username = api.email != null && api.email!.contains('@')
        ? api.email!.split('@')[0]
        : 'Seongyun';

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
          children: [
            // 메인 스크롤 콘텐츠
            SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Gap(4),
                    // 1. Header (아바타 및 웰컴 계정명)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "안녕하세요, $username님!",
                                style: GoogleFonts.jost(
                                  color: secondaryText, // 5. 사용자 이메일 / 웰컴: 뮤트 타우프 그레이
                                  fontSize: 14,
                                  fontWeight: FontWeight.w300,
                                ),
                              ),
                            ],
                          ),
                          GestureDetector(
                            onTap: () => _showLogoutDialog(context),
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(color: highlight.withValues(alpha: 0.5), width: 1.5),
                              ),
                              child: CircleAvatar(
                                radius: 24,
                                backgroundColor: Colors.white,
                                child: Icon(Icons.person_rounded, color: highlight, size: 24),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Gap(40),

                    // 2. 메인 타이틀 영역 (Headline: 크게 furniFit)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        'furniFit',
                        style: GoogleFonts.syne(
                          fontSize: 56, // 48에서 56으로 더 크게 확대
                          fontWeight: FontWeight.w700, // w800에서 w700으로 슬림화
                          color: mainDark,
                          letterSpacing: -1.0,
                          height: 1.1,
                        ),
                      ),
                    ),
                    const Gap(12),
                    // 3. 본문 설명 서브 텍스트
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        'AI가 가구를 분석하고 입체 모델로 만들어드려요.\n인테리어를 상상이 아닌 눈으로 확인해보세요.',
                        style: GoogleFonts.jost(
                          fontSize: 13,
                          fontWeight: FontWeight.w200,
                          color: mainDark, // 1. 본문 설명 서브 텍스트: 딥 에스프레소 차콜
                          height: 1.65,
                        ),
                      ),
                    ),

                    // 검색창 (캡슐 스타일)
                    const Gap(24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        height: 52,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFFD3AD97).withValues(alpha: 0.09),
                              const Color(0xFFDBC9A9).withValues(alpha: 0.09),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.3),
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
                            const Icon(Icons.search, color: Colors.grey, size: 22),
                            const Gap(12),
                            Text(
                              "Search your 3D models...",
                              style: GoogleFonts.jost(
                                color: mainDark.withValues(alpha: 0.4),
                                fontWeight: FontWeight.w300,
                              ),
                            ),
                            const Spacer(),
                            Icon(Icons.tune, color: highlight, size: 22),
                          ],
                        ),
                      ),
                    ),

                    // 1. 카테고리 탭 영역 (가로 스크롤 반영)
                    const Gap(66),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        "Categories",
                        style: GoogleFonts.jost(
                          fontSize: 18,
                          fontWeight: FontWeight.w400, // 얇고 감각적인 두께로 조정
                          color: mainDark,
                        ),
                      ),
                    ),
                    const Gap(10),
                    _CategoryTabs(
                      categories: activeCategories,
                      selectedCategory: selectedCategory,
                      onCategorySelected: (category) {
                        setState(() {
                          selectedCategory = category;
                        });
                      },
                      mainDark: mainDark,
                      highlight: highlight,
                      secondaryText: secondaryText,
                    ),

                    const Gap(20),

                    // 그리드 뷰 (실제 3D 가구 모델 렌더링)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _loading
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.symmetric(vertical: 60),
                                child: CircularProgressIndicator(color: AppColors.primary),
                              ),
                            )
                          : _error != null
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
                                    child: Column(
                                      children: [
                                        Text(
                                          '오류가 발생했어요:\n$_error',
                                          textAlign: TextAlign.center,
                                          style: GoogleFonts.jost(color: secondaryText),
                                        ),
                                        const Gap(12),
                                        ElevatedButton(
                                          onPressed: _loadAssets,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: highlight,
                                            foregroundColor: Colors.white,
                                            elevation: 0,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                          ),
                                          child: Text('다시 시도', style: GoogleFonts.jost(fontWeight: FontWeight.bold)),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : currentAssets.isEmpty
                                  ? Center(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
                                        child: Column(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.all(16),
                                              decoration: BoxDecoration(
                                                color: iconBoxBg,
                                                shape: BoxShape.circle,
                                              ),
                                              child: Icon(Icons.chair_outlined, color: highlight, size: 36),
                                            ),
                                            const Gap(16),
                                            Text(
                                              '아직 생성된 모델이 없어요',
                                              style: GoogleFonts.jost(
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                                color: mainDark,
                                              ),
                                            ),
                                            const Gap(6),
                                            Text(
                                              '새 가구 이미지를 업로드해서 3D 모델을 만들어보세요!',
                                              textAlign: TextAlign.center,
                                              style: GoogleFonts.jost(
                                                fontSize: 13,
                                                color: secondaryText,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                  : GridView.builder(
                                      shrinkWrap: true,
                                      physics: const NeverScrollableScrollPhysics(),
                                      padding: const EdgeInsets.only(bottom: 120),
                                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 2,
                                        mainAxisSpacing: 18,
                                        crossAxisSpacing: 18,
                                        childAspectRatio: 0.78,
                                      ),
                                      itemCount: currentAssets.length,
                                      itemBuilder: (context, index) {
                                        final asset = currentAssets[index];
                                        return _HomeAssetCard(
                                          asset: asset,
                                          mainDark: mainDark,
                                          highlight: highlight,
                                          iconBoxBg: iconBoxBg,
                                          secondaryText: secondaryText,
                                          onRefresh: _loadAssets,
                                        );
                                      },
                                    ),
                    ),
                  ],
                ),
              ),
            ),

            // 3. 중앙 정렬형 플로팅 내비게이션 바
            _buildFloatingBottomNav(),
          ],
        ),
      );
  }

  // 박물관 앱 스타일의 하단 3버튼 플로팅 도크
  Widget _buildFloatingBottomNav() {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.only(bottom: 28),
        height: 66,
        width: 240, // 3개의 버튼이 중앙에 컴팩트하게 모이도록 너비 제한
        decoration: BoxDecoration(
          color: mainDark,
          borderRadius: BorderRadius.circular(33),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 20,
              offset: const Offset(0, 10),
            )
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // 왼쪽 버튼: 홈 화면 (현재 활성화 상태로 라이트 브라운 하이라이트)
            IconButton(
              icon: const Icon(Icons.home_filled, color: Colors.white),
              onPressed: _loadAssets,
            ),
            // 가운데 버튼: 사진으로 새로운 모델 만들기 (UploadScreen 연동)
            IconButton(
              icon: Icon(Icons.document_scanner_outlined, color: highlight),
              onPressed: () => Navigator.push(
                context,
                _slide(const UploadScreen()),
              ).then((_) => _loadAssets()),
            ),
            // 오른쪽 버튼: 즉시 AR 공간 배치 진입 (ArViewScreen 연동)
            IconButton(
              icon: Icon(Icons.view_in_ar_outlined, color: Colors.white.withValues(alpha: 0.6)),
              onPressed: () => Navigator.push(
                context,
                _slide(const ArViewScreen()),
              ).then((_) => _loadAssets()),
            ),
          ],
        ),
      ),
    );
  }

  PageRouteBuilder _slide(Widget page) => PageRouteBuilder(
        pageBuilder: (context, a, secondaryAnimation) => page,
        transitionsBuilder: (context, a, secondaryAnimation, child) => SlideTransition(
          position: Tween(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 320),
      );
}

class _CategoryTabs extends StatefulWidget {
  final List<String> categories;
  final String selectedCategory;
  final ValueChanged<String> onCategorySelected;
  final Color mainDark;
  final Color highlight;
  final Color secondaryText;

  const _CategoryTabs({
    required this.categories,
    required this.selectedCategory,
    required this.onCategorySelected,
    required this.mainDark,
    required this.highlight,
    required this.secondaryText,
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
          stops: [0.0, 0.82, 1.0],
        ).createShader(bounds);
      },
      blendMode: BlendMode.dstIn,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.only(left: 24, right: 48),
        child: Stack(
          alignment: Alignment.bottomLeft,
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
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
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(
                        category,
                        style: GoogleFonts.jost(
                          fontSize: isSelected ? 16 : 15,
                          fontWeight: isSelected ? FontWeight.w500 : FontWeight.w300,
                          color: isSelected
                              ? widget.mainDark
                              : widget.secondaryText.withValues(alpha: 0.5),
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
              bottom: 4,
              child: Opacity(
                opacity: isReady ? 1.0 : 0.0,
                child: Center(
                  child: Container(
                    width: 16,
                    height: 4,
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

class _HomeAssetCard extends StatefulWidget {
  final FurnitureAsset asset;
  final Color mainDark;
  final Color highlight;
  final Color iconBoxBg;
  final Color secondaryText;
  final VoidCallback onRefresh;

  const _HomeAssetCard({
    required this.asset,
    required this.mainDark,
    required this.highlight,
    required this.iconBoxBg,
    required this.secondaryText,
    required this.onRefresh,
  });

  @override
  State<_HomeAssetCard> createState() => _HomeAssetCardState();
}

class _HomeAssetCardState extends State<_HomeAssetCard> {
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
      ).then((_) => widget.onRefresh());
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
      ).then((_) => widget.onRefresh()),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF5F2EB), // soft warm gray/parchment background
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: const Color(0xFFE5E2DB),
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
                    color: Colors.white.withValues(alpha: 0.4),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: widget.iconBoxBg,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Icon(
                          Icons.view_in_ar_outlined,
                          color: widget.highlight,
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
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.asset.displayCategory.toUpperCase(),
                    style: GoogleFonts.jost(
                      color: widget.highlight,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Gap(4),
                  Text(
                    widget.asset.displayName,
                    style: GoogleFonts.jost(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: widget.mainDark,
                    ),
                    overflow: TextOverflow.ellipsis,
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

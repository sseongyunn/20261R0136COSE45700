import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../providers/pending_jobs_provider.dart';
import '../theme/app_theme.dart';
import 'ar_view_screen.dart';
import 'gallery_screen.dart';
import 'upload_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _assetCount = 0;
  String selectedCategory = "Chairs";

  // 기본 컬러 시스템 (유저 사양 및 기존 톤앤매너 유지)
  final Color mainDark = const Color(0xFF2A211D);     // 에스프레소 차콜
  final Color highlight = const Color(0xFFD3AD97);    // 웜 토프 베이지
  final Color bgParchment = const Color(0xFFF5F2EB);   // 파치먼트 배경색
  final Color iconBoxBg = const Color(0xFFEFEAE4);     // 소프트 애시 베이지
  final Color secondaryText = const Color(0xFF8E847A); // 뮤트 타우프 그레이

  // 카테고리별 목업 데이터 세팅
  final Map<String, List<Map<String, String>>> mockupData = {
    "Chairs": [
      {"title": "Sansa Chair", "img": "https://images.unsplash.com/photo-1567538096630-e0c55bd6374c?w=500"},
      {"title": "Eames Lounge", "img": "https://images.unsplash.com/photo-1592078615290-033ee584e267?w=500"},
    ],
    "Sofas": [
      {"title": "Nordic Velvet Sofa", "img": "https://images.unsplash.com/photo-1555041469-a586c61ea9bc?w=500"},
      {"title": "Minimalist Divan", "img": "https://images.unsplash.com/photo-1484101403633-562f891dc89a?w=500"},
    ],
    "Beds": [
      {"title": "Platform Bed Frame", "img": "https://images.unsplash.com/photo-1505693416388-ac5ce068fe85?w=500"},
    ],
    "Tables": [
      {"title": "Oak Dining Table", "img": "https://images.unsplash.com/photo-1530018607912-eff2df114f11?w=500"},
      {"title": "Minimalist Desk", "img": "https://images.unsplash.com/photo-1518455027359-f3f8164ba6bd?w=500"},
    ],
    "Lamps": [
      {"title": "Brass Floor Lamp", "img": "https://images.unsplash.com/photo-1507473885765-e6ed057f782c?w=500"},
    ],
    "Cabinets": [
      {"title": "Wooden Sideboard", "img": "https://images.unsplash.com/photo-1595428774223-ef52624120d2?w=500"},
    ],
  };

  @override
  void initState() {
    super.initState();
    _loadAssetCount();
  }

  Future<void> _loadAssetCount() async {
    try {
      final assets = await context.read<ApiClient>().listFurnitureAssets();
      if (!mounted) return;
      setState(() => _assetCount = assets.length);
    } catch (_) {
      // Home remains usable even if the count request fails.
    }
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
    final runningCount = context.watch<PendingJobsProvider>().runningCount;
    final totalCount = _assetCount + runningCount;

    List<Map<String, String>> currentModels = mockupData[selectedCategory] ?? [];

    // 사용자 이름 파싱 (이메일 앞자리)
    final username = api.email != null && api.email!.contains('@')
        ? api.email!.split('@')[0]
        : 'Seongyun';

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: AuthColors.neutralGradientPreset,
        ),
        child: Stack(
          children: [
            // 메인 스크롤 콘텐츠
            SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Gap(20),
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
                    const Gap(24),

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
                          fontSize: 15,
                          fontWeight: FontWeight.w300,
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
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
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
                    const Gap(40),
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
                    const Gap(14),
                    _CategoryTabs(
                      categories: mockupData.keys.toList(),
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

                    // 2. 필터링된 모델 카드 그리드 영역
                    const Gap(16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Text(
                                "Recent Models ($selectedCategory)",
                                style: GoogleFonts.jost(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w400, // 얇고 감각적인 두께로 조정
                                  color: mainDark,
                                ),
                              ),
                              if (totalCount > 0 && selectedCategory == "Chairs") ...[
                                const Gap(8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: highlight,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    "$totalCount",
                                    style: GoogleFonts.jost(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          GestureDetector(
                            onTap: () => Navigator.push(
                              context,
                              _slide(const GalleryScreen()), // View All 클릭 시 실제 내 컬렉션 갤러리 화면 연동
                            ).then((_) => _loadAssetCount()),
                            child: Text(
                              "View All",
                              style: GoogleFonts.jost(
                                color: highlight,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Gap(16),

                    // 그리드 뷰 (비대칭 느낌의 유연한 Grid 구현)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 120), // 하단 플로팅 도크가 겹치지 않도록 스페이싱 확보
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 18,
                          crossAxisSpacing: 18,
                          childAspectRatio: 0.78,
                        ),
                        itemCount: currentModels.length,
                        itemBuilder: (context, index) {
                          var item = currentModels[index];
                          return _buildModelCard(item['title']!, item['img']!, context);
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
      ),
    );
  }

  // 3D 모델 프로젝트 카드 빌더
  Widget _buildModelCard(String title, String imageUrl, BuildContext context) {
    return GestureDetector(
      onTap: () {
        // 상세 프로젝트 조회로 넘어가는 링크로 갤러리 스크린 연결
        Navigator.push(
          context,
          _slide(const GalleryScreen()),
        ).then((_) => _loadAssetCount());
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFF1EDE6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 12,
              offset: const Offset(0, 6),
            )
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconBoxBg,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                    // ⚠️ 외부 Unsplash 이미지 로드 실패 시 미려한 기본 아이콘 박스로 예외 처리
                    errorBuilder: (context, error, stackTrace) => Center(
                      child: Icon(
                        Icons.chair_outlined,
                        color: highlight,
                        size: 36,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 14, right: 14, bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selectedCategory,
                    style: GoogleFonts.jost(
                      color: highlight,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Gap(4),
                  Text(
                    title,
                    style: GoogleFonts.jost(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: mainDark,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            )
          ],
        ),
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
              onPressed: () {},
            ),
            // 가운데 버튼: 사진으로 새로운 모델 만들기 (UploadScreen 연동)
            IconButton(
              icon: Icon(Icons.document_scanner_outlined, color: highlight),
              onPressed: () => Navigator.push(
                context,
                _slide(const UploadScreen()),
              ).then((_) => _loadAssetCount()),
            ),
            // 오른쪽 버튼: 즉시 AR 공간 배치 진입 (ArViewScreen 연동)
            IconButton(
              icon: Icon(Icons.view_in_ar_outlined, color: Colors.white.withValues(alpha: 0.6)),
              onPressed: () => Navigator.push(
                context,
                _slide(const ArViewScreen()),
              ).then((_) => _loadAssetCount()),
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

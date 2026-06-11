import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../providers/pending_jobs_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/glb_model_viewer.dart';
import 'ar_view_screen.dart';
import 'upload_screen.dart';
import 'model_url_screen.dart';
import 'gallery_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // 기본 컬러 시스템 (유저 사양 및 기존 톤앤매너 유지)
  final Color mainDark = const Color(0xFF2A211D);     // 에스프레소 차콜
  final Color highlight = const Color(0xFFD3AD97);    // 웜 토프 베이지
  final Color bgParchment = const Color(0xFFF5F2EB);   // 파치먼트 배경색
  final Color iconBoxBg = const Color(0xFFEFEAE4).withValues(alpha: 0.4);     // 소프트 애시 베이지
  final Color secondaryText = const Color(0xFF8E847A); // 뮤트 타우프 그레이

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

      setState(() {
        _assets = assets;
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

  String _getGreetingText() {
    final hour = DateTime.now().hour;
    if (hour >= 5 && hour < 12) {
      return 'Good morning';
    } else if (hour >= 12 && hour < 17) {
      return 'Good afternoon';
    } else if (hour >= 17 && hour < 22) {
      return 'Good evening';
    } else {
      return 'Good night';
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

    // Sort assets by createdAt descending (newest first), handling null cases.
    final sortedAssets = List<FurnitureAsset>.from(_assets)
      ..sort((a, b) {
        if (a.createdAt == null && b.createdAt == null) return 0;
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });

    final currentAssets = sortedAssets
        .take(10)
        .toList();

    // 사용자 이름 파싱 (이메일 앞자리)
    final username = api.email != null && api.email!.contains('@')
        ? api.email!.split('@')[0]
        : 'Seongyun';

    // 히어로 카드 높이의 1/4을 퀵 액션 버튼의 높이로 설정
    final double screenWidth = MediaQuery.of(context).size.width;
    final double heroWidth = screenWidth - 48; // padding 24 * 2
    final double heroHeight = heroWidth / 1.4;
    final double buttonHeight = heroHeight / 4;
    final double cardWidth = screenWidth * 0.25;
    // 카드의 세로 길이를 줄여 하단 플로팅 바와의 겹침을 방지하기 위해 가로세로 비율 조정 (0.78 -> 1.05)
    final double cardHeight = cardWidth / 1.05;

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
                    const Gap(2),
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
                                "${_getGreetingText()},\n$username!",
                                style: GoogleFonts.jost(
                                  color: secondaryText,
                                  fontSize: 12.5, // 14 -> 12.5 (90%)
                                  fontWeight: FontWeight.w300,
                                  height: 1.25,
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
                                border: Border.all(color: highlight.withValues(alpha: 0.5), width: 1.2),
                              ),
                              child: CircleAvatar(
                                radius: 16, // 18 -> 16 (90%)
                                backgroundColor: Colors.white,
                                child: Icon(Icons.logout_rounded, color: highlight, size: 16), // 18 -> 16 (90%)
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Gap(20), // 40 -> 20 (상단 이동)

                    // 2. 메인 타이틀 영역 (Headline: Bring furniture into your space)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        "Bring furniture \n into your space.",
                        style: GoogleFonts.outfit(
                          fontSize: 25, // 28 -> 25 (90%)
                          fontWeight: FontWeight.w800, // bold하게 w800
                          color: mainDark,
                          letterSpacing: -0.5,
                          height: 1.2,
                        ),
                      ),
                    ),
                    const Gap(8), // 12 -> 8 (상단 이동)
                    // 3. 본문 설명 서브 텍스트
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        "사진으로 가구를 3D 모델로 만들고, \n AR로 직접 배치해보세요.",
                        style: GoogleFonts.jost(
                          fontSize: 10.8, // 12 -> 10.8 (90%)
                          fontWeight: FontWeight.w300,
                          color: mainDark.withValues(alpha: 0.6), // 투명도를 높여 부드러운 톤 유지
                          height: 1.6,
                        ),
                      ),
                    ),

                    // 3. 프리미엄 히어로 카드 & AR 공간 배치 카드 세션
                    const Gap(16), // 24 -> 16 (상단 이동)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: SizedBox(
                        height: heroHeight,
                        child: GestureDetector(
                          onTap: () => Navigator.push(
                            context,
                            _slide(const UploadScreen()),
                          ).then((_) => _loadAssets()),
                          child: Container(
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFAF7F2), // 웜 베이지
                              borderRadius: BorderRadius.circular(32), // 32px의 넉넉한 둥근 모서리
                              border: Border.all(
                                color: const Color(0xFFEFEAE4), // 소프트 보더
                                width: 1.2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.015), // 극히 미세한 섀도우
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: CustomPaint(
                              painter: RoomCornerPainter(
                                mainDark: mainDark,
                                highlight: highlight,
                              ),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final cardWidth = constraints.maxWidth;
                                  final cardHeight = constraints.maxHeight;

                                  final btnWidth = cardWidth * 0.38; // 폭의 35~40% (38%)
                                  final btnHeight = cardHeight * 0.14; // 높이의 14% (추가 축소)

                                  return Row(
                                    children: [
                                      // 좌측 콘텐츠 영역 (48% 가로폭)
                                      Expanded(
                                        flex: 48,
                                        child: Padding(
                                          padding: EdgeInsets.fromLTRB(24, cardHeight * 0.08, 0, cardHeight * 0.08),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              // AI POWERED 배지
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: highlight.withValues(alpha: 0.15),
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: Text(
                                                  "AI POWERED",
                                                  style: GoogleFonts.outfit(
                                                    fontSize: cardHeight * 0.036, // 비례 크기
                                                    fontWeight: FontWeight.w800,
                                                    color: highlight,
                                                    letterSpacing: 0.6,
                                                  ),
                                                ),
                                              ),
                                              // 메인 타이틀
                                              Text(
                                                "Create a\n3D Model",
                                                style: GoogleFonts.outfit(
                                                  fontSize: cardHeight * 0.10, // 비율 크기를 0.115에서 0.10으로 축소
                                                  fontWeight: FontWeight.w500, // 볼드체(w800)를 제외한 미디엄 웨이트
                                                  color: mainDark,
                                                  height: 1.15,
                                                ),
                                              ),
                                              // 설명 문구
                                              Text(
                                                "가구 사진으로 \n3D 모델을 만들어보세요.",
                                                style: GoogleFonts.jost(
                                                  fontSize: cardHeight * 0.048, // 12.5pt 비례
                                                  fontWeight: FontWeight.w400,
                                                  color: secondaryText,
                                                  height: 1.35,
                                                ),
                                              ),
                                              // CTA 버튼
                                              SizedBox(
                                                width: btnWidth,
                                                height: btnHeight,
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    gradient: const LinearGradient(
                                                      colors: [
                                                        Color(0xFFF1A882),
                                                        Color(0xFFC66C44),
                                                      ],
                                                      begin: Alignment.topLeft,
                                                      end: Alignment.bottomRight,
                                                    ),
                                                    borderRadius: BorderRadius.circular(btnHeight / 2),
                                                  ),
                                                  child: Center(
                                                    child: Row(
                                                      mainAxisAlignment: MainAxisAlignment.center,
                                                      children: [
                                                        Text(
                                                          "사진으로 시작하기",
                                                          style: GoogleFonts.jost(
                                                            fontSize: btnHeight * 0.32, // 비례 텍스트 크기 상향 조정
                                                            fontWeight: FontWeight.w600,
                                                            color: Colors.white,
                                                          ),
                                                        ),
                                                        const Gap(3),
                                                        Icon(
                                                          Icons.arrow_forward_rounded,
                                                          color: Colors.white,
                                                          size: btnHeight * 0.38, // 비례 아이콘 크기 상향 조정
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      // 우측 비주얼 일러스트 영역 (52% 가로폭) - 3D 방 모서리 명암에 맞춰 비움
                                      const Expanded(
                                        flex: 52,
                                        child: SizedBox(),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const Gap(28),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        "Quick Actions",
                        style: GoogleFonts.jost(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: mainDark,
                        ),
                      ),
                    ),
                    const Gap(10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        children: [
                          // Left Button: AR 공간 배치
                          Expanded(
                            child: GestureDetector(
                              onTap: () => Navigator.push(
                                context,
                                _slide(const ArViewScreen()),
                              ).then((_) => _loadAssets()),
                              child: Container(
                                height: buttonHeight,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      const Color(0xFF6C63FF).withValues(alpha: 0.32),
                                      const Color(0xFF3ECFCF).withValues(alpha: 0.22),
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: const Color(0xFF6C63FF).withValues(alpha: 0.32),
                                    width: 1.0,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF6C63FF).withValues(alpha: 0.03),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Stack(
                                  children: [
                                    Positioned(
                                      right: -8,
                                      bottom: -8,
                                      child: Icon(
                                        Icons.view_in_ar_rounded,
                                        size: buttonHeight * 0.9,
                                        color: const Color(0xFF6C63FF).withValues(alpha: 0.08),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(5),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF6C63FF).withValues(alpha: 0.1),
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(
                                              Icons.view_in_ar_outlined,
                                              color: const Color(0xFF5A52E6),
                                              size: buttonHeight * 0.32,
                                            ),
                                          ),
                                          const Gap(8),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                Text(
                                                  'AR 공간 배치',
                                                  style: GoogleFonts.jost(
                                                    color: const Color(0xFF5A52E6),
                                                    fontSize: buttonHeight * 0.20,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                const Gap(2),
                                                Text(
                                                  '즉시 공간에 배치',
                                                  style: GoogleFonts.jost(
                                                    color: secondaryText,
                                                    fontSize: buttonHeight * 0.14,
                                                    fontWeight: FontWeight.w400,
                                                  ),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const Gap(12),
                          // Right Button: 내 가구 갤러리
                          Expanded(
                            child: GestureDetector(
                              onTap: () => Navigator.push(
                                context,
                                _slide(const GalleryScreen()),
                              ).then((_) => _loadAssets()),
                              child: Container(
                                height: buttonHeight,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      highlight.withValues(alpha: 0.32),
                                      highlight.withValues(alpha: 0.22),
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: highlight.withValues(alpha: 0.32),
                                    width: 1.0,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: highlight.withValues(alpha: 0.03),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Stack(
                                  children: [
                                    Positioned(
                                      right: -8,
                                      bottom: -8,
                                      child: Icon(
                                        Icons.photo_library_rounded,
                                        size: buttonHeight * 0.9,
                                        color: highlight.withValues(alpha: 0.12),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(5),
                                            decoration: BoxDecoration(
                                              color: highlight.withValues(alpha: 0.15),
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(
                                              Icons.photo_library_outlined,
                                              color: mainDark,
                                              size: buttonHeight * 0.32,
                                            ),
                                          ),
                                          const Gap(8),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                Text(
                                                  '내 가구 갤러리',
                                                  style: GoogleFonts.jost(
                                                    color: mainDark,
                                                    fontSize: buttonHeight * 0.20,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                const Gap(2),
                                                Text(
                                                  '생성 모델 전체 보기',
                                                  style: GoogleFonts.jost(
                                                    color: secondaryText,
                                                    fontSize: buttonHeight * 0.14,
                                                    fontWeight: FontWeight.w400,
                                                  ),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
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

                    // 4. Recent Assets 타이틀 영역 (높이 조율 및 카테고리 제거)
                    const Gap(24),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            "Recent Assets",
                            style: GoogleFonts.jost(
                              fontSize: 13, // Quick Actions와 동일하게 13으로 축소
                              fontWeight: FontWeight.w500, // 미세조정
                              color: mainDark,
                            ),
                          ),
                          GestureDetector(
                            onTap: () => Navigator.push(
                              context,
                              _slide(const GalleryScreen()),
                            ).then((_) => _loadAssets()),
                            child: Container(
                              color: Colors.transparent, // 투명 탭 영역 확보
                              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                              child: Text(
                                "Show all",
                                style: GoogleFonts.jost(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w400,
                                  color: highlight,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Gap(14),

                    // 가로 스크롤 뷰 (실제 3D 가구 모델 렌더링)
                    _loading
                        ? const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 24),
                            child: Center(
                              child: Padding(
                                padding: EdgeInsets.symmetric(vertical: 60),
                                child: CircularProgressIndicator(color: AppColors.primary),
                              ),
                            ),
                          )
                        : _error != null
                            ? Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24),
                                child: Center(
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
                                ),
                              )
                            : currentAssets.isEmpty
                                ? Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 24),
                                    child: Center(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
                                        child: Column(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.all(16),
                                              decoration: BoxDecoration(
                                                color: iconBoxBg,
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: Colors.white.withValues(alpha: 0.5),
                                                ),
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
                                    ),
                                  )
                                : SizedBox(
                                    height: cardHeight + 16,
                                    child: ListView.builder(
                                      scrollDirection: Axis.horizontal,
                                      padding: const EdgeInsets.symmetric(horizontal: 24),
                                      itemCount: currentAssets.length,
                                      itemBuilder: (context, index) {
                                        final asset = currentAssets[index];
                                        return Padding(
                                          padding: EdgeInsets.only(
                                            right: index == currentAssets.length - 1 ? 0 : 12,
                                          ),
                                          child: SizedBox(
                                            width: cardWidth,
                                            height: cardHeight,
                                            child: _HomeAssetCard(
                                              asset: asset,
                                              mainDark: mainDark,
                                              highlight: highlight,
                                              iconBoxBg: iconBoxBg,
                                              secondaryText: secondaryText,
                                              onRefresh: _loadAssets,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                    const Gap(120),
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
      child: Padding(
        padding: const EdgeInsets.only(bottom: 28),
        child: SizedBox(
          width: 260, // 너비를 더 컴팩트하게 줄임 (300 -> 260)
          height: 72, // 전체 돌출 높이 축소 (82 -> 72)
          child: Stack(
            alignment: Alignment.bottomCenter,
            children: [
              // White pill container
              Container(
                height: 56, // 바의 높이 축소 (64 -> 56)
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    )
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Left: Home
                    Expanded(
                      child: GestureDetector(
                        onTap: _loadAssets,
                        behavior: HitTestBehavior.opaque,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.home_rounded, color: highlight, size: 22), // 24 -> 22
                            const Gap(2),
                            Text(
                              "Home",
                              style: GoogleFonts.jost(
                                color: highlight,
                                fontSize: 11, // 12.5 -> 11
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Center space for overlapping button
                    const SizedBox(width: 64), // 76 -> 64
                    // Right: AR Space
                    Expanded(
                      child: GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          _slide(const ArViewScreen()),
                        ).then((_) => _loadAssets()),
                        behavior: HitTestBehavior.opaque,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.view_in_ar_outlined, color: secondaryText, size: 22), // 24 -> 22
                            const Gap(2),
                            Text(
                              "AR Space",
                              style: GoogleFonts.jost(
                                color: secondaryText,
                                fontSize: 11, // 12.5 -> 11
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              
              // Center Floating Action Button & Text
              Positioned(
                top: 0,
                child: GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    _slide(const UploadScreen()),
                  ).then((_) => _loadAssets()),
                  behavior: HitTestBehavior.opaque,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 48, // 54 -> 48
                        height: 48,
                        decoration: BoxDecoration(
                          color: highlight,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: highlight.withValues(alpha: 0.4),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.add_rounded,
                          color: Colors.white,
                          size: 26, // 30 -> 26
                        ),
                      ),
                      const Gap(2),
                      Text(
                        "Create",
                        style: GoogleFonts.jost(
                          color: mainDark,
                          fontSize: 11, // 12.5 -> 11
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
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
  late Future<String> _modelUrlFuture;
  String? _modelUrl;

  @override
  void initState() {
    super.initState();
    _modelUrlFuture = _loadModelUrl();
  }

  @override
  void didUpdateWidget(covariant _HomeAssetCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.assetId != widget.asset.assetId) {
      _modelUrl = null;
      _modelUrlFuture = _loadModelUrl();
    }
  }

  Future<String> _loadModelUrl() async {
    final url = await context.read<ApiClient>().getModelUrl(widget.asset.assetId);
    _modelUrl = url;
    return url;
  }

  Future<void> _openAR() async {
    if (_openingAR) return;
    setState(() => _openingAR = true);
    try {
      final url = _modelUrl ?? await _modelUrlFuture;
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
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: const Color(0xFFE5E2DB),
            width: 0.8,
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
                    child: _HomeAssetModelPreview(
                      modelUrlFuture: _modelUrlFuture,
                      fallbackColor: widget.highlight,
                      fallbackBackgroundColor: widget.iconBoxBg,
                    ),
                  ),
                  // AR 버튼 오버레이
                  Positioned(
                    top: 4,
                    right: 4,
                    child: GestureDetector(
                      onTap: _openAR,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF6C63FF), Color(0xFF3ECFCF)],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                          borderRadius: BorderRadius.circular(6),
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
                                width: 8,
                                height: 8,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: Colors.white,
                                ),
                              )
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 8),
                                  const Gap(2),
                                  Text(
                                    'AR',
                                    style: GoogleFonts.outfit(
                                      fontSize: 7.5,
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
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.asset.displayCategory.toUpperCase(),
                    style: GoogleFonts.jost(
                      color: widget.highlight,
                      fontSize: 7,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Gap(2),
                  Text(
                    widget.asset.displayName,
                    style: GoogleFonts.jost(
                      fontSize: 9,
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

class _HomeAssetModelPreview extends StatelessWidget {
  final Future<String> modelUrlFuture;
  final Color fallbackColor;
  final Color fallbackBackgroundColor;

  const _HomeAssetModelPreview({
    required this.modelUrlFuture,
    required this.fallbackColor,
    required this.fallbackBackgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: modelUrlFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: fallbackColor,
              ),
            ),
          );
        }

        if (!snapshot.hasData || snapshot.hasError) {
          return _HomeAssetPreviewFallback(
            color: fallbackColor,
            backgroundColor: fallbackBackgroundColor,
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            return GlbModelViewer(
              modelUrl: snapshot.data!,
              height: constraints.maxHeight,
              backgroundColor: Colors.transparent,
              ar: false,
              autoRotate: false,
              cameraControls: false,
              cameraOrbit: '0deg 75deg 105%',
              fieldOfView: '30deg',
              borderRadius: 0,
              loadingLabel: '',
              errorLabel: '',
            );
          },
        );
      },
    );
  }
}

class _HomeAssetPreviewFallback extends StatelessWidget {
  final Color color;
  final Color backgroundColor;

  const _HomeAssetPreviewFallback({
    required this.color,
    required this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: backgroundColor,
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
        child: Icon(
          Icons.view_in_ar_outlined,
          color: color,
          size: 16,
        ),
      ),
    );
  }
}

class RoomCornerPainter extends CustomPainter {
  final Color mainDark;
  final Color highlight;

  RoomCornerPainter({
    required this.mainDark,
    required this.highlight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. 원점 (0,0,0) - 카드 너비의 63% 지점 (X = size.width * 0.63), 높이의 35% 지점 (Y = size.height * 0.65)
    final double x0 = size.width * 0.63;
    final double y0 = size.height * 0.65;
    final Offset origin = Offset(x0, y0);

    // 대각선이 좌우 경계면에 닿는 Y 좌표
    final double yLeftEnd = size.height * 0.85;
    final double yRightEnd = size.height * 0.85;

    final Offset leftEnd = Offset(0, yLeftEnd);
    final Offset rightEnd = Offset(size.width, yRightEnd);

    // 2. 각 영역의 Path 정의
    // 좌측 벽면 (Left Wall)
    final Path leftWallPath = Path()
      ..moveTo(x0, y0)
      ..lineTo(x0, 0)
      ..lineTo(0, 0)
      ..lineTo(0, yLeftEnd)
      ..close();

    // 우측 벽면 (Right Wall)
    final Path rightWallPath = Path()
      ..moveTo(x0, y0)
      ..lineTo(x0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, yRightEnd)
      ..close();

    // 바닥면 (Floor)
    final Path floorPath = Path()
      ..moveTo(x0, y0)
      ..lineTo(0, yLeftEnd)
      ..lineTo(0, size.height)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width, yRightEnd)
      ..close();

    // 3. 좌측 벽면 채색 (밝은 조명 워시 효과: white.withValues(alpha: 0.6) ~ 0.1)
    // 원점(Alignment(0.26, 0.3))으로 향하는 선형 그라디언트
    final Rect fullRect = Rect.fromLTWH(0, 0, size.width, size.height);
    final Paint leftWallPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: const Alignment(0.26, 0.3),
        colors: [
          Colors.white.withValues(alpha: 0.6),
          Colors.white.withValues(alpha: 0.1),
        ],
      ).createShader(fullRect);
    canvas.drawPath(leftWallPath, leftWallPaint);

    // 4. 우측 벽면 채색 (소프트 웜 그림자 효과: highlight.withValues(alpha: 0.24) ~ 0.0)
    // 원점(Alignment(0.26, 0.3))으로 향하는 선형 그라디언트
    final Paint rightWallPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topRight,
        end: const Alignment(0.26, 0.3),
        colors: [
          highlight.withValues(alpha: 0.24),
          highlight.withValues(alpha: 0.0),
        ],
      ).createShader(fullRect);
    canvas.drawPath(rightWallPath, rightWallPaint);

    // 5. 바닥면 채색 (앰비언트 오클루전 그림자 효과: mainDark.withValues(alpha: 0.09) ~ 0.0 방사형 그라디언트)
    final double floorRadius = size.width * 0.6;
    final Rect floorRect = Rect.fromCircle(center: origin, radius: floorRadius);
    final Paint floorPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          mainDark.withValues(alpha: 0.09),
          mainDark.withValues(alpha: 0.0),
        ],
      ).createShader(floorRect);
    canvas.drawPath(floorPath, floorPaint);

    // 6. 세 축의 차분한 경계선 그리기 (mainDark.withValues(alpha: 0.04))
    final Paint linePaint = Paint()
      ..color = mainDark.withValues(alpha: 0.04)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // 수직 모서리선
    canvas.drawLine(origin, Offset(x0, 0), linePaint);
    // 좌측 대각선
    canvas.drawLine(origin, leftEnd, linePaint);
    // 우측 대각선
    canvas.drawLine(origin, rightEnd, linePaint);
  }

  @override
  bool shouldRepaint(covariant RoomCornerPainter oldDelegate) {
    return oldDelegate.mainDark != mainDark || oldDelegate.highlight != highlight;
  }
}

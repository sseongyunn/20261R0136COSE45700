import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../theme/app_theme.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignup = false;
  bool _rememberMe = false;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = '이메일과 비밀번호를 입력해주세요.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final api = context.read<ApiClient>();
      if (_isSignup) {
        await api.signup(email, password);
      } else {
        await api.login(email, password);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: AuthColors.radialGradientPreset, // 1. 은은한 베이지~그레이/화이트 radial gradient
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28), // 1. 좌우 여백 (28dp)
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, // 1. 좌측 정렬 중심
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Gap(16),
                    const _Logo(),
                    Gap(height * 0.10), // 2. 타이틀 위치: 상단 약 1/4 지점
                    Text(
                      _isSignup ? 'Create\nyour account' : 'Log into\nyour account',
                      style: GoogleFonts.outfit(
                        fontSize: 40,
                        fontWeight: FontWeight.w200, // 미니멀한 얇고 감각적인 두께
                        color: Colors.white,
                        height: 1.15,
                      ),
                    ),
                    const Gap(80),
                    // 3. Username/Email 입력 필드 (Underline 스타일)
                    _UnderlineInput(
                      controller: _emailController,
                      hintText: 'Username/Email',
                      icon: Icons.mail_outline_rounded,
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const Gap(20),
                    // 3. Password 입력 필드 (Underline 스타일) & Forgot? 버튼 Baseline 배치
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: _UnderlineInput(
                            controller: _passwordController,
                            hintText: 'Password',
                            icon: Icons.lock_outline_rounded,
                            obscureText: true,
                          ),
                        ),
                        if (!_isSignup) ...[
                          TextButton(
                            onPressed: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('비밀번호 찾기 기능은 아직 지원되지 않습니다.'),
                                ),
                              );
                            },
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              'Forgot?',
                              style: GoogleFonts.outfit(
                                color: Colors.white70,
                                fontWeight: FontWeight.w300,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const Gap(24),
                    // 3. 옵션 영역 (Remember me)
                    if (!_isSignup) ...[
                      Row(
                        children: [
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _rememberMe = !_rememberMe;
                              });
                            },
                            child: Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(4), // 모서리가 살짝 둥근 사각
                              ),
                              child: _rememberMe
                                  ? const Icon(
                                      Icons.check,
                                      size: 14,
                                      color: Color(0xFF6E5F4F),
                                    )
                                  : null,
                            ),
                          ),
                          const Gap(8),
                          Text(
                            'Remember me',
                            style: GoogleFonts.outfit(
                              fontSize: 14,
                              fontWeight: FontWeight.w300,
                              color: Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (_error != null) ...[
                      const Gap(16),
                      _ErrorBox(message: _error!),
                    ],
                    const Gap(40),
                    // 4. 기본 로그인 버튼 (Log In/Sign Up, Capsule/Pill-shaped, Charcoal, Drop Shadow)
                    GestureDetector(
                      onTap: _loading ? null : _submit,
                      child: Container(
                        height: 54,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: AuthColors.charcoalButton, // #2A2A2E 내외
                          borderRadius: BorderRadius.circular(27), // 캡슐 형태
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 12,
                              offset: const Offset(0, 6), // 부드럽고 은은한 드롭 섀도우
                            ),
                          ],
                        ),
                        child: Center(
                          child: _loading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  _isSignup ? 'Sign Up' : 'Log In',
                                  style: GoogleFonts.outfit(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
                // 5. 하단 푸터 (Don't have an account? Sign Up, 좌측 정렬, 밑줄)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Gap(24),
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () => setState(() {
                                _isSignup = !_isSignup;
                                _error = null;
                              }),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        alignment: Alignment.centerLeft,
                      ),
                      child: RichText(
                        text: TextSpan(
                          style: GoogleFonts.outfit(
                            fontSize: 14,
                            fontWeight: FontWeight.w300,
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                          children: [
                            TextSpan(
                              text: _isSignup
                                  ? 'Already have an account? '
                                  : "Don't have an account? ",
                            ),
                            TextSpan(
                              text: _isSignup ? 'Log In' : 'Sign Up',
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                                decoration: TextDecoration.underline,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Gap(16),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(
          Icons.chair_outlined,
          color: Colors.white,
          size: 24,
        ),
        const Gap(8),
        Text(
          'furniFit',
          style: GoogleFonts.outfit(
            fontSize: 20,
            fontWeight: FontWeight.w400,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

class _UnderlineInput extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final IconData icon;
  final bool obscureText;
  final TextInputType? keyboardType;

  const _UnderlineInput({
    required this.controller,
    required this.hintText,
    required this.icon,
    this.obscureText = false,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.w300, color: Colors.white),
      cursorColor: Colors.white,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: GoogleFonts.outfit(
          color: Colors.white.withValues(alpha: 0.6),
          fontWeight: FontWeight.w300,
        ),
        prefixIcon: Icon(icon, color: Colors.white70, size: 20),
        filled: false, // 채우기 없이
        enabledBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: Colors.white38, width: 1.0), // 반투명 화이트 밑줄
        ),
        focusedBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: Colors.white, width: 1.5),
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;

  const _ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x2BFFB8A8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white38),
      ),
      child: Text(
        message,
        style: GoogleFonts.outfit(
          fontSize: 13,
          fontWeight: FontWeight.w300,
          color: Colors.white,
          height: 1.4,
        ),
      ),
    );
  }
}

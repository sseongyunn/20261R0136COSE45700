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
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight:
                  MediaQuery.sizeOf(context).height -
                  MediaQuery.paddingOf(context).top -
                  MediaQuery.paddingOf(context).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Gap(28),
                const _Logo(),
                const Gap(72),
                Text(
                  _isSignup ? '계정을 만들고\n3D 생성을 시작하세요' : '로그인하고\n내 모델을 확인하세요',
                  style: GoogleFonts.nunito(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                    height: 1.2,
                  ),
                ),
                const Gap(14),
                Text(
                  '사진 업로드부터 GLB 다운로드 URL까지\n한 흐름으로 관리합니다.',
                  style: GoogleFonts.nunito(
                    fontSize: 15,
                    color: AppColors.textSecondary,
                    height: 1.55,
                  ),
                ),
                const Gap(34),
                _AuthCard(
                  emailController: _emailController,
                  passwordController: _passwordController,
                  loading: _loading,
                  isSignup: _isSignup,
                  error: _error,
                  onSubmit: _submit,
                  onToggle: () => setState(() {
                    _isSignup = !_isSignup;
                    _error = null;
                  }),
                ),
                const Gap(24),
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
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: const Icon(
            Icons.chair_outlined,
            color: AppColors.primary,
            size: 20,
          ),
        ),
        const Gap(10),
        Text(
          'Furni3D',
          style: GoogleFonts.nunito(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _AuthCard extends StatelessWidget {
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final bool loading;
  final bool isSignup;
  final String? error;
  final VoidCallback onSubmit;
  final VoidCallback onToggle;

  const _AuthCard({
    required this.emailController,
    required this.passwordController,
    required this.loading,
    required this.isSignup,
    required this.error,
    required this.onSubmit,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          _TextInput(
            controller: emailController,
            label: '이메일',
            icon: Icons.mail_outline_rounded,
            keyboardType: TextInputType.emailAddress,
          ),
          const Gap(12),
          _TextInput(
            controller: passwordController,
            label: '비밀번호',
            icon: Icons.lock_outline_rounded,
            obscureText: true,
          ),
          if (error != null) ...[const Gap(14), _ErrorBox(message: error!)],
          const Gap(18),
          GestureDetector(
            onTap: loading ? null : onSubmit,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              height: 56,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primary, AppColors.accent],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Center(
                child: loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        isSignup ? '가입하기' : '로그인',
                        style: GoogleFonts.nunito(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ),
          const Gap(12),
          TextButton(
            onPressed: loading ? null : onToggle,
            child: Text(
              isSignup ? '이미 계정이 있나요? 로그인' : '처음이신가요? 계정 만들기',
              style: GoogleFonts.nunito(
                fontSize: 14,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TextInput extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscureText;
  final TextInputType? keyboardType;

  const _TextInput({
    required this.controller,
    required this.label,
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
      style: GoogleFonts.nunito(fontSize: 15, color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.nunito(color: AppColors.textTertiary),
        prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 20),
        filled: true,
        fillColor: AppColors.surface,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.primary),
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
        color: const Color(0xFF3A1D1D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF693131)),
      ),
      child: Text(
        message,
        style: GoogleFonts.nunito(
          fontSize: 13,
          color: const Color(0xFFFFB8A8),
          height: 1.4,
        ),
      ),
    );
  }
}

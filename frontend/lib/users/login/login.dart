import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

final _dio = Dio(
  BaseOptions(
    baseUrl: 'http://localhost:8000',
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
    headers: {'Content-Type': 'application/json'},
  ),
);

// Secure Storage — final bukan const agar tidak crash di web
final _storage = FlutterSecureStorage(
  aOptions: const AndroidOptions(encryptedSharedPreferences: true),
  webOptions: const WebOptions(
    dbName: 'agribot_secure',
    publicKey: 'agribot_key',
  ),
);

// ---------------------------------------------------------------------------
// Warna & konstanta
// ---------------------------------------------------------------------------

const _bg       = Color(0xFF020202);
const _neon     = Color(0xFF16DB65);
const _neonDim  = Color(0x3316DB65);
const _surface  = Color(0xFF0D0D0D);
const _border   = Color(0xFF16DB65);
const _textMuted = Color(0xFFA3A3A3);

// ---------------------------------------------------------------------------
// LoginPage
// ---------------------------------------------------------------------------

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();

  final _identifierController = TextEditingController();
  final _passwordController   = TextEditingController();

  bool _obscurePassword = true;
  bool _isLoading       = false;

  late final AnimationController _fadeController;
  late final Animation<double>   _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _fadeController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _identifierController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // ── Hit API login ──────────────────────────────────────────────────────────

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    try {
      final response = await _dio.post(
        '/users/login',
        data: {
          'identifier': _identifierController.text.trim(),
          'password'  : _passwordController.text,
        },
      );

      if (response.statusCode == 200 && mounted) {
        final data = response.data['data'] as Map<String, dynamic>;

        // Tulis sequential — IndexedDB web tidak support concurrent writes
        await _storage.write(key: 'access_token',  value: data['access_token']  as String);
        await _storage.write(key: 'refresh_token', value: data['refresh_token'] as String);
        await _storage.write(key: 'user_id',       value: (data['user_id'] as int).toString());

        if (!mounted) return;
        context.go('/chats');
      }
    } on DioException catch (e) {
      if (!mounted) return;
      String message = 'Terjadi kesalahan. Coba lagi.';
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        message = 'Koneksi timeout. Periksa jaringan kamu.';
      } else if (e.response?.data['detail'] != null) {
        message = e.response!.data['detail'].toString();
      }
      _showErrorSnackbar(message);
    } catch (_) {
      if (mounted) _showErrorSnackbar('Terjadi kesalahan tidak terduga.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showErrorSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: GoogleFonts.poppins(fontSize: 13, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF1A1A1A),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFFFF4D4D), width: 1),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Logo ──────────────────────────────────────────────────
                  _Logo(),
                  const SizedBox(height: 40),

                  // ── Heading ───────────────────────────────────────────────
                  Text(
                    'Masuk',
                    style: GoogleFonts.poppins(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Selamat datang kembali di AgriBot.',
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      color: _textMuted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 36),

                  // ── Fields ────────────────────────────────────────────────
                  _NeonField(
                    controller: _identifierController,
                    label: 'Username atau Email',
                    hint: '@johndoe atau johndoe@email.com',
                    icon: Icons.alternate_email_rounded,
                    validator: (v) {
                      if (v == null || v.isEmpty) {
                        return 'Username atau email tidak boleh kosong';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),

                  _NeonField(
                    controller: _passwordController,
                    label: 'Password',
                    hint: '••••••••',
                    icon: Icons.lock_outline_rounded,
                    obscureText: _obscurePassword,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        color: _neon,
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Password tidak boleh kosong';
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),

                  // ── Lupa Password anchor ───────────────────────────────────
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () => context.push('/users/forgot-password'),
                      child: Text(
                        'Lupa password?',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: _neon,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // ── Submit button ──────────────────────────────────────────
                  _NeonButton(
                    label: 'Masuk',
                    isLoading: _isLoading,
                    onPressed: _handleLogin,
                  ),
                  const SizedBox(height: 28),

                  // ── Belum punya akun ───────────────────────────────────────
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Belum punya akun? ',
                          style: GoogleFonts.poppins(
                            fontSize: 13,
                            color: _textMuted,
                          ),
                        ),
                        GestureDetector(
                          onTap: () => context.push('/users/register'),
                          child: Text(
                            'Daftar sekarang',
                            style: GoogleFonts.poppins(
                              fontSize: 13,
                              color: _neon,
                              fontWeight: FontWeight.w600,
                            ),
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
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Logo widget
// ---------------------------------------------------------------------------

class _Logo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: _neonDim,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: _neon.withOpacity(0.35),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Center(
            child: Text('🌿', style: TextStyle(fontSize: 26)),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'AgriBot',
          style: GoogleFonts.poppins(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Neon TextField
// ---------------------------------------------------------------------------

class _NeonField extends StatefulWidget {
  const _NeonField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.obscureText = false,
    this.keyboardType,
    this.suffixIcon,
    this.validator,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final Widget? suffixIcon;
  final String? Function(String?)? validator;

  @override
  State<_NeonField> createState() => _NeonFieldState();
}

class _NeonFieldState extends State<_NeonField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: GoogleFonts.poppins(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: _focused ? _neon : _textMuted,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 8),
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: _neon.withOpacity(0.25),
                      blurRadius: 16,
                      spreadRadius: 0,
                    ),
                  ]
                : [],
          ),
          child: Focus(
            onFocusChange: (f) { if (mounted) setState(() => _focused = f); },
            child: TextFormField(
              controller: widget.controller,
              obscureText: widget.obscureText,
              keyboardType: widget.keyboardType,
              validator: widget.validator,
              style: GoogleFonts.poppins(
                fontSize: 14,
                color: _neon,
                fontWeight: FontWeight.w500,
              ),
              cursorColor: _neon,
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: GoogleFonts.poppins(
                  fontSize: 14,
                  color: _textMuted,
                ),
                prefixIcon: Icon(
                  widget.icon,
                  color: _focused ? _neon : _textMuted,
                  size: 20,
                ),
                suffixIcon: widget.suffixIcon,
                filled: true,
                fillColor: _surface,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF1A1A1A), width: 1.5),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _border, width: 1.5),
                ),
                errorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.red.shade700, width: 1.5),
                ),
                focusedErrorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.red.shade700, width: 1.5),
                ),
                errorStyle: GoogleFonts.poppins(
                  fontSize: 11,
                  color: Colors.red.shade400,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Neon Button
// ---------------------------------------------------------------------------

class _NeonButton extends StatelessWidget {
  const _NeonButton({
    required this.label,
    required this.onPressed,
    this.isLoading = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: _neon.withOpacity(0.35),
              blurRadius: 20,
              spreadRadius: 0,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ElevatedButton(
          onPressed: isLoading ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: _neon,
            disabledBackgroundColor: _neon.withOpacity(0.5),
            foregroundColor: Colors.black,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: isLoading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.black,
                  ),
                )
              : Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.black,
                    letterSpacing: 0.3,
                  ),
                ),
        ),
      ),
    );
  }
}
import 'package:flutter/material.dart';
import 'package:frontend/users/register/register.dart';
import 'package:frontend/users/register/verify_otp.dart';
import 'package:go_router/go_router.dart';

void main() {
  runApp(const MyApp());
}

// ---------------------------------------------------------------------------
// Dummy pages — ganti dengan import page asli nanti
// ---------------------------------------------------------------------------

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});
  @override
  Widget build(BuildContext context) =>
      _DummyPage(title: 'Login', path: '/users/login');
}

class ForgotPasswordPage extends StatelessWidget {
  const ForgotPasswordPage({super.key});
  @override
  Widget build(BuildContext context) =>
      _DummyPage(title: 'Forgot Password', path: '/forgot-password');
}

class ForgotPasswordVerifyOtpPage extends StatelessWidget {
  const ForgotPasswordVerifyOtpPage({super.key});
  @override
  Widget build(BuildContext context) => _DummyPage(
    title: 'Forgot Password – Verify OTP',
    path: '/forgot-password/verify-otp',
  );
}

class ResetPasswordPage extends StatelessWidget {
  const ResetPasswordPage({super.key});
  @override
  Widget build(BuildContext context) =>
      _DummyPage(title: 'Reset Password', path: '/reset-password');
}

class ChatsPage extends StatelessWidget {
  const ChatsPage({super.key});
  @override
  Widget build(BuildContext context) =>
      _DummyPage(title: 'Chats', path: '/chats');
}

// Widget dummy generik — hapus setelah page asli siap
class _DummyPage extends StatelessWidget {
  const _DummyPage({required this.title, required this.path});
  final String title;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(
              path,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

final GoRouter _router = GoRouter(
  initialLocation: '/users/register',
  routes: [
    // Auth – Register
    GoRoute(
      path: '/users/register',
      builder: (context, state) => const RegisterPage(),
      routes: [
        GoRoute(
          path: 'verify-otp', // resolves to /register/verify-otp
          builder: (context, state) {
            final email = state.uri.queryParameters['email'] ?? '';
            return RegisterVerifyOtpPage(email: email);
          },
        ),
      ],
    ),

    // Auth – Login
    GoRoute(
      path: '/users/login',
      builder: (context, state) => const LoginPage(),
    ),

    // Auth – Forgot Password
    GoRoute(
      path: '/users/forgot-password',
      builder: (context, state) => const ForgotPasswordPage(),
      routes: [
        GoRoute(
          path: 'verify-otp', // resolves to /forgot-password/verify-otp
          builder: (context, state) => const ForgotPasswordVerifyOtpPage(),
        ),
      ],
    ),

    // Auth – Reset Password
    GoRoute(
      path: '/users/reset-password',
      builder: (context, state) => const ResetPasswordPage(),
    ),

    // Main
    GoRoute(path: '/chats', builder: (context, state) => const ChatsPage()),
  ],
);

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'My App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      routerConfig: _router,
    );
  }
}

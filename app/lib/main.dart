import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_services.dart';
import 'auth/auth_service.dart';
import 'auth/email_link_landing.dart';
import 'auth/otp_verification_screen.dart';
import 'auth/set_new_password_screen.dart';
import 'auth/sign_in_screen.dart';
import 'screens/shell_screen.dart';
import 'supabase_config.dart';
import 'theme.dart';

/// If the app was opened by clicking an emailed auth link, which kind.
/// Read from the URL *before* `Supabase.initialize` consumes the tokens.
EmailLinkType? _openedFromEmailLink;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    _openedFromEmailLink = parseEmailLinkType(Uri.base.fragment);
  }
  await Supabase.initialize(
    url: supabaseUrl,
    publishableKey: supabasePublishableKey,
  );
  runApp(const BurhanApp());
}

class BurhanApp extends StatefulWidget {
  /// Tests inject an already-open (FFI) database *and* skip auth entirely
  /// -- production (this field null) requires sign-in + an email second
  /// step before opening the on-device database.
  final AppServices? services;

  const BurhanApp({super.key, this.services});

  @override
  State<BurhanApp> createState() => _BurhanAppState();
}

class _BurhanAppState extends State<BurhanApp> {
  // `late`, not `final`: in test mode (widget.services != null) build()
  // returns before this is ever read, so it must not construct eagerly --
  // AuthService() touches Supabase.instance, which tests never initialize.
  late final _authService = AuthService();
  Future<AppServices>? _servicesFuture;

  /// Set once the landing link (if any) has been acted on, so a rebuild
  /// doesn't re-apply it.
  bool _landingHandled = false;
  bool _needsNewPassword = false;

  /// A confirmation or magic link clicked from the inbox is proof of inbox
  /// access -- the same thing typing the OTP code proves -- so it satisfies
  /// the second step. A recovery link additionally routes to the
  /// set-new-password screen first.
  Future<void> _handleEmailLanding(User user) async {
    if (_landingHandled) return;
    _landingHandled = true;
    final type = _openedFromEmailLink;
    if (type == null) return;
    await _authService.markMfaVerified(user.id);
    if (type == EmailLinkType.recovery) _needsNewPassword = true;
    if (mounted) setState(() {});
  }

  /// Every branch below returns its OWN complete `MaterialApp` (or, once
  /// fully authenticated, `AppScope` wrapping one). That's deliberate, not
  /// duplication: `AppScope` must be an ancestor of the `Navigator` that
  /// owns pushed routes, so it can only ever wrap the outermost
  /// `MaterialApp` of the branch the user is actually in -- never nested
  /// one level inside it. Auth-state changes swap the whole subtree, so
  /// there is never a stray `MaterialApp` sitting *below* `AppScope`.
  @override
  Widget build(BuildContext context) {
    final theme = buildAppTheme();

    if (widget.services != null) {
      return AppScope(
        services: widget.services!,
        child: MaterialApp(
          title: 'Burhan Rent-A-Car',
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: const ShellScreen(),
        ),
      );
    }

    return StreamBuilder<AuthState>(
      stream: _authService.onAuthStateChange,
      initialData: AuthState(
        AuthChangeEvent.initialSession,
        _authService.currentSession,
      ),
      builder: (context, snapshot) {
        final session =
            snapshot.data?.session ?? _authService.currentSession;
        final user = session?.user;

        if (user == null) {
          return _bareApp(
            theme,
            SignInScreen(authService: _authService),
          );
        }

        if (!_landingHandled && _openedFromEmailLink != null) {
          _handleEmailLanding(user);
          return _bareApp(theme, const _Loading());
        }

        if (_needsNewPassword) {
          return _bareApp(
            theme,
            SetNewPasswordScreen(
              authService: _authService,
              onDone: () => setState(() => _needsNewPassword = false),
            ),
          );
        }

        return FutureBuilder<bool>(
          key: ValueKey('mfa-${user.id}'),
          future: _authService.isMfaVerified(user.id),
          builder: (context, mfaSnapshot) {
            if (!mfaSnapshot.hasData) {
              return _bareApp(theme, const _Loading());
            }
            if (mfaSnapshot.data != true) {
              return _bareApp(
                theme,
                OtpVerificationScreen(
                  authService: _authService,
                  email: user.email ?? '',
                  onVerified: () => setState(() {}),
                ),
              );
            }

            _servicesFuture ??= AppServices.bootstrap();
            return FutureBuilder<AppServices>(
              future: _servicesFuture,
              builder: (context, svcSnapshot) {
                if (svcSnapshot.hasError) {
                  return _bareApp(
                    theme,
                    _ErrorMessage(
                      'Could not open the database:\n${svcSnapshot.error}',
                    ),
                  );
                }
                if (!svcSnapshot.hasData) {
                  return _bareApp(theme, const _Loading());
                }
                return AppScope(
                  services: svcSnapshot.data!,
                  child: MaterialApp(
                    title: 'Burhan Rent-A-Car',
                    debugShowCheckedModeBanner: false,
                    theme: theme,
                    home: const ShellScreen(),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _bareApp(ThemeData theme, Widget home) {
    return MaterialApp(
      title: 'Burhan Rent-A-Car',
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: home,
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _ErrorMessage extends StatelessWidget {
  final String message;

  const _ErrorMessage(this.message);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message),
        ),
      ),
    );
  }
}

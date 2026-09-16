import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_services.dart';
import 'auth/auth_service.dart';
import 'auth/biometric_service.dart';
import 'auth/email_link_landing.dart';
import 'auth/enable_biometric_screen.dart';
import 'auth/lock_screen.dart';
import 'auth/secure_session_storage.dart';
import 'auth/set_new_password_screen.dart';
import 'auth/sign_in_screen.dart';
import 'screens/shell_screen.dart';
import 'sync/cloud_sync_engine.dart';
import 'sync/sync_actions.dart';
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
    authOptions: FlutterAuthClientOptions(
      // On a phone the session is kept in the Keystore so fingerprint/face
      // can unlock it on the next launch (see _BurhanAppState). On the web
      // there is no biometric unlock, so nothing is persisted and every
      // load asks for the password.
      localStorage: kIsWeb ? const EmptyLocalStorage() : SecureSessionStorage(),
    ),
  );
  runApp(const BurhanApp());
}

class BurhanApp extends StatefulWidget {
  /// Tests inject an already-open (FFI) database *and* skip auth entirely
  /// -- production (this field null) requires sign-in before opening the
  /// on-device database.
  final AppServices? services;

  const BurhanApp({super.key, this.services});

  @override
  State<BurhanApp> createState() => _BurhanAppState();
}

class _BurhanAppState extends State<BurhanApp> {
  // `late`, not `final`: in test mode (widget.services != null) these are
  // never read, so they must not construct eagerly -- AuthService() touches
  // Supabase.instance, which tests never initialize.
  late final _authService = AuthService();
  late final BiometricService _biometrics = DeviceBiometricService();
  Future<AppServices>? _servicesFuture;
  StreamSubscription<AuthState>? _authSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _cloudSyncStarted = false;

  /// True once the owner has proven who they are *this launch* -- by typing
  /// the password, or by passing the biometric lock. A session restored
  /// from storage starts locked; it never opens the app on its own.
  bool _unlocked = false;

  /// Set after a password sign-in until the "turn on fingerprint?" question
  /// has been answered (or skipped because it doesn't apply).
  bool _offerPending = false;

  /// Set once the landing link (if any) has been acted on, so a rebuild
  /// doesn't re-apply it.
  bool _landingHandled = false;
  bool _needsNewPassword = false;

  /// Guards the one-shot discard of a restored session when biometric
  /// unlock is off.
  bool _discarding = false;

  @override
  void initState() {
    super.initState();
    if (widget.services != null) return;
    _authSub = _authService.onAuthStateChange.listen((state) {
      if (!mounted) return;
      setState(() {
        switch (state.event) {
          case AuthChangeEvent.signedIn:
            _unlocked = true;
            _offerPending = true;
          case AuthChangeEvent.signedOut:
            _unlocked = false;
            _offerPending = false;
            _discarding = false;
            _cloudSyncStarted = false;
            _connectivitySub?.cancel();
            _connectivitySub = null;
          default:
            break;
        }
      });
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _connectivitySub?.cancel();
    super.dispose();
  }

  /// Starts talking to Postgres once the owner is fully signed in and the
  /// local database is open: one sync right away (so another device's
  /// changes show up without a manual tap), then again whenever the
  /// connection comes back. Everything else keeps reading/writing local
  /// SQLite regardless of whether this has run yet.
  void _startCloudSync(AppServices services) {
    if (_cloudSyncStarted) return;
    _cloudSyncStarted = true;
    final engine = CloudSyncEngine(
      client: Supabase.instance.client,
      db: services.db,
    );
    services.cloudSync = engine;
    runSync(services);
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        runSync(services);
      }
    });
  }

  /// Only a recovery link changes the flow: it routes to the
  /// set-new-password screen. Confirmation links just land signed-in.
  void _handleEmailLanding() {
    if (_landingHandled) return;
    _landingHandled = true;
    if (_openedFromEmailLink == EmailLinkType.recovery) {
      _needsNewPassword = true;
      _unlocked = true; // the link itself is the proof
    }
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

    final user = _authService.currentUser;
    if (user == null) {
      return _bareApp(theme, SignInScreen(authService: _authService));
    }

    _handleEmailLanding();

    if (_needsNewPassword) {
      return _bareApp(
        theme,
        SetNewPasswordScreen(
          authService: _authService,
          onDone: () => setState(() => _needsNewPassword = false),
        ),
      );
    }

    // A session came back from storage. Biometric unlock on -> lock screen.
    // Off -> the saved session is discarded and the password is required,
    // exactly as if nothing had been saved.
    if (!_unlocked) {
      return FutureBuilder<bool?>(
        future: _biometrics.isEnabled(),
        builder: (context, snapshot) {
          if (!snapshot.hasData && !snapshot.hasError) {
            return _bareApp(theme, const _Loading());
          }
          if (snapshot.data == true) {
            return _bareApp(
              theme,
              LockScreen(
                biometrics: _biometrics,
                email: user.email,
                onUnlocked: () => setState(() => _unlocked = true),
                onUsePassword: _authService.signOutLocal,
              ),
            );
          }
          if (!_discarding) {
            _discarding = true;
            _authService.signOutLocal();
          }
          return _bareApp(theme, const _Loading());
        },
      );
    }

    // Just signed in with the password: offer biometric unlock once, if the
    // phone has it and the owner hasn't already decided.
    if (_offerPending) {
      return FutureBuilder<bool>(
        future: _shouldOfferBiometrics(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return _bareApp(theme, const _Loading());
          if (snapshot.data != true) {
            // Nothing to ask; fall through on the next frame.
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => setState(() => _offerPending = false),
            );
            return _bareApp(theme, const _Loading());
          }
          return _bareApp(
            theme,
            EnableBiometricScreen(
              biometrics: _biometrics,
              onDone: () => setState(() => _offerPending = false),
            ),
          );
        },
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
        final services = svcSnapshot.data!;
        services.signOut = _authService.signOut;
        services.biometrics = _biometrics;
        _startCloudSync(services);
        return AppScope(
          services: services,
          child: MaterialApp(
            title: 'Burhan Rent-A-Car',
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: const ShellScreen(),
          ),
        );
      },
    );
  }

  Future<bool> _shouldOfferBiometrics() async {
    if (kIsWeb) return false;
    if (await _biometrics.isEnabled() != null) return false;
    return _biometrics.isSupported();
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

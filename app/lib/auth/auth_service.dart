import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Thin wrapper around Supabase Auth plus the app-level email-OTP second
/// factor.
///
/// Supabase's own MFA API only supports TOTP (authenticator app) and phone
/// factors, not email -- so "email OTP as a second step" is implemented at
/// the app layer instead: after a password sign-in succeeds (which already
/// establishes a valid Supabase session), [sendOtp]/[verifyOtp] run a
/// second, independent passwordless email challenge against the same
/// address before the app is unlocked. [isMfaVerified] gates that, tracked
/// per signed-in user and cleared on sign-out.
class AuthService {
  final SupabaseClient? _clientOverride;
  final FlutterSecureStorage _storage;

  AuthService({SupabaseClient? client, FlutterSecureStorage? storage})
      : _clientOverride = client,
        _storage = storage ?? const FlutterSecureStorage();

  // Lazy: constructing AuthService() must not itself touch Supabase.instance
  // -- widget tests build screens with a default AuthService() purely to
  // check validation/navigation, never call Supabase.initialize(), and
  // never get far enough to actually invoke an auth method.
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  GoTrueClient get _auth => _client.auth;

  Session? get currentSession => _auth.currentSession;
  User? get currentUser => _auth.currentUser;
  Stream<AuthState> get onAuthStateChange => _auth.onAuthStateChange;

  String _mfaKey(String userId) => 'mfa_verified_$userId';

  Future<bool> isMfaVerified(String userId) async {
    return (await _storage.read(key: _mfaKey(userId))) == 'true';
  }

  Future<void> _markMfaVerified(String userId) async {
    await _storage.write(key: _mfaKey(userId), value: 'true');
  }

  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) {
    return _auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signUp({
    required String email,
    required String password,
  }) {
    return _auth.signUp(email: email, password: password);
  }

  Future<void> sendPasswordResetEmail(String email) {
    return _auth.resetPasswordForEmail(email);
  }

  /// Sends the second-factor code to the already-authenticated user's own
  /// email address. Deliberately ignores [email] as a free-typed value --
  /// it always targets [currentUser]'s address, so the code can never be
  /// sent somewhere else.
  Future<void> sendOtp() async {
    final email = currentUser?.email;
    if (email == null) {
      throw StateError('sendOtp() requires a signed-in user with an email.');
    }
    await _auth.signInWithOtp(email: email);
  }

  Future<void> verifyOtp(String code) async {
    final email = currentUser?.email;
    if (email == null) {
      throw StateError('verifyOtp() requires a signed-in user with an email.');
    }
    await _auth.verifyOTP(type: OtpType.email, email: email, token: code);
    final userId = currentUser?.id;
    if (userId != null) await _markMfaVerified(userId);
  }

  Future<void> signOut() async {
    final userId = currentUser?.id;
    if (userId != null) await _storage.delete(key: _mfaKey(userId));
    await _auth.signOut();
  }
}

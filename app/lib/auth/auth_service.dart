import 'package:supabase_flutter/supabase_flutter.dart';

import 'email_rate_limit.dart';

/// Thin wrapper around Supabase Auth: email + password, with email-based
/// confirmation and password recovery. Single-owner app -- no second
/// factor by design.
class AuthService {
  final SupabaseClient? _clientOverride;

  AuthService({SupabaseClient? client}) : _clientOverride = client;

  // Lazy: constructing AuthService() must not itself touch Supabase.instance
  // -- widget tests build screens with a default AuthService() purely to
  // check validation/navigation, never call Supabase.initialize(), and
  // never get far enough to actually invoke an auth method.
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  GoTrueClient get _auth => _client.auth;

  Session? get currentSession => _auth.currentSession;
  User? get currentUser => _auth.currentUser;
  Stream<AuthState> get onAuthStateChange => _auth.onAuthStateChange;

  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) {
    return _auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signUp({required String email, required String password}) async {
    await _auth.signUp(email: email, password: password);
    await EmailRateLimit.recordSend();
  }

  /// Re-sends the sign-up confirmation email for an account that exists but
  /// hasn't clicked its link yet -- the failure mode behind "Email not
  /// confirmed" on sign-in.
  Future<void> resendConfirmation(String email) async {
    await _auth.resend(type: OtpType.signup, email: email);
    await EmailRateLimit.recordSend();
  }

  Future<void> sendPasswordResetEmail(String email) async {
    await _auth.resetPasswordForEmail(email);
    await EmailRateLimit.recordSend();
  }

  /// Sets a new password for the currently signed-in user -- used after a
  /// recovery link has landed the user back in the app.
  Future<void> updatePassword(String newPassword) {
    return _auth.updateUser(UserAttributes(password: newPassword));
  }

  Future<void> signOut() => _auth.signOut();

  /// Drops the session on this device only, without a server round-trip --
  /// used to fall back from the biometric lock to the password, and to
  /// discard a restored session when biometric unlock is off. Works offline.
  Future<void> signOutLocal() => _auth.signOut(scope: SignOutScope.local);
}

import 'package:supabase_flutter/supabase_flutter.dart';

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

  Future<void> signUp({required String email, required String password}) {
    return _auth.signUp(email: email, password: password);
  }

  /// Re-sends the sign-up confirmation email for an account that exists but
  /// hasn't clicked its link yet -- the failure mode behind "Email not
  /// confirmed" on sign-in.
  Future<void> resendConfirmation(String email) {
    return _auth.resend(type: OtpType.signup, email: email);
  }

  Future<void> sendPasswordResetEmail(String email) {
    return _auth.resetPasswordForEmail(email);
  }

  /// Sets a new password for the currently signed-in user -- used after a
  /// recovery link has landed the user back in the app.
  Future<void> updatePassword(String newPassword) {
    return _auth.updateUser(UserAttributes(password: newPassword));
  }

  Future<void> signOut() => _auth.signOut();
}

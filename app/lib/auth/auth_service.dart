import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Thin wrapper around Supabase Auth plus the app-level email second factor.
///
/// Supabase's own MFA API only supports TOTP (authenticator app) and phone
/// factors, not email -- so "email as a second step" is implemented at the
/// app layer: after a password sign-in succeeds (which already establishes
/// a Supabase session), the app stays locked until the user proves access
/// to their inbox. That proof is accepted in EITHER of two forms, because
/// which one arrives depends on the project's email template:
///
///  * typing the 6-digit code from the email ([verifyOtp]) -- only present
///    if the Magic Link template includes `{{ .Token }}`; or
///  * clicking the link in the email, which lands back on the app with a
///    session in the URL ([markMfaVerified], called by the app on such a
///    landing). Clicking a link that only the inbox owner could have
///    received proves exactly what typing the code does.
///
/// [isMfaVerified] gates the app on that, tracked per signed-in user in
/// platform secure storage and cleared on sign-out.
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

  Future<void> markMfaVerified(String userId) async {
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

  /// Sends the second-step email to the already-authenticated user's own
  /// address. Never takes a free-typed address, so it can't be redirected.
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
    if (userId != null) await markMfaVerified(userId);
  }

  Future<void> signOut() async {
    final userId = currentUser?.id;
    if (userId != null) await _storage.delete(key: _mfaKey(userId));
    await _auth.signOut();
  }
}

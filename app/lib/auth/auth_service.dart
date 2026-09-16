import 'package:supabase_flutter/supabase_flutter.dart';

/// Thin wrapper around Supabase Auth with authenticator-app (TOTP) MFA as a
/// mandatory second step.
///
/// Supabase tracks how strongly a session is authenticated as an
/// "assurance level": `aal1` after a password alone, `aal2` once a TOTP
/// code has been verified. That level lives in the session itself, so it
/// survives reloads, drops back to `aal1` on every fresh sign-in (the code
/// is required each login), and disappears on sign-out -- no app-side
/// flag to keep in step. The app unlocks only at `aal2`.
///
/// Enrollment is enforced, not optional: a user with no verified factor is
/// sent to enrol before anything else. This is a single-owner app, so that
/// is the owner setting up their own second step once.
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

  // ---- password -----------------------------------------------------------

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

  // ---- authenticator-app second step ---------------------------------------

  /// Whether the current session has passed the second step.
  bool isFullyVerified() {
    final level = _auth.mfa.getAuthenticatorAssuranceLevel();
    return level.currentLevel == AuthenticatorAssuranceLevels.aal2;
  }

  /// The user's verified authenticator factor, or null if none is enrolled.
  Future<Factor?> verifiedTotpFactor() async {
    final factors = await _auth.mfa.listFactors();
    return factors.totp.isEmpty ? null : factors.totp.first;
  }

  /// Starts enrolment. Any half-finished (unverified) factor from an earlier
  /// abandoned attempt is discarded first, so the user always scans exactly
  /// the QR code that will be verified.
  Future<AuthMFAEnrollResponse> enrollTotp() async {
    final existing = await _auth.mfa.listFactors();
    for (final f in existing.all) {
      if (f.status == FactorStatus.unverified) {
        await _auth.mfa.unenroll(f.id);
      }
    }
    return _auth.mfa.enroll(
      factorType: FactorType.totp,
      friendlyName: 'Burhan Rent-A-Car',
      issuer: 'Burhan Rent-A-Car',
    );
  }

  /// Checks a 6-digit code from the authenticator app against [factorId].
  /// On success the session is upgraded to `aal2`.
  Future<void> verifyTotp({
    required String factorId,
    required String code,
  }) async {
    final challenge = await _auth.mfa.challenge(factorId: factorId);
    await _auth.mfa.verify(
      factorId: factorId,
      challengeId: challenge.id,
      code: code,
    );
  }
}

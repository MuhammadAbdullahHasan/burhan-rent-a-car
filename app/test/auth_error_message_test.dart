import 'package:burhan_rent_a_car/auth/auth_error_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Every message the owner can see on an auth screen comes through here,
/// so the raw server/transport wording never reaches them.
void main() {
  test('wrong password reads as a credentials problem, not a server code', () {
    expect(
      authErrorMessage(const AuthException('Invalid login credentials'),
          fallback: 'x'),
      'Incorrect email or password.',
    );
  });

  test('unconfirmed account is recognised and explained', () {
    const e = AuthException('Email not confirmed');
    expect(isUnconfirmedEmailError(e), isTrue);
    expect(authErrorMessage(e, fallback: 'x'), contains('confirmation link'));
  });

  test('rate limiting tells the user to wait', () {
    expect(
      authErrorMessage(const AuthException('email rate limit exceeded'),
          fallback: 'x'),
      contains('wait a few minutes'),
    );
  });

  test('network failures on either platform become one plain sentence', () {
    for (final raw in [
      'ClientException with SocketException: Failed host lookup: x',
      'ClientException: XMLHttpRequest error.',
    ]) {
      expect(
        authErrorMessage(Exception(raw), fallback: 'x'),
        contains('Check your internet connection'),
        reason: raw,
      );
    }
  });

  test('anything unrecognised falls back to the screen-specific message', () {
    expect(
      authErrorMessage(StateError('boom'), fallback: 'Could not sign in.'),
      'Could not sign in.',
    );
  });

  test('an unrecognised server message is passed through unchanged', () {
    expect(
      authErrorMessage(const AuthException('Signups not allowed for this instance'),
          fallback: 'x'),
      'Signups not allowed for this instance',
    );
  });
}

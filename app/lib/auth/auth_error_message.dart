import 'package:supabase_flutter/supabase_flutter.dart';

/// Turns whatever an auth call threw into one sentence the owner can act
/// on. Server messages are terse and technical ("Invalid login
/// credentials", "email rate limit exceeded"); transport failures dump a
/// whole exception. Neither belongs on screen verbatim.
String authErrorMessage(Object error, {required String fallback}) {
  if (error is AuthException) {
    final msg = error.message.toLowerCase();
    if (msg.contains('invalid login credentials') ||
        msg.contains('invalid credentials')) {
      return 'Incorrect email or password.';
    }
    if (msg.contains('email not confirmed')) {
      return "This email hasn't been confirmed yet. Check your inbox (and "
          'spam) for the confirmation link, or resend it below.';
    }
    if (msg.contains('rate limit')) {
      return 'Too many attempts. Please wait a few minutes and try again.';
    }
    if (msg.contains('already registered') || msg.contains('already exists')) {
      return 'An account with this email already exists. Try signing in.';
    }
    if (msg.contains('password') && msg.contains('at least')) {
      return 'Password is too short.';
    }
    if (msg.contains('invalid totp') || msg.contains('invalid code')) {
      return 'That code is incorrect or has expired. Enter the current one.';
    }
    if (msg.contains('user not found')) {
      return 'No account exists for this email.';
    }
    return error.message;
  }

  // No dart:io here (unavailable on web): match on text instead, which
  // covers SocketException on mobile and http's XMLHttpRequest error on web.
  final text = error.toString();
  if (text.contains('SocketException') ||
      text.contains('Failed host lookup') ||
      text.contains('XMLHttpRequest') ||
      text.contains('Connection refused')) {
    return "Can't reach the server. Check your internet connection and try "
        'again.';
  }

  return fallback;
}

/// Whether an error is the specific "account exists but is unconfirmed"
/// case, which the sign-in screen handles with a resend action.
bool isUnconfirmedEmailError(Object error) =>
    error is AuthException &&
    error.message.toLowerCase().contains('email not confirmed');

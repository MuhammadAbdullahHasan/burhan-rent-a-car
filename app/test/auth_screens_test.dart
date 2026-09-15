import 'package:burhan_rent_a_car/auth/auth_service.dart';
import 'package:burhan_rent_a_car/auth/forgot_password_screen.dart';
import 'package:burhan_rent_a_car/auth/sign_in_screen.dart';
import 'package:burhan_rent_a_car/auth/sign_up_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Auth screens without a live Supabase connection: form validation,
/// navigation between them, and password-visibility toggling. Anything
/// that actually calls the network (sign-in, OTP send/verify) is out of
/// scope for a widget test and is exercised manually against the real
/// backend instead.
void main() {
  Future<void> pump(WidgetTester t, Widget screen) async {
    await t.pumpWidget(MaterialApp(home: screen));
  }

  group('SignInScreen', () {
    testWidgets('rejects an invalid email and empty password', (t) async {
      await pump(t, SignInScreen(authService: AuthService()));

      await t.tap(find.text('Sign In'));
      await t.pump();

      expect(find.text('Enter a valid email'), findsOneWidget);
      expect(find.text('Enter your password'), findsOneWidget);
    });

    testWidgets('password field starts obscured and can be revealed',
        (t) async {
      await pump(t, SignInScreen(authService: AuthService()));

      Finder textFieldOf(Finder formField) => find.descendant(
            of: formField,
            matching: find.byType(TextField),
          );

      final passwordField = find.widgetWithText(TextFormField, 'Password');
      expect(t.widget<TextField>(textFieldOf(passwordField)).obscureText, isTrue);

      await t.tap(find.byIcon(Icons.visibility_outlined));
      await t.pump();

      expect(t.widget<TextField>(textFieldOf(passwordField)).obscureText, isFalse);
    });

    testWidgets('links to Sign up and Forgot password', (t) async {
      await pump(t, SignInScreen(authService: AuthService()));

      expect(find.text("Don't have an account? Sign up"), findsOneWidget);
      expect(find.text('Forgot password?'), findsOneWidget);

      await t.tap(find.text('Forgot password?'));
      await t.pumpAndSettle();
      expect(find.byType(ForgotPasswordScreen), findsOneWidget);
    });

    testWidgets('Sign up link opens SignUpScreen', (t) async {
      await pump(t, SignInScreen(authService: AuthService()));
      await t.tap(find.text("Don't have an account? Sign up"));
      await t.pumpAndSettle();
      expect(find.byType(SignUpScreen), findsOneWidget);
    });
  });

  group('SignUpScreen', () {
    testWidgets('requires a valid email and an 8+ character password',
        (t) async {
      await pump(t, SignUpScreen(authService: AuthService()));

      await t.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'short',
      );
      await t.tap(find.widgetWithText(FilledButton, 'Create Account'));
      await t.pump();

      expect(find.text('Enter a valid email'), findsOneWidget);
      expect(find.text('At least 8 characters'), findsOneWidget);
    });

    testWidgets('rejects mismatched password confirmation', (t) async {
      await pump(t, SignUpScreen(authService: AuthService()));

      await t.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'owner@example.com',
      );
      await t.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'longenoughpassword',
      );
      await t.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'),
        'somethingelse',
      );
      await t.tap(find.widgetWithText(FilledButton, 'Create Account'));
      await t.pump();

      expect(find.text('Passwords do not match'), findsOneWidget);
    });
  });

  group('ForgotPasswordScreen', () {
    testWidgets('requires a valid email before sending', (t) async {
      await pump(t, ForgotPasswordScreen(authService: AuthService()));

      await t.tap(find.text('Send Reset Link'));
      await t.pump();

      expect(find.text('Enter a valid email'), findsOneWidget);
    });
  });
}

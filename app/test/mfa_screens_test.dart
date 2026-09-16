import 'package:burhan_rent_a_car/auth/auth_service.dart';
import 'package:burhan_rent_a_car/auth/mfa_challenge_screen.dart';
import 'package:burhan_rent_a_car/auth/mfa_code_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Authenticator-code screens without a live Supabase connection. The
/// challenge screen makes no network call until a 6-digit code is
/// submitted, so its input rules can be checked directly.
void main() {
  Future<void> pump(WidgetTester t, Widget screen) async {
    await t.pumpWidget(MaterialApp(home: screen));
  }

  group('MfaChallengeScreen', () {
    testWidgets('refuses a short code before touching the network', (t) async {
      await pump(t, MfaChallengeScreen(
        authService: AuthService(),
        factorId: 'factor-1',
        onVerified: () => fail('must not verify a 3-digit code'),
      ));

      await t.enterText(find.byType(TextField), '123');
      await t.tap(find.widgetWithText(FilledButton, 'Verify'));
      await t.pump();

      expect(find.text('Enter the 6-digit code from your app'), findsOneWidget);
    });

    testWidgets('offers a way out via Sign out', (t) async {
      await pump(t, MfaChallengeScreen(
        authService: AuthService(),
        factorId: 'factor-1',
        onVerified: () {},
      ));
      expect(find.text('Sign out'), findsOneWidget);
    });
  });

  group('MfaCodeField', () {
    testWidgets('accepts digits only and caps at six', (t) async {
      final controller = TextEditingController();
      await pump(t, Scaffold(
        body: MfaCodeField(controller: controller, onSubmitted: () {}),
      ));

      await t.enterText(find.byType(TextField), '12ab34567890');
      expect(controller.text, '123456');
    });
  });
}

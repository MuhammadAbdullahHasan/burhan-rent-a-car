import 'package:burhan_rent_a_car/auth/biometric_service.dart';
import 'package:burhan_rent_a_car/auth/enable_biometric_screen.dart';
import 'package:burhan_rent_a_car/auth/lock_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scriptable stand-in for the phone's fingerprint/face prompt.
class FakeBiometrics implements BiometricService {
  bool supported;
  bool? enabled;
  List<bool> results;
  int prompts = 0;

  FakeBiometrics({this.supported = true, this.enabled, this.results = const [true]});

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return results.length >= prompts ? results[prompts - 1] : results.last;
  }

  @override
  Future<bool?> isEnabled() async => enabled;

  @override
  Future<void> setEnabled(bool value) async => enabled = value;
}

void main() {
  group('LockScreen', () {
    testWidgets('prompts on its own and unlocks on success', (t) async {
      final bio = FakeBiometrics(results: const [true]);
      var unlocked = false;
      await t.pumpWidget(MaterialApp(
        home: LockScreen(
          biometrics: bio,
          email: 'owner@example.com',
          onUnlocked: () => unlocked = true,
          onUsePassword: () async {},
        ),
      ));
      await t.pumpAndSettle();

      expect(bio.prompts, 1);
      expect(unlocked, isTrue);
      expect(find.text('Signed in as owner@example.com'), findsOneWidget);
    });

    testWidgets('a failed check shows a message and allows retry', (t) async {
      final bio = FakeBiometrics(results: const [false, true]);
      var unlocked = false;
      await t.pumpWidget(MaterialApp(
        home: LockScreen(
          biometrics: bio,
          email: null,
          onUnlocked: () => unlocked = true,
          onUsePassword: () async {},
        ),
      ));
      await t.pumpAndSettle();

      expect(unlocked, isFalse);
      expect(find.textContaining("Couldn't verify"), findsOneWidget);

      await t.tap(find.text('Unlock with fingerprint / face'));
      await t.pumpAndSettle();
      expect(bio.prompts, 2);
      expect(unlocked, isTrue);
    });

    testWidgets('"Use password instead" hands off to the password flow',
        (t) async {
      final bio = FakeBiometrics(results: const [false]);
      var passwordRequested = false;
      await t.pumpWidget(MaterialApp(
        home: LockScreen(
          biometrics: bio,
          email: null,
          onUnlocked: () {},
          onUsePassword: () async => passwordRequested = true,
        ),
      ));
      await t.pumpAndSettle();

      await t.tap(find.text('Use password instead'));
      await t.pumpAndSettle();
      expect(passwordRequested, isTrue);
    });
  });

  group('EnableBiometricScreen', () {
    testWidgets('turning on requires a successful check first', (t) async {
      final bio = FakeBiometrics(results: const [true]);
      var done = false;
      await t.pumpWidget(MaterialApp(
        home: EnableBiometricScreen(biometrics: bio, onDone: () => done = true),
      ));

      await t.tap(find.text('Turn on fingerprint / face'));
      await t.pumpAndSettle();

      expect(bio.prompts, 1);
      expect(bio.enabled, isTrue);
      expect(done, isTrue);
    });

    testWidgets('a failed check leaves it off and explains', (t) async {
      final bio = FakeBiometrics(results: const [false]);
      var done = false;
      await t.pumpWidget(MaterialApp(
        home: EnableBiometricScreen(biometrics: bio, onDone: () => done = true),
      ));

      await t.tap(find.text('Turn on fingerprint / face'));
      await t.pumpAndSettle();

      expect(bio.enabled, isNull);
      expect(done, isFalse);
      expect(find.textContaining("Couldn't verify"), findsOneWidget);
    });

    testWidgets('"Not now" is remembered so the question is not repeated',
        (t) async {
      final bio = FakeBiometrics();
      var done = false;
      await t.pumpWidget(MaterialApp(
        home: EnableBiometricScreen(biometrics: bio, onDone: () => done = true),
      ));

      await t.tap(find.text('Not now'));
      await t.pumpAndSettle();

      expect(bio.enabled, isFalse);
      expect(bio.prompts, 0);
      expect(done, isTrue);
    });
  });
}

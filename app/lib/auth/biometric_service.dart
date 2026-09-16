import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// Fingerprint / face unlock of the saved sign-in, plus the owner's choice
/// of whether to use it.
///
/// Biometrics never replace the account password: they only unlock a
/// session that a password sign-in already created. Password sign-in and
/// email recovery keep working regardless.
///
/// The preference has three states: unset (never asked -- offer it after
/// the next password sign-in), enabled, or declined (don't ask again; can
/// be switched on from the Home menu).
abstract class BiometricService {
  Future<bool> isSupported();
  Future<bool> authenticate(String reason);
  Future<bool?> isEnabled();
  Future<void> setEnabled(bool enabled);
}

class DeviceBiometricService implements BiometricService {
  static const _prefKey = 'biometric_unlock';
  final LocalAuthentication _auth;
  final FlutterSecureStorage _storage;

  DeviceBiometricService({
    LocalAuthentication? auth,
    FlutterSecureStorage? storage,
  })  : _auth = auth ?? LocalAuthentication(),
        _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<bool> isSupported() async {
    if (kIsWeb) return false;
    try {
      if (!await _auth.isDeviceSupported()) return false;
      // canCheckBiometrics is false when nothing is enrolled yet; the
      // device-credential fallback still lets the system prompt work, but
      // there's little point offering "fingerprint" with none set up.
      final enrolled = await _auth.getAvailableBiometrics();
      return enrolled.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          // Let the phone's PIN/pattern stand in if a fingerprint read
          // fails repeatedly -- the same fallback the system uses.
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool?> isEnabled() async {
    final raw = await _storage.read(key: _prefKey);
    return raw == null ? null : raw == 'true';
  }

  @override
  Future<void> setEnabled(bool enabled) =>
      _storage.write(key: _prefKey, value: enabled ? 'true' : 'false');
}

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Keeps the Supabase session in platform secure storage (Android Keystore
/// / iOS Keychain) instead of the SDK's default plain preferences.
///
/// This is what makes fingerprint/face sign-in possible: the session
/// survives a restart, but the app refuses to use it until the biometric
/// lock screen has passed -- see main.dart. It is never read by anything
/// else.
class SecureSessionStorage extends LocalStorage {
  static const _key = 'supabase_session';
  final FlutterSecureStorage _storage;

  SecureSessionStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> hasAccessToken() async =>
      (await _storage.read(key: _key)) != null;

  @override
  Future<String?> accessToken() => _storage.read(key: _key);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _key, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => _storage.delete(key: _key);
}

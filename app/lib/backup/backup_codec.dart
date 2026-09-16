import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show compute;

/// Backup file format:
///
///   "BRAC1" | salt (16) | nonce (12) | mac (16) | AES-256-GCM ciphertext
///
/// The ciphertext is a gzip-compressed JSON document holding every
/// customer, vehicle, rental and agreement photo (photos base64). The key
/// is derived from the owner's backup password with PBKDF2-HMAC-SHA256
/// (100,000 rounds), so the file is restorable on any device that knows the
/// password and useless to anyone who doesn't.
///
/// The cloud snapshot ([encodeSnapshot]) is the same JSON+gzip payload
/// without the encryption layer: it lives in a private bucket only the
/// signed-in owner can read.
class BackupCodec {
  static const magic = 'BRAC1';
  static const _iterations = 100000;

  static const _formatKey = 'format';
  static const _format = 'burhan-rent-a-car-backup';

  /// Plain (unencrypted) gzip JSON.
  static Future<Uint8List> encodeSnapshot(Snapshot snapshot) =>
      compute(_encode, _snapshotToJson(snapshot));

  static Future<Snapshot> decodeSnapshot(Uint8List bytes) async {
    final json = await compute(_decode, bytes);
    return _snapshotFromJson(json);
  }

  static Future<Uint8List> encrypt(Snapshot snapshot, String password) async {
    final plain = await encodeSnapshot(snapshot);
    return compute(_encryptSync, _CryptoJob(plain, password));
  }

  /// Throws [BackupFormatException] for a non-backup file and
  /// [WrongPasswordException] when the password does not open it.
  static Future<Snapshot> decrypt(Uint8List file, String password) async {
    final plain = await compute(_decryptSync, _CryptoJob(file, password));
    return decodeSnapshot(plain);
  }

  /// How many records a file holds, for the confirmation step.
  static BackupCounts countsOf(Snapshot s) => BackupCounts(
        customers: s.customers.length,
        vehicles: s.vehicles.length,
        rentals: s.rentals.length,
        attachments: s.attachments.length,
      );

  // ---- JSON ----------------------------------------------------------------

  static Map<String, Object?> _snapshotToJson(Snapshot s) => {
        _formatKey: _format,
        'version': 1,
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'customers': s.customers,
        'vehicles': s.vehicles,
        'rentals': s.rentals,
        'attachments': [
          for (final a in s.attachments)
            {
              for (final e in a.entries)
                e.key: e.value is Uint8List
                    ? base64Encode(e.value as Uint8List)
                    : e.value,
            },
        ],
      };

  static Snapshot _snapshotFromJson(Map<String, Object?> json) {
    if (json[_formatKey] != _format) {
      throw const BackupFormatException('Not a Burhan Rent-A-Car backup.');
    }
    List<Map<String, Object?>> rows(String key) =>
        (json[key] as List? ?? const [])
            .cast<Map>()
            .map((m) => m.cast<String, Object?>())
            .toList();
    return Snapshot(
      customers: rows('customers'),
      vehicles: rows('vehicles'),
      rentals: rows('rentals'),
      attachments: [
        for (final a in rows('attachments'))
          {
            ...a,
            'image':
                a['image'] == null ? null : base64Decode(a['image'] as String),
            'thumbnail': a['thumbnail'] == null
                ? null
                : base64Decode(a['thumbnail'] as String),
          },
      ],
    );
  }
}

class BackupCounts {
  final int customers;
  final int vehicles;
  final int rentals;
  final int attachments;
  const BackupCounts({
    required this.customers,
    required this.vehicles,
    required this.rentals,
    required this.attachments,
  });
}

class BackupFormatException implements Exception {
  final String message;
  const BackupFormatException(this.message);
  @override
  String toString() => message;
}

class WrongPasswordException implements Exception {
  const WrongPasswordException();
  @override
  String toString() => 'Wrong backup password.';
}

// ---- isolate workers ---------------------------------------------------------

Uint8List _encode(Map<String, Object?> json) {
  final bytes = utf8.encode(jsonEncode(json));
  return Uint8List.fromList(GZipEncoder().encodeBytes(bytes));
}

Map<String, Object?> _decode(Uint8List bytes) {
  final List<int> plain;
  try {
    plain = GZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const BackupFormatException('Not a Burhan Rent-A-Car backup.');
  }
  final decoded = jsonDecode(utf8.decode(plain));
  if (decoded is! Map) {
    throw const BackupFormatException('Not a Burhan Rent-A-Car backup.');
  }
  return decoded.cast<String, Object?>();
}

class _CryptoJob {
  final Uint8List bytes;
  final String password;
  const _CryptoJob(this.bytes, this.password);
}

Future<SecretKey> _deriveKey(String password, List<int> salt) {
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: BackupCodec._iterations,
    bits: 256,
  );
  return pbkdf2.deriveKeyFromPassword(password: password, nonce: salt);
}

Future<Uint8List> _encryptSync(_CryptoJob job) async {
  final algorithm = AesGcm.with256bits();
  final salt = SecretKeyData.random(length: 16).bytes;
  final nonce = algorithm.newNonce();
  final key = await _deriveKey(job.password, salt);
  final box = await algorithm.encrypt(job.bytes, secretKey: key, nonce: nonce);
  final builder = BytesBuilder(copy: false)
    ..add(ascii.encode(BackupCodec.magic))
    ..add(salt)
    ..add(nonce)
    ..add(box.mac.bytes)
    ..add(box.cipherText);
  return builder.toBytes();
}

Future<Uint8List> _decryptSync(_CryptoJob job) async {
  final file = job.bytes;
  const headerLength = 5 + 16 + 12 + 16;
  if (file.length < headerLength ||
      ascii.decode(file.sublist(0, 5), allowInvalid: true) !=
          BackupCodec.magic) {
    throw const BackupFormatException('Not a Burhan Rent-A-Car backup.');
  }
  final salt = file.sublist(5, 21);
  final nonce = file.sublist(21, 33);
  final mac = Mac(file.sublist(33, 49));
  final cipherText = file.sublist(49);
  final key = await _deriveKey(job.password, salt);
  try {
    final plain = await AesGcm.with256bits().decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: key,
    );
    return Uint8List.fromList(plain);
  } on SecretBoxAuthenticationError {
    throw const WrongPasswordException();
  }
}

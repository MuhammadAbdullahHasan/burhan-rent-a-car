import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../supabase_config.dart';

/// The owner's scanned agreements from before the app, kept in the private
/// `agreements` bucket as `<business>/<rental_no>.jpg` (a second scan of
/// the same rental as `<rental_no>-2.jpg`). A rental that has no photo of
/// its own shows its archive scan, fetched here on demand and cached on
/// the device so it opens offline next time. Rentals without a scan get
/// nothing -- there is no placeholder image.
enum _Fetch { missing, offline }

class AgreementArchive {
  final SupabaseClient client;
  static const _bucket = 'agreements';

  /// Numbers known to have no scan, so a rental isn't asked for again in
  /// this session (an unknown number is one round trip, not a cost worth
  /// caching to disk).
  final _absent = <int>{};
  final _memory = <int, List<Uint8List>>{};

  AgreementArchive({required this.client});

  String get _folder => businessFolder;

  /// Every archive scan of [rentalNo], first scan first; empty when there
  /// is none or the device is offline and nothing is cached.
  Future<List<Uint8List>> photosFor(int rentalNo) async {
    final cached = _memory[rentalNo];
    if (cached != null) return cached;
    if (_absent.contains(rentalNo)) return const [];

    final fromDisk = await _readDisk(rentalNo);
    if (fromDisk.isNotEmpty) return _memory[rentalNo] = fromDisk;

    if (client.auth.currentUser == null) return const [];
    final photos = <Uint8List>[];
    // The first scan is fetched by its exact name: a name search would rank
    // "1005.jpg" ahead of "5.jpg" and cap at a page, so short numbers would
    // come back empty. Further scans (rare) are "<no>-2.jpg", "-3" ...
    final first = await _fetch('$rentalNo.jpg');
    if (first == _Fetch.offline) return const [];
    if (first == _Fetch.missing) {
      _absent.add(rentalNo);
      return const [];
    }
    photos.add(first as Uint8List);
    for (var i = 2; i <= 9; i++) {
      final more = await _fetch('$rentalNo-$i.jpg');
      if (more is! Uint8List) break;
      photos.add(more);
    }
    return _memory[rentalNo] = photos;
  }

  /// The bytes of one object, [_Fetch.missing] when the bucket has no such
  /// name, [_Fetch.offline] when the request could not be made at all.
  Future<Object> _fetch(String name) async {
    try {
      final bytes =
          await client.storage.from(_bucket).download('$_folder/$name');
      await _writeDisk(name, bytes);
      return bytes;
    } on StorageException catch (e) {
      final code = e.statusCode ?? '';
      final text = e.message.toLowerCase();
      if (code == '404' || code == '400' || text.contains('not found')) {
        return _Fetch.missing;
      }
      return _Fetch.offline;
    } catch (_) {
      return _Fetch.offline;
    }
  }

  Future<Directory?> _cacheDir() async {
    if (kIsWeb) return null;
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory(p.join(base.path, 'agreement_archive', _folder));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    } catch (_) {
      return null; // no writable app directory: work from memory only
    }
  }

  Future<List<Uint8List>> _readDisk(int rentalNo) async {
    final dir = await _cacheDir();
    if (dir == null) return const [];
    final pattern = RegExp('^$rentalNo(-\\d+)?\\.jpg\$');
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => pattern.hasMatch(p.basename(f.path)))
        .toList()
      ..sort((a, b) => a.path.length != b.path.length
          ? a.path.length - b.path.length
          : a.path.compareTo(b.path));
    return [for (final f in files) await f.readAsBytes()];
  }

  Future<void> _writeDisk(String name, Uint8List bytes) async {
    final dir = await _cacheDir();
    if (dir == null) return;
    await File(p.join(dir.path, name)).writeAsBytes(bytes, flush: true);
  }
}

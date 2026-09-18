import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The owner's scanned agreements from before the app, kept in the private
/// `agreements` bucket as `<owner_id>/<rental_no>.jpg` (a second scan of
/// the same rental as `<rental_no>-2.jpg`). A rental that has no photo of
/// its own shows its archive scan, fetched here on demand and cached on
/// the device so it opens offline next time. Rentals without a scan get
/// nothing -- there is no placeholder image.
class AgreementArchive {
  final SupabaseClient client;
  static const _bucket = 'agreements';

  /// Numbers known to have no scan, so a rental isn't asked for again in
  /// this session (an unknown number is one round trip, not a cost worth
  /// caching to disk).
  final _absent = <int>{};
  final _memory = <int, List<Uint8List>>{};

  AgreementArchive({required this.client});

  String get _folder => client.auth.currentUser!.id;

  /// Every archive scan of [rentalNo], first scan first; empty when there
  /// is none or the device is offline and nothing is cached.
  Future<List<Uint8List>> photosFor(int rentalNo) async {
    final cached = _memory[rentalNo];
    if (cached != null) return cached;
    if (_absent.contains(rentalNo)) return const [];

    final fromDisk = await _readDisk(rentalNo);
    if (fromDisk.isNotEmpty) return _memory[rentalNo] = fromDisk;

    if (client.auth.currentUser == null) return const [];
    final List<FileObject> objects;
    try {
      objects = await client.storage.from(_bucket).list(
            path: _folder,
            searchOptions: SearchOptions(search: '$rentalNo', limit: 20),
          );
    } catch (_) {
      return const []; // offline or bucket unreachable: nothing to show
    }
    final pattern = RegExp('^$rentalNo(-\\d+)?\\.jpg\$');
    final names = objects.map((o) => o.name).where(pattern.hasMatch).toList()
      ..sort((a, b) => a.length != b.length
          ? a.length - b.length // "96.jpg" before "96-2.jpg"
          : a.compareTo(b));
    if (names.isEmpty) {
      _absent.add(rentalNo);
      return const [];
    }
    final photos = <Uint8List>[];
    for (final name in names) {
      try {
        final bytes =
            await client.storage.from(_bucket).download('$_folder/$name');
        photos.add(bytes);
        await _writeDisk(name, bytes);
      } catch (_) {
        // A scan that fails to download is simply not shown this time.
      }
    }
    if (photos.isEmpty) return const [];
    return _memory[rentalNo] = photos;
  }

  Future<Directory?> _cacheDir() async {
    if (kIsWeb) return null;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'agreement_archive', _folder));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
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

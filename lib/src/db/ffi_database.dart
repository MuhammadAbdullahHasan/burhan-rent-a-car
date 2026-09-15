import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'database.dart';

/// FFI-backed open, for this package's tests and CLI tools (and any future
/// desktop build). The Android app uses `sqflite`'s own factory instead --
/// see [openAppDatabase].
Future<Database> openAppDatabaseFfi(String path) {
  sqfliteFfiInit();
  return openAppDatabase(databaseFactoryFfi, path);
}

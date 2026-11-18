import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import 'local_store.dart';
import 'local_store_sqlite.dart';
import 'secure_store.dart';

/// Android/iOS use SQLCipher with a 256-bit key held in Keychain/Keystore.
/// Windows/Linux/macOS use sqflite_common_ffi (development preview, unencrypted).
Future<LocalStore> openLocalStore(SecureStore secure) async {
  final dir = await getApplicationSupportDirectory();
  final path = p.join(dir.path, 'coralink.db');

  final Database db;
  final useCipher = Platform.isAndroid || Platform.isIOS;
  if (useCipher) {
    final key = await secure.databaseKey();
    db = await cipher.openDatabase(
      path,
      password: key,
      version: SqliteLocalStore.schemaVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: SqliteLocalStore.createSchema,
      onUpgrade: SqliteLocalStore.upgrade,
    );
  } else {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: SqliteLocalStore.schemaVersion,
        onCreate: SqliteLocalStore.createSchema,
        onUpgrade: SqliteLocalStore.upgrade,
      ),
    );
  }
  await db.rawQuery('PRAGMA journal_mode = WAL');
  return SqliteLocalStore(db);
}

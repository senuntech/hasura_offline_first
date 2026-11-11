import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

/// Manages the local SQLite database connection for mobile, desktop, and testing environments.
class DatabaseProvider {
  final String dbName;
  sqflite.Database? _database;
  Future<sqflite.Database>? _initFuture;
  final sqflite.DatabaseFactory? customDatabaseFactory;

  DatabaseProvider({
    this.dbName = 'hasura_local_replica.db',
    this.customDatabaseFactory,
  });

  /// Returns the active SQLite database instance, initializing it if necessary.
  Future<sqflite.Database> get database {
    if (_database != null && _database!.isOpen) {
      return Future.value(_database!);
    }
    return _initFuture ??= _initDatabase();
  }

  Future<sqflite.Database> _initDatabase() async {
    sqflite.DatabaseFactory factory;

    if (customDatabaseFactory != null) {
      factory = customDatabaseFactory!;
    } else if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      ffi.sqfliteFfiInit();
      factory = ffi.databaseFactoryFfi;
    } else {
      factory = sqflite.databaseFactory;
    }

    String dbPath;
    try {
      if (kIsWeb) {
        dbPath = dbName;
      } else {
        final docDir = await getApplicationDocumentsDirectory();
        final dirPath = p.join(docDir.path, 'hasura_db');
        final dir = Directory(dirPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        dbPath = p.join(dirPath, dbName);
      }
    } catch (_) {
      // Fallback for headless test environments
      final tempDir = Directory.systemTemp.path;
      dbPath = p.join(tempDir, 'hasura_db', dbName);
      final dir = Directory(p.dirname(dbPath));
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
    }

    final db = await factory.openDatabase(
      dbPath,
      options: sqflite.OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await _createControlTables(db);
        },
      ),
    );

    // Ensure control tables exist even if opened previously
    await _createControlTables(db);

    _database = db;
    return db;
  }

  Future<void> _createControlTables(sqflite.DatabaseExecutor db) async {
    // 1. Audit and Outbox Sync Log Table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS _sync_log (
        id TEXT PRIMARY KEY,
        table_name TEXT NOT NULL,
        row_id TEXT NOT NULL,
        operation TEXT NOT NULL,
        payload TEXT,
        created_at TEXT NOT NULL,
        status TEXT NOT NULL,
        retry_count INTEGER DEFAULT 0,
        last_error TEXT
      )
    ''');

    // 2. Schema Metadata Snapshot Table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS _schema_metadata (
        table_name TEXT PRIMARY KEY,
        columns_json TEXT NOT NULL,
        schema_hash TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    // 3. Sync Checkpoints Table (for delta pull sync)
    await db.execute('''
      CREATE TABLE IF NOT EXISTS _sync_checkpoint (
        table_name TEXT PRIMARY KEY,
        last_sync_time TEXT NOT NULL
      )
    ''');
  }

  /// Closes database connection.
  Future<void> close() async {
    if (_database != null && _database!.isOpen) {
      await _database!.close();
      _database = null;
      _initFuture = null;
    }
  }
}

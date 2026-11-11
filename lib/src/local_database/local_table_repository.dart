import 'dart:async';
import 'dart:convert';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:uuid/uuid.dart';
import 'database_provider.dart';

/// Represents a change event in a local SQLite table.
class TableChangeEvent {
  final String tableName;
  final String operation; // 'insert', 'update', 'delete', 'sync'
  final String? rowId;

  TableChangeEvent({
    required this.tableName,
    required this.operation,
    this.rowId,
  });
}

/// Provides CRUD operations directly against the local SQLite database replica,
/// handling audit columns and outbox logging automatically.
class LocalTableRepository {
  final DatabaseProvider databaseProvider;
  final _uuid = const Uuid();
  final StreamController<TableChangeEvent> _tableChangeController =
      StreamController<TableChangeEvent>.broadcast();

  LocalTableRepository({required this.databaseProvider});

  /// Broadcast stream emitting table change notifications.
  Stream<TableChangeEvent> get onTableChanged => _tableChangeController.stream;

  void notifyChange(String tableName, String operation, [String? rowId]) {
    if (!_tableChangeController.isClosed) {
      _tableChangeController.add(
        TableChangeEvent(
          tableName: tableName,
          operation: operation,
          rowId: rowId,
        ),
      );
    }
  }

  Future<void> _ensureTableAndColumns(
    sqflite.DatabaseExecutor db,
    String tableName, [
    Map<String, dynamic>? sampleRow,
  ]) async {
    // 1. Check if table exists
    final tableCheck = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [tableName],
    );

    if (tableCheck.isEmpty) {
      final colDefs = <String>['"id" TEXT PRIMARY KEY'];
      if (sampleRow != null) {
        sampleRow.forEach((key, value) {
          if (key == 'id' || key.startsWith('__')) return;
          if (value is int || value is bool) {
            colDefs.add('"$key" INTEGER');
          } else if (value is double) {
            colDefs.add('"$key" REAL');
          } else {
            colDefs.add('"$key" TEXT');
          }
        });
      }

      colDefs.addAll([
        '"__sync_status" TEXT DEFAULT \'synced\'',
        '"__updated_at" TEXT',
        '"__is_deleted" INTEGER DEFAULT 0',
        '"__version" INTEGER DEFAULT 1',
      ]);

      await db.execute(
        'CREATE TABLE IF NOT EXISTS "$tableName" (${colDefs.join(', ')})',
      );
    } else if (sampleRow != null) {
      // Table exists: check if any column is missing
      final List<Map<String, dynamic>> existingCols =
          await db.rawQuery('PRAGMA table_info("$tableName")');
      final existingColNames =
          existingCols.map((c) => c['name'].toString().toLowerCase()).toSet();

      for (final key in sampleRow.keys) {
        if (key.startsWith('__')) continue;
        if (!existingColNames.contains(key.toLowerCase())) {
          final value = sampleRow[key];
          String colType = 'TEXT';
          if (value is int || value is bool) {
            colType = 'INTEGER';
          } else if (value is double) {
            colType = 'REAL';
          }
          await db
              .execute('ALTER TABLE "$tableName" ADD COLUMN "$key" $colType');
        }
      }
    }
  }

  /// Queries records from a local SQLite table, automatically filtering out deleted rows (tombstones).
  Future<List<Map<String, dynamic>>> query(
    String tableName, {
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
    bool includeDeleted = false,
    bool stripControlColumns = true,
  }) async {
    final db = await databaseProvider.database;

    final tableCheck = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [tableName],
    );
    if (tableCheck.isEmpty) {
      return [];
    }

    String effectiveWhere = where ?? '';
    final effectiveArgs = whereArgs != null ? [...whereArgs] : <dynamic>[];

    if (!includeDeleted) {
      if (effectiveWhere.isNotEmpty) {
        effectiveWhere =
            '($effectiveWhere) AND (__is_deleted = 0 OR __is_deleted IS NULL)';
      } else {
        effectiveWhere = '(__is_deleted = 0 OR __is_deleted IS NULL)';
      }
    }

    // Safe orderBy resolution to prevent crashes on non-existent columns
    String? safeOrderBy = orderBy;
    if (safeOrderBy != null) {
      final tableInfo = await db.rawQuery('PRAGMA table_info("$tableName")');
      final colNames =
          tableInfo.map((c) => c['name'].toString().toLowerCase()).toSet();

      final colMatch = RegExp(
              r'''["']?([a-zA-Z0-9_]+)["']?\s*(ASC|DESC)?''',
              caseSensitive: false)
          .firstMatch(safeOrderBy);
      if (colMatch != null) {
        final col = colMatch.group(1)!.toLowerCase();
        final dir = colMatch.group(2)?.toUpperCase() ?? 'ASC';
        if (colNames.contains(col)) {
          safeOrderBy = '"${colMatch.group(1)}" $dir';
        } else if ((col == 'created_at' || col == 'updated_at') &&
            colNames.contains('__updated_at')) {
          // Fallback to local replica timestamp if table has no native created_at column
          safeOrderBy = '"__updated_at" $dir';
        } else {
          safeOrderBy = null;
        }
      }
    }

    final results = await db.query(
      '"$tableName"',
      where: effectiveWhere.isNotEmpty ? effectiveWhere : null,
      whereArgs: effectiveArgs.isNotEmpty ? effectiveArgs : null,
      orderBy: safeOrderBy,
      limit: limit,
      offset: offset,
    );

    if (stripControlColumns) {
      return results.map((row) {
        final clean = Map<String, dynamic>.from(row);
        clean.removeWhere((key, _) => key.startsWith('__'));
        return clean;
      }).toList();
    }

    return results.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Inserts a new record into the local SQLite table and enqueues an outbox sync log.
  Future<Map<String, dynamic>> insert(
    String tableName,
    Map<String, dynamic> data,
  ) async {
    final db = await databaseProvider.database;
    final row = Map<String, dynamic>.from(data);

    final id = row['id']?.toString() ?? _uuid.v4();
    row['id'] = id;
    row['__sync_status'] = 'pending_insert';
    row['__updated_at'] = DateTime.now().toIso8601String();
    row['__is_deleted'] = 0;
    row['__version'] = (row['__version'] as int? ?? 0) + 1;

    final sqliteRow = _sanitizeForSqlite(row);

    await db.transaction((txn) async {
      await _ensureTableAndColumns(txn, tableName, sqliteRow);

      await txn.insert(
        '"$tableName"',
        sqliteRow,
        conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
      );

      // Log outbox mutation
      final payload = Map<String, dynamic>.from(data)..['id'] = id;
      await txn.insert('_sync_log', {
        'id': _uuid.v4(),
        'table_name': tableName,
        'row_id': id,
        'operation': 'insert',
        'payload': jsonEncode(payload),
        'created_at': DateTime.now().toIso8601String(),
        'status': 'pending',
        'retry_count': 0,
      });
    });

    notifyChange(tableName, 'insert', id);
    return row;
  }

  /// Updates an existing record in the local SQLite table and enqueues an outbox sync log.
  Future<void> update(
    String tableName,
    String id,
    Map<String, dynamic> data,
  ) async {
    final db = await databaseProvider.database;
    final row = Map<String, dynamic>.from(data);
    row.remove('id');
    row['__sync_status'] = 'pending_update';
    row['__updated_at'] = DateTime.now().toIso8601String();

    final sqliteRow = _sanitizeForSqlite(row);

    await db.transaction((txn) async {
      await _ensureTableAndColumns(txn, tableName, sqliteRow);

      await txn.update(
        '"$tableName"',
        sqliteRow,
        where: 'id = ?',
        whereArgs: [id],
      );

      // Coalesce rapid updates for the same record to send the latest state
      await txn.delete(
        '_sync_log',
        where: 'table_name = ? AND row_id = ? AND status = ?',
        whereArgs: [tableName, id, 'pending'],
      );

      // Log outbox mutation
      await txn.insert('_sync_log', {
        'id': _uuid.v4(),
        'table_name': tableName,
        'row_id': id,
        'operation': 'update',
        'payload': jsonEncode(data),
        'created_at': DateTime.now().toIso8601String(),
        'status': 'pending',
        'retry_count': 0,
      });
    });

    notifyChange(tableName, 'update', id);
  }

  /// Marks a record as deleted (tombstone) locally and enqueues an outbox sync log.
  Future<void> delete(String tableName, String id) async {
    final db = await databaseProvider.database;

    await db.transaction((txn) async {
      await _ensureTableAndColumns(txn, tableName);

      await txn.update(
        '"$tableName"',
        {
          '__is_deleted': 1,
          '__sync_status': 'pending_delete',
          '__updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );

      // Coalesce rapid updates for the same record to send the latest state
      await txn.delete(
        '_sync_log',
        where: 'table_name = ? AND row_id = ? AND status = ?',
        whereArgs: [tableName, id, 'pending'],
      );

      // Log outbox mutation
      await txn.insert('_sync_log', {
        'id': _uuid.v4(),
        'table_name': tableName,
        'row_id': id,
        'operation': 'delete',
        'payload': jsonEncode({'id': id}),
        'created_at': DateTime.now().toIso8601String(),
        'status': 'pending',
        'retry_count': 0,
      });
    });

    notifyChange(tableName, 'delete', id);
  }

  Map<String, dynamic> _sanitizeForSqlite(Map<String, dynamic> map) {
    final sanitized = <String, dynamic>{};
    map.forEach((k, v) {
      if (v is bool) {
        sanitized[k] = v ? 1 : 0;
      } else if (v is Map || v is List) {
        sanitized[k] = jsonEncode(v);
      } else {
        sanitized[k] = v;
      }
    });
    return sanitized;
  }

  void dispose() {
    _tableChangeController.close();
  }
}

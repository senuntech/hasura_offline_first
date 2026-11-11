import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'package:sqflite/sqflite.dart' as sqflite;

import '../contracts/hasura_connect_interface.dart';
import '../contracts/network_status.dart';
import '../core/exceptions.dart';
import '../core/network_manager.dart';
import '../local_database/database_provider.dart';
import '../local_database/local_table_repository.dart';
import '../local_database/schema_migrator.dart';
import '../network/hasura_http_client.dart';
import 'conflict_resolver.dart';

/// Bidirectional synchronization engine with Server Authority conflict resolution.
class SyncEngine {
  final DatabaseProvider databaseProvider;
  final LocalTableRepository localRepository;
  final SchemaMigrator schemaMigrator;
  final ConflictResolver conflictResolver;
  final HasuraHttpClient httpClient;
  final NetworkManager networkManager;
  final String url;
  final Map<String, String> Function() headersProvider;
  final Set<String> registeredTables;

  bool _isSyncing = false;
  StreamSubscription<NetworkStatus>? _networkSubscription;

  final StreamController<bool> _syncStateController =
      StreamController<bool>.broadcast();

  SyncEngine({
    required this.databaseProvider,
    required this.localRepository,
    required this.schemaMigrator,
    required this.conflictResolver,
    required this.httpClient,
    required this.networkManager,
    required this.url,
    required this.headersProvider,
    Set<String>? tables,
  }) : registeredTables = tables ?? {} {
    _init();
  }

  Stream<bool> get onSyncStateChanged => _syncStateController.stream;
  bool get isSyncing => _isSyncing;

  void registerTable(String table) {
    registeredTables.add(table);
  }

  void _init() {
    _networkSubscription = networkManager.onStatusChanged.listen((status) {
      if (status == NetworkStatus.online) {
        synchronize();
      }
    });
  }

  /// Triggers a full bidirectional synchronization (Schema Sync -> Push -> Pull).
  Future<void> synchronize() async {
    if (_isSyncing) return;
    if (networkManager.currentStatus != NetworkStatus.online) return;

    _isSyncing = true;
    _syncStateController.add(true);

    try {
      final db = await databaseProvider.database;

      // 1. Dynamic Schema Migration for all registered tables
      for (final table in registeredTables) {
        if (networkManager.currentStatus != NetworkStatus.online) break;
        await schemaMigrator.syncTableSchema(db, table);
      }

      // 2. Upstream Sync: Push local mutations to Hasura
      await _pushMutations(db);

      // 3. Downstream Sync: Pull server truth and apply Remote Authority
      for (final table in registeredTables) {
        if (networkManager.currentStatus != NetworkStatus.online) break;
        await _pullDeltas(db, table);
      }
    } catch (e) {
      dev.log('Sync error: $e', name: 'SyncEngine', error: e);
    } finally {
      _isSyncing = false;
      if (!_syncStateController.isClosed) {
        _syncStateController.add(false);
      }
    }
  }

  Future<void> _pushMutations(sqflite.Database db) async {
    final pendingLogs = await db.query(
      '_sync_log',
      where: "status = 'pending' OR status = 'failed'",
      orderBy: 'created_at ASC',
    );

    for (final log in pendingLogs) {
      if (networkManager.currentStatus != NetworkStatus.online) break;

      final logId = log['id'].toString();
      final table = log['table_name'].toString();
      final rowId = log['row_id'].toString();
      final operation = log['operation'].toString();
      final payloadStr = log['payload']?.toString();
      final Map<String, dynamic> payload =
          payloadStr != null ? jsonDecode(payloadStr) : {};

      try {
        if (operation == 'insert') {
          await _pushInsert(table, payload);
          await _markLogSynced(db, logId, table, rowId);
        } else if (operation == 'update') {
          final success = await _pushUpdate(table, rowId, payload);
          if (success) {
            await _markLogSynced(db, logId, table, rowId);
          } else {
            // SERVER AUTHORITY: Record was deleted on server by another user
            await conflictResolver.handleRemoteNotFound(
              db,
              tableName: table,
              rowId: rowId,
              logId: logId,
            );
            localRepository.notifyChange(table, 'delete', rowId);
          }
        } else if (operation == 'delete') {
          await _pushDelete(table, rowId);
          await db.delete('_sync_log', where: 'id = ?', whereArgs: [logId]);
          // Permanently remove tombstone row after server confirmation
          await db.delete(table, where: 'id = ?', whereArgs: [rowId]);
        }
      } catch (e) {
        // If it was a GraphQL error stating record not found, trigger server authority
        if (e is HasuraRequestError &&
            e.message.toLowerCase().contains('not found')) {
          await conflictResolver.handleRemoteNotFound(
            db,
            tableName: table,
            rowId: rowId,
            logId: logId,
          );
          localRepository.notifyChange(table, 'delete', rowId);
        } else {
          // Increment retry count
          await db.update(
            '_sync_log',
            {
              'status': 'failed',
              'retry_count': (log['retry_count'] as int? ?? 0) + 1,
              'last_error': e.toString(),
            },
            where: 'id = ?',
            whereArgs: [logId],
          );
        }
      }
    }
  }

  Future<void> _pushInsert(String table, Map<String, dynamic> payload) async {
    final cleanPayload = Map<String, dynamic>.from(payload)
      ..removeWhere((k, _) => k.startsWith('__'));

    final mutationDoc = '''
      mutation PushInsert_$table(\$object: ${table}_insert_input!) {
        insert_${table}_one(object: \$object) {
          id
        }
      }
    ''';

    final request = Request(
      url: url,
      document: mutationDoc,
      variables: {'object': cleanPayload},
      headers: headersProvider(),
      type: 'mutation',
    );

    await httpClient.execute(request);
  }

  Future<bool> _pushUpdate(
    String table,
    String id,
    Map<String, dynamic> payload,
  ) async {
    final cleanPayload = Map<String, dynamic>.from(payload)
      ..removeWhere((k, _) => k.startsWith('__') || k == 'id');

    final mutationDoc = '''
      mutation PushUpdate_$table(\$id: uuid!, \$set: ${table}_set_input!) {
        update_${table}_by_pk(pk_columns: {id: \$id}, _set: \$set) {
          id
        }
      }
    ''';

    final request = Request(
      url: url,
      document: mutationDoc,
      variables: {'id': id, 'set': cleanPayload},
      headers: headersProvider(),
      type: 'mutation',
    );

    final res = await httpClient.execute(request);
    if (res == null) {
      // Hasura returns null if pk_columns did not match any row
      return false;
    }
    return true;
  }

  Future<void> _pushDelete(String table, String id) async {
    final mutationDoc = '''
      mutation PushDelete_$table(\$id: uuid!) {
        delete_${table}_by_pk(id: \$id) {
          id
        }
      }
    ''';

    final request = Request(
      url: url,
      document: mutationDoc,
      variables: {'id': id},
      headers: headersProvider(),
      type: 'mutation',
    );

    await httpClient.execute(request);
  }

  Future<void> _markLogSynced(
    sqflite.Database db,
    String logId,
    String table,
    String rowId,
  ) async {
    await db.delete('_sync_log', where: 'id = ?', whereArgs: [logId]);
    await db.update(
      table,
      {'__sync_status': 'synced'},
      where: 'id = ?',
      whereArgs: [rowId],
    );
  }

  Future<void> _pullDeltas(sqflite.Database db, String table) async {
    // Check if table exists locally before pulling deltas
    final tableCheck = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [table],
    );
    if (tableCheck.isEmpty) {
      return;
    }

    // Introspect table columns from metadata to build dynamic query
    final meta = await db.query(
      '_schema_metadata',
      where: 'table_name = ?',
      whereArgs: [table],
    );

    String fieldsSelection = 'id';
    if (meta.isNotEmpty && meta.first['columns_json'] != null) {
      final List<dynamic> cols =
          jsonDecode(meta.first['columns_json'] as String);
      final validCols = cols
          .map((c) => c['name']?.toString())
          .where((name) => name != null && !name.startsWith('__'))
          .toList();
      if (validCols.isNotEmpty) {
        fieldsSelection = validCols.join('\n');
      }
    }

    final dynamicQuery = '''
      query Pull_$table {
        $table {
          $fieldsSelection
        }
      }
    ''';

    final request = Request(
      url: url,
      document: dynamicQuery,
      headers: headersProvider(),
      key: table,
      type: 'query',
    );

    final response = await httpClient.execute(request);
    if (response is List) {
      final remoteRows =
          response.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      final remoteIds = remoteRows.map((r) => r['id'].toString()).toSet();

      // SERVER AUTHORITY: Delete local rows marked as 'synced' that no longer exist on server
      final localSyncedRows = await db.query(
        table,
        columns: ['id'],
        where: "__sync_status = 'synced'",
      );
      for (final localRow in localSyncedRows) {
        final localId = localRow['id'].toString();
        if (!remoteIds.contains(localId)) {
          dev.log(
            'Server Authority (Pull): Purging locally missing row "$localId" in table "$table"',
            name: 'SyncEngine',
          );
          await db.delete(table, where: 'id = ?', whereArgs: [localId]);
        }
      }

      // UPSERT remote rows into local SQLite
      for (final remoteRow in remoteRows) {
        final id = remoteRow['id'].toString();

        // Check if there is an offline modification pending for this row
        final localExisting = await db.query(
          table,
          where: 'id = ?',
          whereArgs: [id],
        );

        if (localExisting.isNotEmpty) {
          final localSyncStatus = localExisting.first['__sync_status'];
          if (localSyncStatus != null && localSyncStatus != 'synced') {
            // Local has pending modification, but Server is Authority for conflicting updates
            final resolved = conflictResolver.resolveServerWin(
              localData: localExisting.first,
              remoteData: remoteRow,
            );
            await db.update(table, _sanitize(resolved),
                where: 'id = ?', whereArgs: [id]);
            continue;
          }
        }

        // Fresh or synced record: insert or replace directly
        final sanitized = _sanitize(remoteRow)
          ..['__sync_status'] = 'synced'
          ..['__is_deleted'] = 0
          ..['__updated_at'] = DateTime.now().toIso8601String();

        await db.insert(
          table,
          sanitized,
          conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
        );
      }

      localRepository.notifyChange(table, 'sync');
    }
  }

  Map<String, dynamic> _sanitize(Map<String, dynamic> map) {
    final clean = <String, dynamic>{};
    map.forEach((k, v) {
      if (v is bool) {
        clean[k] = v ? 1 : 0;
      } else if (v is Map || v is List) {
        clean[k] = jsonEncode(v);
      } else {
        clean[k] = v;
      }
    });
    return clean;
  }

  void dispose() {
    _networkSubscription?.cancel();
    _syncStateController.close();
  }
}

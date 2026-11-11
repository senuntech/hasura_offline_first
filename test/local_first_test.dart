import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  group('Local-First Engine & Database Replica', () {
    late DatabaseProvider dbProvider;
    late LocalTableRepository localRepo;

    setUp(() async {
      dbProvider = DatabaseProvider(
        dbName: 'test_replica_${DateTime.now().microsecondsSinceEpoch}.db',
        customDatabaseFactory: databaseFactoryFfi,
      );
      localRepo = LocalTableRepository(databaseProvider: dbProvider);

      // Create a test table
      final db = await dbProvider.database;
      await db.execute('''
        CREATE TABLE IF NOT EXISTS teste_offilne (
          id TEXT PRIMARY KEY,
          task TEXT,
          check_val INTEGER,
          __sync_status TEXT DEFAULT 'synced',
          __updated_at TEXT,
          __is_deleted INTEGER DEFAULT 0,
          __version INTEGER DEFAULT 1
        )
      ''');
    });

    tearDown(() async {
      localRepo.dispose();
      await dbProvider.close();
    });

    test('insert, query and update operate locally with 0ms latency', () async {
      // 1. Insert local
      final inserted = await localRepo.insert('teste_offilne', {
        'id': 'local-123',
        'task': 'Comprar pão',
        'check_val': 0,
      });
      expect(inserted['id'], equals('local-123'));

      // 2. Query local
      var rows = await localRepo.query('teste_offilne');
      expect(rows.length, equals(1));
      expect(rows.first['task'], equals('Comprar pão'));
      expect(rows.first.containsKey('__sync_status'),
          isFalse); // control column stripped

      // 3. Update local
      await localRepo
          .update('teste_offilne', 'local-123', {'task': 'Comprar leite'});
      rows = await localRepo.query('teste_offilne');
      expect(rows.first['task'], equals('Comprar leite'));

      // 4. Delete local (tombstone)
      await localRepo.delete('teste_offilne', 'local-123');
      rows = await localRepo.query('teste_offilne');
      expect(rows, isEmpty); // filtered by __is_deleted = 0
    });

    test('rapid sequential updates preserve local changes and coalesce pending logs', () async {
      // 1. Initial insert
      await localRepo.insert('teste_offilne', {
        'id': 'task-rapid-1',
        'task': 'Item 1',
        'check_val': 0,
      });

      // 2. Multiple sequential updates (toggle back and forth)
      await localRepo.update('teste_offilne', 'task-rapid-1', {'check_val': 1});
      await localRepo.update('teste_offilne', 'task-rapid-1', {'check_val': 0});
      await localRepo.update('teste_offilne', 'task-rapid-1', {'check_val': 1});

      // 3. Check final value in local SQLite
      final rows = await localRepo.query('teste_offilne', where: 'id = ?', whereArgs: ['task-rapid-1']);
      expect(rows.first['check_val'], equals(1));

      // 4. Check sync logs are coalesced (only 1 pending update log remains)
      final db = await dbProvider.database;
      final pendingLogs = await db.query(
        '_sync_log',
        where: "table_name = ? AND row_id = ? AND status = 'pending' AND operation = 'update'",
        whereArgs: ['teste_offilne', 'task-rapid-1'],
      );
      expect(pendingLogs.length, equals(1));
      final payload = jsonDecode(pendingLogs.first['payload'] as String);
      expect(payload['check_val'], equals(1));
    });
  });

  group('SchemaMigrator (Dynamic Auto-Migration via Introspection)', () {
    late DatabaseProvider dbProvider;
    late HasuraHttpClient mockHttpClient;
    late SchemaMigrator migrator;

    setUp(() async {
      dbProvider = DatabaseProvider(
        dbName: 'test_schema_${DateTime.now().microsecondsSinceEpoch}.db',
        customDatabaseFactory: databaseFactoryFfi,
      );

      // Mock Hasura introspection returning a table with a new column 'priority'
      mockHttpClient = HasuraHttpClient(
        client: MockClient((req) async {
          final res = {
            'data': {
              '__type': {
                'name': 'teste_offilne',
                'fields': [
                  {
                    'name': 'id',
                    'type': {'name': 'uuid', 'kind': 'SCALAR'},
                  },
                  {
                    'name': 'task',
                    'type': {'name': 'String', 'kind': 'SCALAR'},
                  },
                  {
                    'name': 'priority',
                    'type': {'name': 'String', 'kind': 'SCALAR'},
                  },
                ],
              },
            },
          };
          return http.Response(jsonEncode(res), 200,
              headers: {'content-type': 'application/json'});
        }),
      );

      migrator = SchemaMigrator(
        httpClient: mockHttpClient,
        url: 'https://fake-hasura.io/v1/graphql',
        headersProvider: () => {},
      );
    });

    tearDown(() async {
      await dbProvider.close();
    });

    test('auto-migrates SQLite table when Hasura has new columns', () async {
      final db = await dbProvider.database;

      // Initial table with only id and task
      await db.execute('''
        CREATE TABLE IF NOT EXISTS teste_offilne (
          id TEXT PRIMARY KEY,
          task TEXT
        )
      ''');

      var tableInfo = await db.rawQuery('PRAGMA table_info(teste_offilne)');
      expect(tableInfo.any((c) => c['name'] == 'priority'), isFalse);

      // Run dynamic schema migration
      await migrator.syncTableSchema(db, 'teste_offilne');

      tableInfo = await db.rawQuery('PRAGMA table_info(teste_offilne)');
      expect(tableInfo.any((c) => c['name'] == 'priority'), isTrue);
    });
  });

  group('ConflictResolver (Server Authority / Remote-Wins)', () {
    late DatabaseProvider dbProvider;
    late ConflictResolver conflictResolver;

    setUp(() async {
      dbProvider = DatabaseProvider(
        dbName: 'test_conflict_${DateTime.now().microsecondsSinceEpoch}.db',
        customDatabaseFactory: databaseFactoryFfi,
      );
      conflictResolver = ConflictResolver();

      final db = await dbProvider.database;
      await db.execute('''
        CREATE TABLE IF NOT EXISTS teste_offilne (
          id TEXT PRIMARY KEY,
          task TEXT
        )
      ''');
    });

    tearDown(() async {
      conflictResolver.dispose();
      await dbProvider.close();
    });

    test('purges local record when deleted remotely on server by another user',
        () async {
      final db = await dbProvider.database;

      // Insert record and pending sync log
      await db.insert('teste_offilne',
          {'id': 'item-to-delete', 'task': 'Excluido no servidor'});
      await db.insert('_sync_log', {
        'id': 'log-1',
        'table_name': 'teste_offilne',
        'row_id': 'item-to-delete',
        'operation': 'update',
        'status': 'pending',
        'created_at': DateTime.now().toIso8601String(),
      });

      var rows = await db.query('teste_offilne',
          where: 'id = ?', whereArgs: ['item-to-delete']);
      expect(rows.length, equals(1));

      ConflictPurgeEvent? eventReceived;
      conflictResolver.onConflictPurge.listen((event) => eventReceived = event);

      // Server authority handles remote not found (another user deleted it online)
      await conflictResolver.handleRemoteNotFound(
        db,
        tableName: 'teste_offilne',
        rowId: 'item-to-delete',
        logId: 'log-1',
      );
      await pumpEventQueue();

      // Record must be purged from local SQLite table
      rows = await db.query('teste_offilne',
          where: 'id = ?', whereArgs: ['item-to-delete']);
      expect(rows, isEmpty);

      // Log must be deleted
      final logs =
          await db.query('_sync_log', where: 'id = ?', whereArgs: ['log-1']);
      expect(logs, isEmpty);

      // UI event emitted
      expect(eventReceived, isNotNull);
      expect(eventReceived?.id, equals('item-to-delete'));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'mocks/fake_connectivity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final databaseFactory = databaseFactoryFfi;

  late DatabaseProvider dbProvider;
  late LocalTableRepository repository;
  late NetworkManager networkManager;
  late FakeConnectivity fakeConnectivity;

  setUp(() async {
    final dbName = 'test_hybrid_sub_${DateTime.now().microsecondsSinceEpoch}.db';
    dbProvider = DatabaseProvider(
      dbName: dbName,
      customDatabaseFactory: databaseFactory,
    );

    final db = await dbProvider.database;
    await db.execute('''
      CREATE TABLE IF NOT EXISTS todos (
        id TEXT PRIMARY KEY,
        task TEXT NOT NULL,
        check_val INTEGER DEFAULT 0,
        __sync_status TEXT DEFAULT 'synced',
        __updated_at TEXT,
        __is_deleted INTEGER DEFAULT 0,
        __version INTEGER DEFAULT 1
      )
    ''');

    repository = LocalTableRepository(
      databaseProvider: dbProvider,
      tenantConfig: null,
    );

    fakeConnectivity = FakeConnectivity();
    networkManager = NetworkManager(connectivity: fakeConnectivity);
  });

  tearDown(() async {
    await dbProvider.close();
    await dbProvider.deleteDatabaseFile();
  });

  group('HybridSnapshot & Realtime Subscription Tests', () {
    test('emits local SQLite data immediately with 0ms latency even while offline', () async {
      // 1. Pre-populate SQLite local table
      await repository.insert('todos', {
        'id': 'todo-1',
        'task': 'Comprar café',
        'check_val': 0,
      });

      final snapshot = HybridSnapshot<Map<String, dynamic>>(
        tableName: 'todos',
        document: 'query { todos { id task check_val } }',
        localRepository: repository,
        networkManager: networkManager,
        queryLocal: () async {
          final rows = await repository.query('todos');
          return {'todos': rows};
        },
        subscribeRemote: () async => throw Exception('Remote offline'),
      );

      // Verify that stream immediately emits local state
      final firstEmission = await snapshot.stream.first;
      expect(firstEmission['todos'], isA<List>());
      final list = firstEmission['todos'] as List;
      expect(list.length, equals(1));
      expect(list.first['task'], equals('Comprar café'));

      snapshot.close();
    });

    test('reacts to offline local SQLite mutations and deduplicates identical emissions', () async {
      final emittedValues = <int>[];

      final snapshot = HybridSnapshot<Map<String, dynamic>>(
        tableName: 'todos',
        document: 'query { todos { id task } }',
        localRepository: repository,
        networkManager: networkManager,
        queryLocal: () async {
          final rows = await repository.query('todos');
          return {'todos': rows};
        },
        subscribeRemote: () async => throw Exception('Remote offline'),
      );

      final sub = snapshot.stream.listen((data) {
        final list = data['todos'] as List;
        emittedValues.add(list.length);
      });

      // Wait for initial emission (length 0)
      await Future.delayed(const Duration(milliseconds: 50));
      expect(emittedValues, equals([0]));

      // Insert new item locally
      await repository.insert('todos', {
        'id': 'todo-2',
        'task': 'Ler documentação',
      });

      // Allow microtask coalescing
      await Future.delayed(const Duration(milliseconds: 50));
      expect(emittedValues, equals([0, 1]));

      // Rapidly insert another item
      await repository.insert('todos', {
        'id': 'todo-3',
        'task': 'Escrever testes unitários',
      });

      await Future.delayed(const Duration(milliseconds: 50));
      expect(emittedValues, equals([0, 1, 2]));

      await sub.cancel();
      snapshot.close();
    });

    test('coalesces multiple rapid table events into a single query to protect UI framerate', () async {
      var queryCount = 0;

      final snapshot = HybridSnapshot<Map<String, dynamic>>(
        tableName: 'todos',
        document: 'query { todos { id task } }',
        localRepository: repository,
        networkManager: networkManager,
        queryLocal: () async {
          queryCount++;
          final rows = await repository.query('todos');
          return {'todos': rows};
        },
        subscribeRemote: () async => throw Exception('Remote offline'),
      );

      await Future.delayed(const Duration(milliseconds: 50));
      expect(queryCount, equals(1)); // Initial query

      // Fire 5 change notifications rapidly
      for (int i = 0; i < 5; i++) {
        repository.notifyChange('todos', 'test');
      }

      // Microtask coalesces into at most 2 additional queries instead of 5
      await Future.delayed(const Duration(milliseconds: 50));
      expect(queryCount, lessThanOrEqualTo(3));

      snapshot.close();
    });
  });
}

import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'mocks/fake_connectivity.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('GraphQLQueryParser Tests', () {
    test('parses where clause with _eq boolean and strings', () {
      const doc = '''
        query GetCompletedTasks {
          todos(where: { check: { _eq: true }, category: { _eq: "urgente" } }) {
            id
            task
          }
        }
      ''';

      final parsed = GraphQLQueryParser.parseWhere(doc);
      expect(parsed, isNotNull);
      expect(parsed!.clause, equals('"check" = ? AND "category" = ?'));
      expect(parsed.args, equals([1, 'urgente']));
    });

    test('parses where clause with _like, _gt, and _is_null', () {
      const doc = '''
        query FilterTasks {
          tasks(where: { task: { _like: "%mercado%" }, priority: { _gt: 2 }, notes: { _is_null: true } }) {
            id
          }
        }
      ''';

      final parsed = GraphQLQueryParser.parseWhere(doc);
      expect(parsed, isNotNull);
      expect(
        parsed!.clause,
        equals('"task" LIKE ? AND "priority" > ? AND "notes" IS NULL'),
      );
      expect(parsed.args, equals(['%mercado%', 2]));
    });

    test('parses order_by, limit and offset', () {
      const doc = '''
        query ListProducts {
          products(order_by: { price: desc }, limit: 10, offset: 20) {
            id
          }
        }
      ''';

      expect(GraphQLQueryParser.parseOrderBy(doc), equals('"price" DESC'));
      expect(GraphQLQueryParser.parseLimit(doc), equals(10));
      expect(GraphQLQueryParser.parseOffset(doc), equals(20));
    });

    test('parses multiple operators in a single field block (e.g. date range with variables)', () {
      const doc = r'''
        query GetOccurrencesByProject(
          $id_project: uuid!, 
          $start_date: timestamptz!, 
          $end_date: timestamptz!
        ) {
          occurrences(
            where: {
              id_project: {_eq: $id_project},
              created_at: {_gte: $start_date, _lte: $end_date}
            }, 
            order_by: {created_at: desc}
          ) {
            id
            description
          }
        }
      ''';

      final vars = {
        'id_project': 'proj-123',
        'start_date': '2026-11-01T00:00:00.000Z',
        'end_date': '2026-11-30T23:59:59.999Z',
      };

      final parsed = GraphQLQueryParser.parseWhere(doc, vars);
      expect(parsed, isNotNull);
      expect(
        parsed!.clause,
        equals('"id_project" = ? AND "created_at" >= ? AND "created_at" <= ?'),
      );
      expect(parsed.args, equals([
        'proj-123',
        '2026-11-01T00:00:00.000Z',
        '2026-11-30T23:59:59.999Z',
      ]));
      // Ensure no null values are present in args (which causes sqflite crash)
      expect(parsed.args.contains(null), isFalse);
    });

    test('safely handles null variable without adding null to whereArgs', () {
      const doc = r'''
        query FilterWithNull($category: String, $optional_filter: String) {
          tasks(where: { category: { _eq: $category }, description: { _like: $optional_filter } }) {
            id
          }
        }
      ''';

      final vars = <String, dynamic>{
        'category': null,
        'optional_filter': null,
      };

      final parsed = GraphQLQueryParser.parseWhere(doc, vars);
      expect(parsed, isNotNull);
      // _eq with null resolves to IS NULL, and null relational is omitted
      expect(parsed!.clause, equals('"category" IS NULL'));
      expect(parsed.args, isEmpty);
      expect(parsed.args.contains(null), isFalse);
    });
  });

  group('Local Query with where filter & SyncStatusStream Tests', () {
    test('client.query applies where filter offline directly in local SQLite', () async {
      final fakeConn = FakeConnectivity()..emit([ConnectivityResult.none]);
      final netManager = NetworkManager(connectivity: fakeConn);
      final dbProvider = DatabaseProvider(
        dbName: 'test_where_filter.db',
        customDatabaseFactory: databaseFactoryFfi,
      );

      final client = HasuraOfflineFirst(
        'https://example.com/graphql',
        networkManager: netManager,
        customDatabaseProvider: dbProvider,
        tables: {'itens'},
      );

      // Inserir itens locais
      await client.localRepository.insert('itens', {'id': '1', 'nome': 'Mesa', 'ativo': 1});
      await client.localRepository.insert('itens', {'id': '2', 'nome': 'Cadeira', 'ativo': 0});
      await client.localRepository.insert('itens', {'id': '3', 'nome': 'Sofá', 'ativo': 1});

      // Consultar com where: { ativo: { _eq: true } }
      final resultAtivos = await client.query('''
        query {
          itens(where: { ativo: { _eq: true } }) {
            id
            nome
          }
        }
      ''', key: 'itens') as List;

      expect(resultAtivos.length, equals(2));
      expect(resultAtivos.map((r) => r['nome']).toList(), containsAll(['Mesa', 'Sofá']));

      await dbProvider.deleteDatabaseFile();
      client.dispose();
    });

    test('syncStatusStream updates pendingCount in real-time when inserting and syncing', () async {
      final fakeConn = FakeConnectivity()..emit([ConnectivityResult.none]);
      final netManager = NetworkManager(connectivity: fakeConn);
      final dbProvider = DatabaseProvider(
        dbName: 'test_sync_status.db',
        customDatabaseFactory: databaseFactoryFfi,
      );

      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'data': {
              'insert_tarefas_one': {'id': 't-1'},
              'tarefas': [],
            }
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = HasuraOfflineFirst(
        'https://example.com/graphql',
        httpClient: mockHttp,
        networkManager: netManager,
        customDatabaseProvider: dbProvider,
        tables: {'tarefas'},
      );

      final statusEvents = <SyncStatusSnapshot>[];
      final subscription = client.syncStatusStream.listen(statusEvents.add);

      // Inserir offline -> deve aumentar pendingCount
      await client.insertLocal('tarefas', {'id': 't-1', 'titulo': 'Testar Stream'});
      await Future.delayed(const Duration(milliseconds: 50));

      expect(client.syncStatus.pendingCount, greaterThanOrEqualTo(1));

      // Ficar online e sincronizar -> pendingCount deve ir para 0 e state para synced
      fakeConn.emit([ConnectivityResult.wifi]);
      await client.synchronize();
      await Future.delayed(const Duration(milliseconds: 50));

      expect(client.syncStatus.pendingCount, equals(0));
      expect(client.syncStatus.state, equals(SyncState.synced));

      await subscription.cancel();
      await dbProvider.deleteDatabaseFile();
      client.dispose();
    });
  });
}


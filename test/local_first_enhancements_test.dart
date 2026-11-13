import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';
import 'package:hasura_offline_first/src/local_database/graphql_query_parser.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'mocks/fake_connectivity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('Local-First Enhancements Tests', () {
    test('hasNestedSelections detects nested GraphQL object relations', () {
      const flatQuery = '''
        query GetUsers {
          user {
            id
            name
            email
          }
        }
      ''';
      expect(GraphQLQueryParser.hasNestedSelections(flatQuery), isFalse);

      const flatQueryWithWhere = '''
        query SearchUsers(\$email: String!) {
          user(where: { email: { _eq: \$email } }) {
            id
            name
          }
        }
      ''';
      expect(
          GraphQLQueryParser.hasNestedSelections(flatQueryWithWhere), isFalse);

      const nestedRelationalQuery = '''
        query SearchEnterprise(\$id_user: uuid!) {
          user_enterprise(where: { id_user: { _eq: \$id_user } }) {
            id_user
            enterprise {
              id
              name
              document
            }
          }
        }
      ''';
      expect(GraphQLQueryParser.hasNestedSelections(nestedRelationalQuery),
          isTrue);
    });

    test('update_by_pk mutation returns full local entity merged with updates',
        () async {
      final fakeConn = FakeConnectivity()..emit([ConnectivityResult.wifi]);
      final netManager = NetworkManager(connectivity: fakeConn);
      final dbProvider = DatabaseProvider(
        dbName: 'test_full_entity_${DateTime.now().microsecondsSinceEpoch}.db',
        customDatabaseFactory: databaseFactoryFfi,
      );

      final client = HasuraOfflineFirst(
        'https://example.com/graphql',
        networkManager: netManager,
        customDatabaseProvider: dbProvider,
        tables: {'user'},
      );

      // Pre-insert full user in local SQLite
      await client.localRepository.insert('user', {
        'id': 'user-123',
        'name': 'Cristian',
        'email': 'cristian@example.com',
        'last_visit': '2026-01-01T00:00:00Z',
      });

      // Execute update_user_by_pk mutation that only supplies last_visit
      final result = await client.mutation(
        r'''
        mutation UpdateUserVisit($id: uuid!, $lastVisit: timestamptz!) {
          update_user_by_pk(pk_columns: {id: $id}, _set: {last_visit: $lastVisit}) {
            id
            name
            email
            last_visit
          }
        }
        ''',
        variables: {
          'id': 'user-123',
          'lastVisit': '2026-11-13T18:00:00Z',
        },
      );

      expect(result, isNotNull);
      final updatedMap = result['update_user_by_pk'] as Map<String, dynamic>;
      expect(updatedMap['id'], equals('user-123'));
      expect(updatedMap['name'], equals('Cristian'));
      expect(updatedMap['email'], equals('cristian@example.com'));
      expect(updatedMap['last_visit'], equals('2026-11-13T18:00:00Z'));

      await dbProvider.deleteDatabaseFile();
      client.dispose();
    });

    test(
        'query with nested relations falls back to remote pipeline when online',
        () async {
      final fakeConn = FakeConnectivity()..emit([ConnectivityResult.wifi]);
      final netManager = NetworkManager(connectivity: fakeConn);
      final dbProvider = DatabaseProvider(
        dbName:
            'test_nested_fallback_${DateTime.now().microsecondsSinceEpoch}.db',
        customDatabaseFactory: databaseFactoryFfi,
      );

      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'data': {
              'user_enterprise': [
                {
                  'id_user': 'user-1',
                  'enterprise': {
                    'id': 'ent-1',
                    'name': 'Construtora Exemplo',
                  },
                }
              ]
            }
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = HasuraOfflineFirst(
        'https://example.com/graphql',
        networkManager: netManager,
        customDatabaseProvider: dbProvider,
        httpClient: mockHttp,
        tables: {'user_enterprise', 'enterprise'},
      );

      const queryDoc = '''
        query SearchEnterprise(\$id_user: uuid!) {
          user_enterprise(where: { id_user: { _eq: \$id_user } }) {
            id_user
            enterprise {
              id
              name
            }
          }
        }
      ''';

      final response =
          await client.query(queryDoc, variables: {'id_user': 'user-1'});
      expect(response, isNotNull);
      final list = response['user_enterprise'] as List;
      expect(list.length, equals(1));
      expect(list.first['enterprise']['name'], equals('Construtora Exemplo'));

      await dbProvider.deleteDatabaseFile();
      client.dispose();
    });

    test('local query automatically converts SQLite INTEGER (1/0) to bool when metadata marks column as Boolean', () async {
      final fakeConn = FakeConnectivity()..emit([ConnectivityResult.none]);
      final netManager = NetworkManager(connectivity: fakeConn);
      final dbProvider = DatabaseProvider(
        dbName: 'test_boolean_conversion_${DateTime.now().microsecondsSinceEpoch}.db',
        customDatabaseFactory: databaseFactoryFfi,
      );

      final client = HasuraOfflineFirst(
        'https://example.com/graphql',
        networkManager: netManager,
        customDatabaseProvider: dbProvider,
        tables: {'access_profile'},
      );

      final db = await dbProvider.database;

      // Seed schema metadata marking 'edit_enterprise' and 'signature' as Boolean
      await db.rawInsert('''
        INSERT OR REPLACE INTO _schema_metadata (table_name, columns_json, schema_hash, updated_at)
        VALUES (?, ?, ?, ?)
      ''', [
        'access_profile',
        jsonEncode([
          {'name': 'id', 'type': 'uuid'},
          {'name': 'description', 'type': 'String'},
          {'name': 'edit_enterprise', 'type': 'Boolean'},
          {'name': 'signature', 'type': 'Boolean'},
        ]),
        '1',
        DateTime.now().toIso8601String(),
      ]);

      // Insert record in SQLite storing boolean as integer (1 and 0)
      await client.localRepository.insert('access_profile', {
        'id': 'prof-1',
        'description': 'Admin',
        'edit_enterprise': 1,
        'signature': 0,
      });

      final rows = await client.localRepository.query('access_profile');
      expect(rows.length, equals(1));
      expect(rows.first['edit_enterprise'], isA<bool>());
      expect(rows.first['edit_enterprise'], isTrue);
      expect(rows.first['signature'], isA<bool>());
      expect(rows.first['signature'], isFalse);

      await dbProvider.deleteDatabaseFile();
      client.dispose();
    });

    test('mutation extracts correct table name even when operation declares _insert_input in header', () async {
      final fakeConn = FakeConnectivity()..emit([ConnectivityResult.none]);
      final netManager = NetworkManager(connectivity: fakeConn);
      final dbProvider = DatabaseProvider(
        dbName: 'test_insert_input_header_${DateTime.now().microsecondsSinceEpoch}.db',
        customDatabaseFactory: databaseFactoryFfi,
      );

      final client = HasuraOfflineFirst(
        'https://example.com/graphql',
        networkManager: netManager,
        customDatabaseProvider: dbProvider,
        tables: {'access_profile'},
      );

      const doc = r'''
        mutation CreateAccessProfile($object: access_profile_insert_input!) {
          insert_access_profile_one(object: $object) {
            id
            description
            edit_enterprise
            signature
            id_enterprise
          }
        }
      ''';

      final result = await client.mutation(
        doc,
        variables: {
          'object': {
            'description': 'Engenheiro',
            'edit_enterprise': true,
            'signature': false,
            'id_enterprise': 'ent-1',
          }
        },
      );

      expect(result, isNotNull);
      final inserted = result['insert_access_profile_one'] as Map<String, dynamic>?;
      expect(inserted, isNotNull);
      expect(inserted!['id'], isNotEmpty);
      expect(inserted['description'], equals('Engenheiro'));
      expect(inserted['id_enterprise'], equals('ent-1'));

      final localRows = await client.localRepository.query('access_profile');
      expect(localRows.length, equals(1));
      expect(localRows.first['description'], equals('Engenheiro'));

      await dbProvider.deleteDatabaseFile();
      client.dispose();
    });

    test('query with multiple root fields extracts all fields and executes correctly', () async {
      const multiDoc = '''
        query GetProjectsForUser(\$id_enterprise: uuid!, \$id_user: uuid!) {
          user_enterprise(where: {id_enterprise: {_eq: \$id_enterprise}, id_user: {_eq: \$id_user}}) {
            id_root
            id_project
          }
          project(where: {id_enterprise: {_eq: \$id_enterprise}}, order_by: {created_at: desc}) {
            id
            name
          }
        }
      ''';

      final roots = GraphQLQueryParser.extractRootFields(multiDoc);
      expect(roots, equals(['user_enterprise', 'project']));

      final fakeConn = FakeConnectivity()..emit([ConnectivityResult.wifi]);
      final netManager = NetworkManager(connectivity: fakeConn);
      final dbProvider = DatabaseProvider(
        dbName: 'test_multi_root_${DateTime.now().microsecondsSinceEpoch}.db',
        customDatabaseFactory: databaseFactoryFfi,
      );

      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'data': {
              'user_enterprise': [
                {'id_root': true, 'id_project': null}
              ],
              'project': [
                {'id': 'proj-1', 'name': 'Edifício Horizonte'}
              ],
            }
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = HasuraOfflineFirst(
        'https://example.com/graphql',
        networkManager: netManager,
        customDatabaseProvider: dbProvider,
        httpClient: mockHttp,
        tables: {'user_enterprise', 'project'},
      );

      final result = await client.query(
        multiDoc,
        variables: {
          'id_enterprise': 'ent-1',
          'id_user': 'user-1',
        },
      );

      expect(result, isNotNull);
      expect(result['user_enterprise'], isA<List>());
      expect((result['user_enterprise'] as List).first['id_root'], isTrue);
      expect(result['project'], isA<List>());
      expect((result['project'] as List).first['name'], equals('Edifício Horizonte'));

      await dbProvider.deleteDatabaseFile();
      client.dispose();
    });
  });
}

import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'mocks/fake_connectivity.dart';

void main() {
  group('HasuraOfflineFirst Client', () {
    late FakeConnectivity fakeConnectivity;
    late NetworkManager networkManager;
    late InMemoryStorageDriver storageDriver;
    late http.Client mockHttpClient;
    late HasuraOfflineFirst client;

    final mockResponseData = {
      'data': {
        'users': [
          {'id': '1', 'name': 'Alice'},
        ],
      },
    };

    setUp(() {
      fakeConnectivity = FakeConnectivity();
      networkManager = NetworkManager(connectivity: fakeConnectivity);
      storageDriver = InMemoryStorageDriver();

      mockHttpClient = MockClient((request) async {
        return http.Response(
          jsonEncode(mockResponseData),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      client = HasuraOfflineFirst(
        'https://fake-hasura.io/v1/graphql',
        networkManager: networkManager,
        storageDriver: storageDriver,
        httpClient: mockHttpClient,
      );
    });

    tearDown(() {
      client.dispose();
      fakeConnectivity.dispose();
    });

    test('online query fetches from server and caches result', () async {
      const doc = 'query GetUsers { users { id name } }';
      final response = await client.query(doc);

      expect(response, equals(mockResponseData['data']));

      final hash = HashGenerator.generate(doc);
      final cached = await storageDriver.getCache(hash);
      expect(cached, isNotNull);
      expect(cached?['users'], equals(mockResponseData['data']!['users']));
    });

    test('offline query returns cached response on cache hit', () async {
      const doc = 'query GetUsers { users { id name } }';

      // 1. Fetch online first to populate cache
      await client.query(doc);

      // 2. Go offline
      fakeConnectivity.emit([ConnectivityResult.none]);
      await pumpEventQueue();

      // 3. Query again offline
      final offlineResult = await client.query(doc);
      expect(offlineResult, equals(mockResponseData['data']));
    });

    test('offline query throws HasuraCacheMissException on cache miss', () async {
      // Go offline
      fakeConnectivity.emit([ConnectivityResult.none]);
      await pumpEventQueue();

      const doc = 'query UncachedQuery { uncached }';

      expect(
        () => client.query(doc),
        throwsA(isA<HasuraCacheMissException>()),
      );
    });

    test('offline mutation enqueues into Outbox and synchronizes when back online', () async {
      // 1. Go offline
      fakeConnectivity.emit([ConnectivityResult.none]);
      await pumpEventQueue();

      const mutationDoc = 'mutation AddUser { insert_users(objects: {}) }';

      // 2. Execute mutation offline
      final result = await client.mutation(mutationDoc);
      expect(result['_offline'], isTrue);
      expect(result['status'], equals('enqueued'));

      // Check outbox has 1 pending item
      final pendingBefore = await storageDriver.getPendingOutbox();
      expect(pendingBefore.length, equals(1));

      // 3. Go back online -> automatically triggers sync
      fakeConnectivity.emit([ConnectivityResult.wifi]);
      await pumpEventQueue();
      await Future.delayed(const Duration(milliseconds: 50));

      // Check outbox drained
      final pendingAfter = await storageDriver.getPendingOutbox();
      expect(pendingAfter, isEmpty);
    });

    test('offline mutation updates local cache so next offline query returns added item', () async {
      // 1. App starts offline
      fakeConnectivity.emit([ConnectivityResult.none]);
      await pumpEventQueue();

      const mutationDoc = '''
        mutation AddTodo(\$id: String, \$task: String) {
          insert_teste_offilne_one(object: {id: \$id, task: \$task}) { id }
        }
      ''';

      // 2. User adds item offline
      await client.mutation(
        mutationDoc,
        variables: {'id': 'uuid-1', 'task': 'Comprar pão'},
      );

      // 3. User queries offline (simulating app reopen)
      const queryDoc = 'query GetTodos { teste_offilne { id task } }';
      final offlineTodos = await client.query(queryDoc, key: 'teste_offilne');

      expect(offlineTodos, isA<List>());
      expect((offlineTodos as List).length, equals(1));
      expect(offlineTodos.first['id'], equals('uuid-1'));
      expect(offlineTodos.first['task'], equals('Comprar pão'));
    });
  });
}


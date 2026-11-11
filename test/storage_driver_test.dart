import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';
import 'mocks/fake_connectivity.dart';

void main() {
  group('InMemoryStorageDriver', () {
    late InMemoryStorageDriver driver;

    setUp(() async {
      driver = InMemoryStorageDriver();
      await driver.init();
    });

    tearDown(() async {
      await driver.close();
    });

    test('saves and retrieves cached query', () async {
      await driver.saveCache('hash123', {
        'users': [
          {'id': '1'}
        ]
      });
      final cached = await driver.getCache('hash123');

      expect(cached, isNotNull);
      expect(cached?['users'], isNotEmpty);
    });

    test('enqueues, gets pending and removes outbox item', () async {
      final item = OutboxItem(
        id: 'outbox-1',
        document: 'mutation { insert_user }',
      );

      await driver.enqueueOutbox(item);
      var pending = await driver.getPendingOutbox();
      expect(pending.length, equals(1));
      expect(pending.first.id, equals('outbox-1'));

      await driver.removeOutbox('outbox-1');
      pending = await driver.getPendingOutbox();
      expect(pending, isEmpty);
    });
  });

  group('FileStorageDriver', () {
    final tempDir = Directory('.test_storage');
    late FileStorageDriver driver;

    setUp(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      driver = FileStorageDriver(basePath: tempDir.path);
      await driver.init();
    });

    tearDown(() async {
      await driver.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('persists cache and outbox across instances', () async {
      await driver.saveCache('persisted_hash', {'data': 'value'});
      await driver.enqueueOutbox(OutboxItem(
        id: 'persisted_item',
        document: 'mutation { insert }',
      ));

      // Create a second driver reading from the same folder
      final secondDriver = FileStorageDriver(basePath: tempDir.path);
      await secondDriver.init();

      final cached = await secondDriver.getCache('persisted_hash');
      expect(cached?['data'], equals('value'));

      final pending = await secondDriver.getPendingOutbox();
      expect(pending.length, equals(1));
      expect(pending.first.id, equals('persisted_item'));

      await secondDriver.close();
    });

    test(
        'full offline lifecycle: add offline, restart client with file storage, query offline',
        () async {
      // 1. Instancia 1 do cliente (App aberto pela primeira vez offline)
      final fakeConn1 = FakeConnectivity()..emit([ConnectivityResult.none]);
      final client1 = HasuraOfflineFirst(
        'https://fake.url',
        storageDriver: FileStorageDriver(basePath: tempDir.path),
        networkManager: NetworkManager(connectivity: fakeConn1),
      );

      const addMutation = '''
        mutation AddTodo(\$id: uuid!, \$task: String!, \$check: Boolean!) {
          insert_teste_offilne_one(object: {id: \$id, task: \$task, check: \$check}) { id }
        }
      ''';
      await client1.mutation(addMutation, variables: {
        'id': 'persisted-uuid-999',
        'task': 'Tarefa que sobrevive ao fechar o app',
        'check': false,
      });

      // Simula fechamento do app
      client1.dispose();
      fakeConn1.dispose();

      // 2. Instancia 2 do cliente (App reaberto offline em um novo processo)
      final fakeConn2 = FakeConnectivity()..emit([ConnectivityResult.none]);
      final client2 = HasuraOfflineFirst(
        'https://fake.url',
        storageDriver: FileStorageDriver(basePath: tempDir.path),
        networkManager: NetworkManager(connectivity: fakeConn2),
      );

      const getQuery = '''
        query GetTodos {
          teste_offilne {
            id
            task
            check
          }
        }
      ''';
      final result = await client2.query(getQuery, key: 'teste_offilne');

      expect(result, isA<List>());
      final list = result as List;
      expect(list.length, equals(1));
      expect(list.first['id'], equals('persisted-uuid-999'));
      expect(
          list.first['task'], equals('Tarefa que sobrevive ao fechar o app'));

      client2.dispose();
      fakeConn2.dispose();
    });
  });
}

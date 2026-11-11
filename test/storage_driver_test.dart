import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';

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
      await driver.saveCache('hash123', {'users': [{'id': '1'}]});
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
  });
}


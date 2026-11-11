import 'package:flutter_test/flutter_test.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';

void main() {
  group('HashGenerator', () {
    test('generates same hash for identical query with different whitespaces', () {
      const doc1 = '''
        query GetUser {
          users {
            id
            name
          }
        }
      ''';

      const doc2 = 'query GetUser { users { id name } }';

      final hash1 = HashGenerator.generate(doc1);
      final hash2 = HashGenerator.generate(doc2);

      expect(hash1, equals(hash2));
    });

    test('generates same hash for maps with different key insertion orders', () {
      const doc = 'query GetUsers(\$limit: Int, \$offset: Int) { users }';
      final var1 = {'offset': 10, 'limit': 20};
      final var2 = {'limit': 20, 'offset': 10};

      final hash1 = HashGenerator.generate(doc, var1);
      final hash2 = HashGenerator.generate(doc, var2);

      expect(hash1, equals(hash2));
    });

    test('generates different hash for different variables', () {
      const doc = 'query GetUsers(\$limit: Int) { users }';
      final hash1 = HashGenerator.generate(doc, {'limit': 10});
      final hash2 = HashGenerator.generate(doc, {'limit': 20});

      expect(hash1, isNot(equals(hash2)));
    });
  });
}


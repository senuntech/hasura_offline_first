import 'dart:convert';
import 'dart:developer' as dev;
import 'package:sqflite/sqflite.dart' as sqflite;
import '../network/hasura_http_client.dart';
import '../contracts/hasura_connect_interface.dart';

/// Handles dynamic schema introspection from Hasura and performs non-destructive
/// auto-migrations (e.g. `ALTER TABLE ADD COLUMN`) on the local SQLite replica.
class SchemaMigrator {
  final HasuraHttpClient httpClient;
  final String url;
  final Map<String, String> Function() headersProvider;

  SchemaMigrator({
    required this.httpClient,
    required this.url,
    required this.headersProvider,
  });

  static const String _introspectionQuery = '''
    query IntrospectTable(\$tableName: String!) {
      __type(name: \$tableName) {
        name
        fields {
          name
          type {
            name
            kind
            ofType {
              name
              kind
              ofType {
                name
                kind
              }
            }
          }
        }
      }
    }
  ''';

  /// Synchronizes the local SQLite table schema with the remote Hasura/PostgreSQL definition.
  Future<void> syncTableSchema(sqflite.Database db, String tableName) async {
    try {
      final request = Request(
        url: url,
        document: _introspectionQuery,
        variables: {'tableName': tableName},
        headers: headersProvider(),
        type: 'query',
      );

      final response = await httpClient.execute(request);
      final fields = _extractFieldsFromIntrospection(response);

      if (fields.isEmpty) {
        // Table not found in Hasura introspection or no fields, keep existing local structure
        return;
      }

      await _applySchemaDelta(db, tableName, fields);
    } catch (e) {
      dev.log(
        'Offline or error during schema introspection for table "$tableName": $e',
        name: 'SchemaMigrator',
      );
    }
  }

  List<Map<String, String>> _extractFieldsFromIntrospection(dynamic response) {
    final List<Map<String, String>> result = [];
    if (response is Map<String, dynamic>) {
      final type = response['__type'];
      if (type is Map<String, dynamic> && type['fields'] is List) {
        final fields = type['fields'] as List;
        for (final f in fields) {
          if (f is Map) {
            final name = f['name']?.toString();
            if (name == null || name.startsWith('__')) continue;
            final typeName = _resolveTypeName(f['type']);
            result.add({'name': name, 'type': typeName});
          }
        }
      }
    }
    return result;
  }

  String _resolveTypeName(dynamic type) {
    if (type is! Map) return 'String';
    if (type['name'] != null) return type['name'].toString();
    if (type['ofType'] != null) return _resolveTypeName(type['ofType']);
    return 'String';
  }

  String _mapToSqliteType(String graphQLType) {
    switch (graphQLType.toLowerCase()) {
      case 'int':
      case 'bigint':
      case 'smallint':
      case 'boolean':
        return 'INTEGER';
      case 'float':
      case 'numeric':
      case 'double':
        return 'REAL';
      case 'string':
      case 'uuid':
      case 'timestamptz':
      case 'timestamp':
      case 'date':
      default:
        return 'TEXT';
    }
  }

  Future<void> _applySchemaDelta(
    sqflite.Database db,
    String tableName,
    List<Map<String, String>> fields,
  ) async {
    // 1. Check existing columns in SQLite
    final List<Map<String, dynamic>> existingCols =
        await db.rawQuery('PRAGMA table_info($tableName)');

    if (existingCols.isEmpty) {
      // Table does not exist locally: create it
      final colDefs = <String>['id TEXT PRIMARY KEY'];
      for (final field in fields) {
        final colName = field['name']!;
        if (colName == 'id') continue;
        final colType = _mapToSqliteType(field['type']!);
        colDefs.add('$colName $colType');
      }

      // Add local-first audit and control columns
      colDefs.addAll([
        '__sync_status TEXT DEFAULT \'synced\'',
        '__updated_at TEXT',
        '__is_deleted INTEGER DEFAULT 0',
        '__version INTEGER DEFAULT 1',
      ]);

      await db.execute(
        'CREATE TABLE IF NOT EXISTS $tableName (${colDefs.join(', ')})',
      );
    } else {
      // Table exists: detect missing columns and run non-destructive auto-migrations
      final existingColNames =
          existingCols.map((c) => c['name'].toString().toLowerCase()).toSet();

      for (final field in fields) {
        final colName = field['name']!;
        if (!existingColNames.contains(colName.toLowerCase())) {
          final colType = _mapToSqliteType(field['type']!);
          dev.log(
            'Auto-migrating local table "$tableName": ADD COLUMN "$colName" $colType',
            name: 'SchemaMigrator',
          );
          await db
              .execute('ALTER TABLE $tableName ADD COLUMN $colName $colType');
        }
      }
    }

    // Save snapshot to _schema_metadata
    final columnsJson = jsonEncode(fields);
    await db.rawInsert('''
      INSERT OR REPLACE INTO _schema_metadata (table_name, columns_json, schema_hash, updated_at)
      VALUES (?, ?, ?, ?)
    ''', [
      tableName,
      columnsJson,
      fields.length.toString(),
      DateTime.now().toIso8601String(),
    ]);
  }
}

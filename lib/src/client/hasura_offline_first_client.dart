import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:uuid/uuid.dart';

import '../contracts/hasura_connect_interface.dart';
import '../contracts/network_status.dart';
import '../contracts/storage_interface.dart';
import '../contracts/tenant_config.dart';
import '../core/exceptions.dart';
import '../core/hash_generator.dart';
import '../core/network_manager.dart';
import '../interceptors/token_interceptor.dart';
import '../local_database/database_provider.dart';
import '../local_database/graphql_query_parser.dart';
import '../local_database/local_table_repository.dart';
import '../local_database/schema_migrator.dart';
import '../network/hasura_http_client.dart';
import '../network/hasura_ws_client.dart';
import '../storage/file_storage_driver.dart';
import '../sync/conflict_resolver.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_manager.dart';
import '../sync/sync_status.dart';
import 'hybrid_snapshot.dart';

/// Local-First & Offline-First GraphQL client compatible with HasuraConnect,
/// powered by an embedded SQLite database replica, dynamic schema auto-migrations,
/// and Server Authority conflict resolution.
class HasuraOfflineFirst implements IHasuraConnect {
  @override
  final String url;
  final Map<String, String> _headers;
  final List<Interceptor> _interceptors;

  final NetworkManager _networkManager;
  final ILocalStorageDriver _storageDriver;
  TenantConfig? _tenantConfig;
  DatabaseProvider databaseProvider;
  late final LocalTableRepository localRepository;
  late final SchemaMigrator schemaMigrator;
  late final ConflictResolver conflictResolver;
  late final SyncEngine syncEngine;
  late final SyncManager _syncManager;
  late final HasuraHttpClient _httpClient;
  late final HasuraWebSocketClient _wsClient;
  final _uuid = const Uuid();

  /// Current active tenant configuration (null for Single-Tenant mode).
  TenantConfig? get tenantConfig => _tenantConfig;

  HasuraOfflineFirst(
    this.url, {
    Map<String, String>? headers,
    FutureOr<String?> Function()? token,
    List<Interceptor>? interceptors,
    ILocalStorageDriver? storageDriver,
    NetworkManager? networkManager,
    DatabaseProvider? customDatabaseProvider,
    sqflite.DatabaseFactory? customDatabaseFactory,
    TenantConfig? tenantConfig,
    http.Client? httpClient,
    Set<String>? tables,
  })  : _headers = headers ?? {},
        _interceptors = [...?interceptors],
        _networkManager = networkManager ?? NetworkManager(),
        _storageDriver = storageDriver ?? FileStorageDriver(),
        _tenantConfig = tenantConfig ??
            (headers != null && headers.containsKey('x-hasura-tenant-id')
                ? TenantConfig(tenantId: headers['x-hasura-tenant-id']!)
                : null),
        databaseProvider = customDatabaseProvider ??
            DatabaseProvider(
              dbName: DatabaseProvider.resolveDatabaseName(
                tenantConfig ??
                    (headers != null &&
                            headers.containsKey('x-hasura-tenant-id')
                        ? TenantConfig(tenantId: headers['x-hasura-tenant-id']!)
                        : null),
              ),
              customDatabaseFactory: customDatabaseFactory,
            ) {
    if (token != null) {
      // Auto-detect tenant from initial token if synchronous
      final initialTokenOrFuture = token();
      if (initialTokenOrFuture is String) {
        final autoConfig = TenantConfig.tryFromJwt(initialTokenOrFuture);
        if (autoConfig != null && _tenantConfig == null) {
          _tenantConfig = autoConfig;
          databaseProvider = DatabaseProvider(
            dbName: DatabaseProvider.resolveDatabaseName(autoConfig),
            customDatabaseFactory: customDatabaseFactory,
          );
        }
      } else if (initialTokenOrFuture is Future<String?>) {
        initialTokenOrFuture.then((t) {
          final autoConfig = TenantConfig.tryFromJwt(t);
          if (autoConfig != null &&
              (_tenantConfig == null ||
                  _tenantConfig!.tenantId != autoConfig.tenantId)) {
            switchTenant(autoConfig);
          }
        }).catchError((_) {});
      }

      _interceptors.insert(
        0,
        TokenInterceptor(
          token,
          onTokenResolved: (resolvedToken) {
            final autoConfig = TenantConfig.tryFromJwt(resolvedToken);
            if (autoConfig != null &&
                (_tenantConfig == null ||
                    _tenantConfig!.tenantId != autoConfig.tenantId)) {
              switchTenant(autoConfig);
            }
          },
        ),
      );
    }

    _httpClient = HasuraHttpClient(
      client: httpClient,
      interceptors: _interceptors,
    );

    _wsClient = HasuraWebSocketClient(
      url: url,
      headersProvider: () => _headers,
    );

    _syncManager = SyncManager(
      storageDriver: _storageDriver,
      networkManager: _networkManager,
      httpClient: _httpClient,
      url: url,
      headersProvider: () => _headers,
    );

    localRepository = LocalTableRepository(
      databaseProvider: databaseProvider,
      tenantConfig: _tenantConfig,
    );

    schemaMigrator = SchemaMigrator(
      httpClient: _httpClient,
      url: url,
      headersProvider: () => _headers,
    );

    conflictResolver = ConflictResolver();

    syncEngine = SyncEngine(
      databaseProvider: databaseProvider,
      localRepository: localRepository,
      schemaMigrator: schemaMigrator,
      conflictResolver: conflictResolver,
      httpClient: _httpClient,
      networkManager: _networkManager,
      url: url,
      headersProvider: () => _headers,
      tenantConfig: _tenantConfig,
      tables: tables,
    );

    // Initial background sync check
    _networkManager.isConnected.then((connected) {
      if (connected) {
        synchronize();
      }
    });
  }

  @override
  Map<String, String> get headers => Map.unmodifiable(_headers);

  /// Reactive stream emitting network status changes.
  @override
  Stream<NetworkStatus> get onConnectivityChanged =>
      _networkManager.onStatusChanged;

  /// Instant check whether the device currently has active network connectivity.
  @override
  Future<bool> get isConnected => _networkManager.isConnected;

  /// Returns true if offline simulation is actively enabled.
  bool get isSimulatingOffline => _networkManager.isSimulatingOffline;

  /// Manually simulates offline mode for testing and demonstration purposes.
  void simulateOffline(bool offline) =>
      _networkManager.simulateOffline(offline);

  /// Stream signaling when bidirectional background sync starts or finishes.
  Stream<bool> get onSyncStateChanged => syncEngine.onSyncStateChanged;

  /// Reactive stream emitting detailed synchronization metrics and states (idle, syncing, synced, error, pendingCount).
  Stream<SyncStatusSnapshot> get syncStatusStream =>
      syncEngine.syncStatusStream;

  /// Instant snapshot of the current synchronization state and pending mutation count.
  SyncStatusSnapshot get syncStatus => syncEngine.currentStatus;

  /// Stream of mutations synced successfully when back online via Outbox.
  Stream<OutboxItem> get onSyncedItem => _syncManager.onSyncedItem;

  /// Stream emitting table changes in the local SQLite database.
  Stream<TableChangeEvent> get onTableChanged => localRepository.onTableChanged;

  /// Stream emitting when a record is deleted locally because another user deleted it on the server.
  Stream<ConflictPurgeEvent> get onConflictPurge =>
      conflictResolver.onConflictPurge;

  /// Storage driver used for document caching.
  ILocalStorageDriver get storageDriver => _storageDriver;

  /// Registers a table to be continuously synchronized and auto-migrated with Hasura.
  void registerTable(String table) {
    syncEngine.registerTable(table);
  }

  /// Registers a network status listener callback and returns a disposer function.
  @override
  VoidCallback addConnectivityListener(ConnectivityListener callback) {
    return _networkManager.addListener(callback);
  }

  /// Executes a query directly on the local SQLite table with zero network latency.
  Future<List<Map<String, dynamic>>> queryLocal(
    String tableName, {
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    registerTable(tableName);
    return await localRepository.query(
      tableName,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  /// Inserts a row into the local SQLite table and queues an upstream sync.
  Future<Map<String, dynamic>> insertLocal(
    String tableName,
    Map<String, dynamic> row,
  ) async {
    registerTable(tableName);
    final inserted = await localRepository.insert(tableName, row);
    _triggerSyncIfOnline();
    return inserted;
  }

  /// Updates an existing row in the local SQLite table and queues an upstream sync.
  Future<void> updateLocal(
    String tableName,
    String id,
    Map<String, dynamic> row,
  ) async {
    registerTable(tableName);
    await localRepository.update(tableName, id, row);
    _triggerSyncIfOnline();
  }

  /// Deletes a row locally (tombstone) and queues an upstream sync.
  Future<void> deleteLocal(String tableName, String id) async {
    registerTable(tableName);
    await localRepository.delete(tableName, id);
    _triggerSyncIfOnline();
  }

  void _triggerSyncIfOnline() {
    _networkManager.isConnected.then((connected) {
      if (connected) {
        synchronize();
      }
    });
  }

  String? _extractTableFromQuery(String document) {
    final normalized = document.replaceAll(RegExp(r'#[^\n\r]*'), '');
    final match = RegExp(r'(?:query[^{]*\{\s*|{\s*)([a-zA-Z0-9_]+)')
        .firstMatch(normalized);
    return match?.group(1);
  }

  String? _resolveBaseTable(String? queryField) {
    if (queryField == null) return null;
    if (syncEngine.registeredTables.contains(queryField)) {
      return queryField;
    }
    final stripped =
        queryField.replaceFirst(RegExp(r'_(?:by_pk|aggregate)$'), '');
    if (syncEngine.registeredTables.contains(stripped)) {
      return stripped;
    }
    return queryField;
  }

  String? _extractOrderByFromQuery(String document,
      [Map<String, dynamic>? variables]) {
    if (variables != null && variables['order_by'] is Map) {
      final map = variables['order_by'] as Map;
      if (map.isNotEmpty) {
        final col = map.keys.first.toString();
        final dir = map.values.first.toString().toUpperCase();
        return '"$col" $dir';
      }
    }

    final normalized = document.replaceAll(RegExp(r'#[^\n\r]*'), '');
    final match = RegExp(
      r'order_by:\s*(?:\[\s*)?\{\s*([a-zA-Z0-9_]+)\s*:\s*(asc|desc)\s*\}',
      caseSensitive: false,
    ).firstMatch(normalized);

    if (match != null) {
      final col = match.group(1)!;
      final dir = match.group(2)!.toUpperCase();
      return '"$col" $dir';
    }
    return null;
  }

  int? _extractLimitFromQuery(String document,
      [Map<String, dynamic>? variables]) {
    if (variables != null && variables['limit'] is int) {
      return variables['limit'] as int;
    }
    final match = RegExp(r'limit:\s*([0-9]+)').firstMatch(document);
    return match != null ? int.tryParse(match.group(1)!) : null;
  }

  int? _extractOffsetFromQuery(String document,
      [Map<String, dynamic>? variables]) {
    if (variables != null && variables['offset'] is int) {
      return variables['offset'] as int;
    }
    final match = RegExp(r'offset:\s*([0-9]+)').firstMatch(document);
    return match != null ? int.tryParse(match.group(1)!) : null;
  }

  Map<String, dynamic>? _extractItemData(Map<String, dynamic>? variables) {
    if (variables == null) return null;
    if (variables.containsKey('object') && variables['object'] is Map) {
      return Map<String, dynamic>.from(variables['object'] as Map);
    }
    if (variables.containsKey('objects') && variables['objects'] is List) {
      final list = variables['objects'] as List;
      if (list.isNotEmpty && list.first is Map) {
        return Map<String, dynamic>.from(list.first as Map);
      }
    }
    return Map<String, dynamic>.from(variables);
  }

  Map<String, dynamic> _extractUpdates(
    String document,
    Map<String, dynamic>? variables,
  ) {
    if (variables != null && variables['_set'] is Map) {
      return Map<String, dynamic>.from(variables['_set'] as Map);
    }
    if (variables != null && variables['changes'] is Map) {
      return Map<String, dynamic>.from(variables['changes'] as Map);
    }

    // Try parsing inline _set block from document: _set: { column: $variable, ... }
    final setMatch = RegExp(r'_set\s*:\s*\{([^}]+)\}').firstMatch(document);
    if (setMatch != null) {
      final content = setMatch.group(1)!;
      final pairRegex = RegExp(r'([a-zA-Z0-9_]+)\s*:\s*([^,\s\}]+)');
      final updates = <String, dynamic>{};
      for (final m in pairRegex.allMatches(content)) {
        final col = m.group(1)!.trim();
        final rawVal = m.group(2)!.trim();
        if (rawVal.startsWith(r'$')) {
          final varName = rawVal.substring(1);
          if (variables != null && variables.containsKey(varName)) {
            updates[col] = variables[varName];
          }
        } else {
          updates[col] = rawVal.replaceAll('"', '').replaceAll("'", '');
        }
      }
      if (updates.isNotEmpty) {
        return updates;
      }
    }

    if (variables != null) {
      final clean = Map<String, dynamic>.from(variables)
        ..remove('id')
        ..remove('pk_columns')
        ..remove('where');
      return clean;
    }
    return {};
  }

  Future<void> _applyMutationToLocalCache(
    String document,
    Map<String, dynamic>? variables,
  ) async {
    try {
      final firstBrace = document.indexOf('{');
      final selectionBody =
          firstBrace != -1 ? document.substring(firstBrace + 1) : document;

      final insertMatch = RegExp(r'\binsert_([a-zA-Z0-9_]+?)(?:_one|\b|\()')
          .firstMatch(selectionBody);
      final updateMatch = RegExp(r'\bupdate_([a-zA-Z0-9_]+?)(?:_by_pk|\b|\()')
          .firstMatch(selectionBody);
      final deleteMatch = RegExp(r'\bdelete_([a-zA-Z0-9_]+?)(?:_by_pk|\b|\()')
          .firstMatch(selectionBody);

      if (insertMatch != null) {
        final table = insertMatch.group(1)!;
        final itemData = _extractItemData(variables);
        if (itemData != null) {
          await _insertIntoLocalTable(table, itemData);
        }
      } else if (updateMatch != null) {
        final table = updateMatch.group(1)!;
        final id = variables?['id'] ??
            variables?['pk_columns']?['id'] ??
            (variables?['where']?['id']?['_eq']);
        if (id != null) {
          final updates = variables?['_set'] is Map
              ? Map<String, dynamic>.from(variables!['_set'] as Map)
              : (variables != null
                  ? Map<String, dynamic>.from(variables)
                  : <String, dynamic>{});
          await _updateLocalTable(table, id.toString(), updates);
        }
      } else if (deleteMatch != null) {
        final table = deleteMatch.group(1)!;
        final id = variables?['id'] ??
            variables?['pk_columns']?['id'] ??
            (variables?['where']?['id']?['_eq']);
        if (id != null) {
          await _deleteFromLocalTable(table, id.toString());
        }
      }
    } catch (_) {}
  }

  Future<void> _insertIntoLocalTable(
    String table,
    Map<String, dynamic> item,
  ) async {
    final tableKey = 'table:$table';
    final existingTableCache = await _storageDriver.getCache(tableKey);
    List<dynamic> list = [];
    if (existingTableCache != null && existingTableCache['list'] is List) {
      list = List<dynamic>.from(existingTableCache['list'] as List);
    }
    if (item.containsKey('id')) {
      list.removeWhere(
          (i) => i is Map && i['id']?.toString() == item['id']?.toString());
    }
    list.add(item);
    await _storageDriver.saveCache(tableKey, {'list': list, table: list});

    final keys = await _storageDriver.getAllCacheKeys();
    for (final key in keys) {
      if (key == tableKey) continue;
      final cacheData = await _storageDriver.getCache(key);
      if (cacheData != null) {
        bool updated = false;
        if (cacheData.containsKey(table) && cacheData[table] is List) {
          final l = List<dynamic>.from(cacheData[table] as List);
          if (item.containsKey('id')) {
            l.removeWhere((i) =>
                i is Map && i['id']?.toString() == item['id']?.toString());
          }
          l.add(item);
          cacheData[table] = l;
          updated = true;
        } else if (cacheData.containsKey('list') && cacheData['list'] is List) {
          final l = List<dynamic>.from(cacheData['list'] as List);
          if (item.containsKey('id')) {
            l.removeWhere((i) =>
                i is Map && i['id']?.toString() == item['id']?.toString());
          }
          l.add(item);
          cacheData['list'] = l;
          updated = true;
        }
        if (updated) {
          await _storageDriver.saveCache(key, cacheData);
        }
      }
    }
  }

  Future<void> _updateLocalTable(
    String table,
    String id,
    Map<String, dynamic> updates,
  ) async {
    final tableKey = 'table:$table';
    final existingTableCache = await _storageDriver.getCache(tableKey);
    if (existingTableCache != null && existingTableCache['list'] is List) {
      final list = List<dynamic>.from(existingTableCache['list'] as List);
      for (int i = 0; i < list.length; i++) {
        if (list[i] is Map && list[i]['id']?.toString() == id) {
          final merged = Map<String, dynamic>.from(list[i] as Map);
          merged.addAll(updates);
          list[i] = merged;
        }
      }
      await _storageDriver.saveCache(tableKey, {'list': list, table: list});
    }

    final keys = await _storageDriver.getAllCacheKeys();
    for (final key in keys) {
      if (key == tableKey) continue;
      final cacheData = await _storageDriver.getCache(key);
      if (cacheData != null) {
        bool updated = false;
        for (final prop in [table, 'list']) {
          if (cacheData.containsKey(prop) && cacheData[prop] is List) {
            final l = List<dynamic>.from(cacheData[prop] as List);
            for (int i = 0; i < l.length; i++) {
              if (l[i] is Map && l[i]['id']?.toString() == id) {
                final merged = Map<String, dynamic>.from(l[i] as Map);
                merged.addAll(updates);
                l[i] = merged;
                updated = true;
              }
            }
            cacheData[prop] = l;
          }
        }
        if (updated) {
          await _storageDriver.saveCache(key, cacheData);
        }
      }
    }
  }

  Future<void> _deleteFromLocalTable(String table, String id) async {
    final tableKey = 'table:$table';
    final existingTableCache = await _storageDriver.getCache(tableKey);
    if (existingTableCache != null && existingTableCache['list'] is List) {
      final list = List<dynamic>.from(existingTableCache['list'] as List);
      list.removeWhere((i) => i is Map && i['id']?.toString() == id);
      await _storageDriver.saveCache(tableKey, {'list': list, table: list});
    }

    final keys = await _storageDriver.getAllCacheKeys();
    for (final key in keys) {
      if (key == tableKey) continue;
      final cacheData = await _storageDriver.getCache(key);
      if (cacheData != null) {
        bool updated = false;
        for (final prop in [table, 'list']) {
          if (cacheData.containsKey(prop) && cacheData[prop] is List) {
            final l = List<dynamic>.from(cacheData[prop] as List);
            final beforeLen = l.length;
            l.removeWhere((i) => i is Map && i['id']?.toString() == id);
            if (l.length != beforeLen) {
              cacheData[prop] = l;
              updated = true;
            }
          }
        }
        if (updated) {
          await _storageDriver.saveCache(key, cacheData);
        }
      }
    }
  }

  /// Standard GraphQL query compatible with HasuraConnect.
  /// If the query targets a registered table, reads directly from the local SQLite replica.
  /// Otherwise, uses the document cache driver.
  @override
  Future<dynamic> query(
    String document, {
    String? key,
    Map<String, dynamic>? variables,
  }) async {
    final rootFields = GraphQLQueryParser.extractRootFields(document);
    final isMultiRoot = rootFields.length > 1;

    final rawField = key ??
        (rootFields.isNotEmpty
            ? rootFields.first
            : _extractTableFromQuery(document));
    final targetTable = _resolveBaseTable(rawField);
    final isByPk = rawField != null && rawField.endsWith('_by_pk');
    final hasNested = GraphQLQueryParser.hasNestedSelections(document);

    // If single registered table without nested relational joins: read from SQLite!
    if (!isMultiRoot &&
        targetTable != null &&
        syncEngine.registeredTables.contains(targetTable) &&
        !hasNested) {
      final parsedWhere = GraphQLQueryParser.parseWhere(document, variables);
      final orderBy = _extractOrderByFromQuery(document, variables) ??
          GraphQLQueryParser.parseOrderBy(document);
      final limit = _extractLimitFromQuery(document, variables) ??
          GraphQLQueryParser.parseLimit(document);
      final offset = _extractOffsetFromQuery(document, variables) ??
          GraphQLQueryParser.parseOffset(document);

      final localRows = await localRepository.query(
        targetTable,
        where: parsedWhere?.clause,
        whereArgs: parsedWhere?.args,
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );

      // If local SQLite already has data, return it immediately with 0ms latency!
      if (localRows.isNotEmpty) {
        if (key != null) {
          return localRows;
        }
        if (isByPk) {
          return {rawField: localRows.first};
        }
        return {rawField ?? targetTable: localRows};
      }

      // If local SQLite is empty but offline, return empty result gracefully
      final isOnline = await isConnected;
      if (!isOnline) {
        if (key != null) return [];
        if (isByPk) return {rawField: null};
        return {rawField ?? targetTable: []};
      }
      // If local SQLite is empty and online, fall through to fetch from Hasura (e.g. first boot before sync completes)
    }

    // Classic GraphQL query cache pipeline (handles multi-root and nested relational queries)
    final queryHash = HashGenerator.generate(document, variables);
    final isOnline = await isConnected;

    if (isOnline) {
      final request = Request(
        url: url,
        document: document,
        variables: variables,
        headers: _headers,
        key: key,
        type: 'query',
      );

      final data = await _httpClient.execute(request);

      if (data is Map<String, dynamic>) {
        await _storageDriver.saveCache(queryHash, data);
      } else if (data is List) {
        await _storageDriver.saveCache(queryHash, {'list': data});
      }

      if (targetTable != null) {
        if (data is List) {
          await _storageDriver.saveCache(
            'table:$targetTable',
            {'list': data, targetTable: data},
          );
        } else if (data is Map<String, dynamic> &&
            data.containsKey(targetTable)) {
          await _storageDriver.saveCache(
            'table:$targetTable',
            {'list': data[targetTable], targetTable: data[targetTable]},
          );
        }
      }

      return data;
    } else {
      var cached = await _storageDriver.getCache(queryHash);

      if (cached == null && targetTable != null) {
        cached = await _storageDriver.getCache('table:$targetTable');
      }

      if (cached != null) {
        if (key != null) {
          if (cached.containsKey(key)) {
            return cached[key];
          }
          if (cached.containsKey('list')) {
            return cached['list'];
          }
        }
        if (cached.containsKey('list') && cached.keys.length == 1) {
          return cached['list'];
        }
        return cached;
      }

      // If offline and multi-root query with no cache, attempt best-effort local table resolution
      if (isMultiRoot) {
        final Map<String, dynamic> combined = {};
        for (final field in rootFields) {
          final base = _resolveBaseTable(field);
          if (base != null && syncEngine.registeredTables.contains(base)) {
            final localRows = await localRepository.query(base);
            combined[field] = localRows;
          }
        }
        if (combined.isNotEmpty) {
          return combined;
        }
      }

      throw HasuraCacheMissException(
        queryHash: queryHash,
        message: 'No cached response found for this query while offline.',
      );
    }
  }

  /// Standard GraphQL mutation compatible with HasuraConnect.
  /// If the mutation targets a registered table, executes locally in SQLite and queues sync.
  /// Otherwise, uses HTTP (when online) or Outbox queue (when offline).
  @override
  Future<dynamic> mutation(
    String document, {
    String? key,
    Map<String, dynamic>? variables,
  }) async {
    final firstBrace = document.indexOf('{');
    final selectionBody =
        firstBrace != -1 ? document.substring(firstBrace + 1) : document;

    final insertMatch = RegExp(r'\binsert_([a-zA-Z0-9_]+?)(?:_one|\b|\()')
        .firstMatch(selectionBody);
    final updateMatch = RegExp(r'\bupdate_([a-zA-Z0-9_]+?)(?:_by_pk|\b|\()')
        .firstMatch(selectionBody);
    final deleteMatch = RegExp(r'\bdelete_([a-zA-Z0-9_]+?)(?:_by_pk|\b|\()')
        .firstMatch(selectionBody);

    final targetTable =
        insertMatch?.group(1) ?? updateMatch?.group(1) ?? deleteMatch?.group(1);

    // If target table is registered for Local-First replica: execute on SQLite!
    if (targetTable != null &&
        syncEngine.registeredTables.contains(targetTable)) {
      if (insertMatch != null) {
        final itemData = _extractItemData(variables) ?? {};
        final inserted = await insertLocal(targetTable, itemData);
        return {
          'insert_${targetTable}_one': inserted,
          '_local': true,
        };
      } else if (updateMatch != null) {
        final id = (variables?['id'] ??
                variables?['pk_columns']?['id'] ??
                variables?['where']?['id']?['_eq'])
            ?.toString();
        if (id != null) {
          final updates = _extractUpdates(document, variables);
          await updateLocal(targetTable, id, updates);

          // Query the full local row so that callers get back complete entity attributes
          final updatedRows = await localRepository.query(
            targetTable,
            where: '"id" = ?',
            whereArgs: [id],
          );
          final fullRow = updatedRows.isNotEmpty
              ? updatedRows.first
              : {'id': id, ...updates};

          return {
            'update_${targetTable}_by_pk': fullRow,
            '_local': true,
          };
        }
      } else if (deleteMatch != null) {
        final id = (variables?['id'] ??
                variables?['pk_columns']?['id'] ??
                variables?['where']?['id']?['_eq'])
            ?.toString();
        if (id != null) {
          await deleteLocal(targetTable, id);
          return {
            'delete_${targetTable}_by_pk': {'id': id},
            '_local': true,
          };
        }
      }
    }

    // Classic mutation pipeline
    final isOnline = await isConnected;

    if (isOnline) {
      final request = Request(
        url: url,
        document: document,
        variables: variables,
        headers: _headers,
        key: key,
        type: 'mutation',
      );

      final result = await _httpClient.execute(request);
      await _applyMutationToLocalCache(document, variables);
      return result;
    } else {
      final outboxItem = OutboxItem(
        id: _uuid.v4(),
        document: document,
        variables: variables,
        status: OutboxStatus.pending,
      );

      await _storageDriver.enqueueOutbox(outboxItem);
      await _applyMutationToLocalCache(document, variables);

      return {
        '_offline': true,
        'id': outboxItem.id,
        'status': 'enqueued',
        'document': document,
        'variables': variables,
      };
    }
  }

  @override
  Future<Snapshot> subscription(
    String document, {
    String? key,
    Map<String, dynamic>? variables,
  }) async {
    final request = Request(
      url: url,
      document: document,
      variables: variables,
      headers: _headers,
      key: key,
      type: 'subscription',
    );

    final tableName = key ?? _extractTableFromQuery(document);

    // If table is registered for Local-First replica: return high-performance HybridSnapshot
    if (tableName != null && syncEngine.registeredTables.contains(tableName)) {
      final hybrid = HybridSnapshot(
        tableName: tableName,
        document: document,
        variables: variables,
        localRepository: localRepository,
        networkManager: _networkManager,
        queryLocal: () async {
          final parsedWhere =
              GraphQLQueryParser.parseWhere(document, variables);
          final orderBy = _extractOrderByFromQuery(document, variables) ??
              GraphQLQueryParser.parseOrderBy(document);
          final limit = _extractLimitFromQuery(document, variables) ??
              GraphQLQueryParser.parseLimit(document);
          final offset = _extractOffsetFromQuery(document, variables) ??
              GraphQLQueryParser.parseOffset(document);

          final localRows = await localRepository.query(
            tableName,
            where: parsedWhere?.clause,
            whereArgs: parsedWhere?.args,
            orderBy: orderBy,
            limit: limit,
            offset: offset,
          );
          if (key != null) {
            return localRows;
          }
          return {tableName: localRows};
        },
        subscribeRemote: () => _wsClient.subscribe(
          document,
          key: key,
          variables: variables,
        ),
        onRemoteData: (remoteData) async {
          List<Map<String, dynamic>>? remoteRows;
          if (remoteData is List) {
            remoteRows = remoteData
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
          } else if (remoteData is Map<String, dynamic>) {
            if (remoteData[tableName] is List) {
              remoteRows = (remoteData[tableName] as List)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
            }
          }
          if (remoteRows != null && remoteRows.isNotEmpty) {
            await localRepository.upsertBatch(tableName, remoteRows);
          }
        },
      );

      for (final interceptor in _interceptors) {
        await interceptor.onSubscription(request, hybrid);
      }

      return hybrid;
    }

    final snapshot = await _wsClient.subscribe(
      document,
      key: key,
      variables: variables,
    );

    for (final interceptor in _interceptors) {
      await interceptor.onSubscription(request, snapshot);
    }

    return snapshot;
  }

  /// Triggers full bidirectional synchronization (Push pending mutations + Pull deltas).
  @override
  Future<void> synchronize() async {
    await _syncManager.synchronize();
    await syncEngine.synchronize();
  }

  /// Switches the active tenant, safely closing the current SQLite database and
  /// opening the dedicated replica for [newTenant].
  Future<void> switchTenant(TenantConfig newTenant) async {
    await databaseProvider.close();
    _tenantConfig = newTenant;
    databaseProvider = DatabaseProvider(
      dbName: DatabaseProvider.resolveDatabaseName(newTenant),
      customDatabaseFactory: databaseProvider.customDatabaseFactory,
    );
    localRepository.databaseProvider = databaseProvider;
    localRepository.tenantConfig = newTenant;
    syncEngine.databaseProvider = databaseProvider;
    syncEngine.tenantConfig = newTenant;

    if (_networkManager.currentStatus == NetworkStatus.online) {
      await syncEngine.synchronize();
    }
  }

  /// Physically deletes the local SQLite database replica for [targetTenantId]
  /// (or the current tenant if omitted). Useful for secure logouts.
  Future<void> clearTenantData([String? targetTenantId]) async {
    final idToClear = targetTenantId ?? _tenantConfig?.tenantId;
    final configToClear =
        idToClear != null ? TenantConfig(tenantId: idToClear) : null;
    final dbName = DatabaseProvider.resolveDatabaseName(configToClear);

    if (dbName == databaseProvider.dbName) {
      await databaseProvider.deleteDatabaseFile();
    } else {
      final tempProvider = DatabaseProvider(
        dbName: dbName,
        customDatabaseFactory: databaseProvider.customDatabaseFactory,
      );
      await tempProvider.deleteDatabaseFile();
    }
  }

  @override
  void dispose() {
    _networkManager.dispose();
    _syncManager.dispose();
    syncEngine.dispose();
    conflictResolver.dispose();
    localRepository.dispose();
    databaseProvider.close();
    _wsClient.close();
    _httpClient.close();
  }
}

/// Alias for drop-in migration compatibility with `hasura_connect`.
typedef HasuraConnect = HasuraOfflineFirst;

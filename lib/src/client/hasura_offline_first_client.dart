import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../contracts/hasura_connect_interface.dart';
import '../contracts/network_status.dart';
import '../contracts/storage_interface.dart';
import '../core/exceptions.dart';
import '../core/hash_generator.dart';
import '../core/network_manager.dart';
import '../interceptors/token_interceptor.dart';
import '../network/hasura_http_client.dart';
import '../network/hasura_ws_client.dart';
import '../storage/file_storage_driver.dart';
import '../sync/sync_manager.dart';

/// Offline-first GraphQL client compatible with HasuraConnect.
class HasuraOfflineFirst implements IHasuraConnect {
  @override
  final String url;
  final Map<String, String> _headers;
  final List<Interceptor> _interceptors;

  final NetworkManager _networkManager;
  final ILocalStorageDriver _storageDriver;
  late final HasuraHttpClient _httpClient;
  late final HasuraWebSocketClient _wsClient;
  late final SyncManager _syncManager;
  final _uuid = const Uuid();

  HasuraOfflineFirst(
    this.url, {
    Map<String, String>? headers,
    FutureOr<String?> Function()? token,
    List<Interceptor>? interceptors,
    ILocalStorageDriver? storageDriver,
    NetworkManager? networkManager,
    http.Client? httpClient,
  })  : _headers = headers ?? {},
        _interceptors = [...?interceptors],
        _networkManager = networkManager ?? NetworkManager(),
        _storageDriver = storageDriver ?? FileStorageDriver() {
    if (token != null) {
      _interceptors.insert(0, TokenInterceptor(token));
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
  void simulateOffline(bool offline) => _networkManager.simulateOffline(offline);

  /// Stream signaling when background mutation sync starts or finishes.
  Stream<bool> get onSyncStateChanged => _syncManager.onSyncStateChanged;

  /// Stream of mutations synced successfully when back online.
  Stream<OutboxItem> get onSyncedItem => _syncManager.onSyncedItem;

  /// Storage driver used by this client.
  ILocalStorageDriver get storageDriver => _storageDriver;

  /// Registers a network status listener callback and returns a disposer function.
  @override
  VoidCallback addConnectivityListener(ConnectivityListener callback) {
    return _networkManager.addListener(callback);
  }

  String? _extractTableFromQuery(String document) {
    final normalized = document.replaceAll(RegExp(r'#[^\n\r]*'), '');
    final match =
        RegExp(r'(?:query[^{]*\{\s*|{\s*)([a-zA-Z0-9_]+)').firstMatch(normalized);
    return match?.group(1);
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

  Future<void> _applyMutationToLocalCache(
    String document,
    Map<String, dynamic>? variables,
  ) async {
    try {
      final insertMatch =
          RegExp(r'insert_([a-zA-Z0-9_]+?)(?:_one|\b|\()').firstMatch(document);
      final updateMatch =
          RegExp(r'update_([a-zA-Z0-9_]+?)(?:_by_pk|\b|\()').firstMatch(document);
      final deleteMatch =
          RegExp(r'delete_([a-zA-Z0-9_]+?)(?:_by_pk|\b|\()').firstMatch(document);

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

    // Update all matching cached queries
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
        }
        if (cacheData.containsKey('list') && cacheData['list'] is List) {
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

  @override
  Future<dynamic> query(
    String document, {
    String? key,
    Map<String, dynamic>? variables,
  }) async {
    final queryHash = HashGenerator.generate(document, variables);
    final tableName = key ?? _extractTableFromQuery(document);
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

      // Save to local cache by queryHash
      if (data is Map<String, dynamic>) {
        await _storageDriver.saveCache(queryHash, data);
      } else if (data is List) {
        await _storageDriver.saveCache(queryHash, {'list': data});
      }

      // Also index by table name
      if (tableName != null) {
        if (data is List) {
          await _storageDriver.saveCache(
            'table:$tableName',
            {'list': data, tableName: data},
          );
        } else if (data is Map<String, dynamic> &&
            data.containsKey(tableName)) {
          await _storageDriver.saveCache(
            'table:$tableName',
            {'list': data[tableName], tableName: data[tableName]},
          );
        }
      }

      return data;
    } else {
      // Offline fallback
      var cached = await _storageDriver.getCache(queryHash);

      // Fallback to table-level cache if queryHash missed
      if (cached == null && tableName != null) {
        cached = await _storageDriver.getCache('table:$tableName');
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

      throw HasuraCacheMissException(
        queryHash: queryHash,
        message: 'No cached response found for this query while offline.',
      );
    }
  }

  @override
  Future<dynamic> mutation(
    String document, {
    String? key,
    Map<String, dynamic>? variables,
  }) async {
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
      // Enqueue to outbox for background synchronization
      final outboxItem = OutboxItem(
        id: _uuid.v4(),
        document: document,
        variables: variables,
        status: OutboxStatus.pending,
      );

      await _storageDriver.enqueueOutbox(outboxItem);
      // Immediately reflect mutation on local cache so queries see it offline
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

  @override
  Future<void> synchronize() async {
    await _syncManager.synchronize();
  }

  @override
  void dispose() {
    _networkManager.dispose();
    _syncManager.dispose();
    _wsClient.close();
    _httpClient.close();
  }
}

/// Alias for drop-in migration compatibility with `hasura_connect`.
typedef HasuraConnect = HasuraOfflineFirst;

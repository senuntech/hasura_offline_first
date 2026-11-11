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

  @override
  Future<dynamic> query(
    String document, {
    String? key,
    Map<String, dynamic>? variables,
  }) async {
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

      // Save to local cache
      if (data is Map<String, dynamic>) {
        await _storageDriver.saveCache(queryHash, data);
      } else if (data is List) {
        await _storageDriver.saveCache(queryHash, {'list': data});
      }

      return data;
    } else {
      // Offline fallback
      final cached = await _storageDriver.getCache(queryHash);
      if (cached != null) {
        if (cached.containsKey('list') && cached.keys.length == 1) {
          return cached['list'];
        }
        if (key != null && cached.containsKey(key)) {
          return cached[key];
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

      return await _httpClient.execute(request);
    } else {
      // Enqueue to outbox for background synchronization
      final outboxItem = OutboxItem(
        id: _uuid.v4(),
        document: document,
        variables: variables,
        status: OutboxStatus.pending,
      );

      await _storageDriver.enqueueOutbox(outboxItem);

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


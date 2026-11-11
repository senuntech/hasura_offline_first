import 'dart:async';
import '../contracts/hasura_connect_interface.dart';
import '../contracts/network_status.dart';
import '../contracts/storage_interface.dart';
import '../core/exceptions.dart';
import '../core/network_manager.dart';
import '../network/hasura_http_client.dart';

/// Manages the outbox queue, reacting to network connectivity changes to drain pending mutations.
class SyncManager {
  final ILocalStorageDriver storageDriver;
  final NetworkManager networkManager;
  final HasuraHttpClient httpClient;
  final String url;
  final Map<String, String> Function() headersProvider;

  bool _isSyncing = false;
  StreamSubscription<NetworkStatus>? _networkSubscription;

  final StreamController<bool> _syncStateController =
      StreamController<bool>.broadcast();
  final StreamController<OutboxItem> _syncedItemController =
      StreamController<OutboxItem>.broadcast();

  SyncManager({
    required this.storageDriver,
    required this.networkManager,
    required this.httpClient,
    required this.url,
    required this.headersProvider,
  }) {
    _init();
  }

  /// Emits true when synchronization is actively running, false when idle.
  Stream<bool> get onSyncStateChanged => _syncStateController.stream;

  /// Emits each [OutboxItem] successfully executed and drained.
  Stream<OutboxItem> get onSyncedItem => _syncedItemController.stream;

  bool get isSyncing => _isSyncing;

  void _init() {
    _networkSubscription = networkManager.onStatusChanged.listen((status) {
      if (status == NetworkStatus.online) {
        synchronize();
      }
    });
  }

  /// Drains all pending mutations stored in the outbox in FIFO order.
  Future<void> synchronize() async {
    if (_isSyncing) return;
    if (networkManager.currentStatus != NetworkStatus.online) return;

    _isSyncing = true;
    _syncStateController.add(true);

    try {
      final pendingItems = await storageDriver.getPendingOutbox();

      for (final item in pendingItems) {
        // If network went down mid-synchronization, stop
        if (networkManager.currentStatus != NetworkStatus.online) {
          break;
        }

        await _processItem(item);
      }
    } finally {
      _isSyncing = false;
      if (!_syncStateController.isClosed) {
        _syncStateController.add(false);
      }
    }
  }

  Future<void> _processItem(OutboxItem item) async {
    final processingItem = item.copyWith(
      status: OutboxStatus.processing,
      retryCount: item.retryCount + 1,
    );
    await storageDriver.updateOutbox(processingItem);

    try {
      final request = Request(
        url: url,
        document: item.document,
        variables: item.variables,
        headers: headersProvider(),
        type: 'mutation',
      );

      await httpClient.execute(request);

      // Successfully executed
      await storageDriver.removeOutbox(item.id);
      if (!_syncedItemController.isClosed) {
        _syncedItemController.add(item);
      }
    } catch (e) {
      final failedItem = item.copyWith(
        status: OutboxStatus.failed,
        retryCount: item.retryCount + 1,
        lastError: e.toString(),
      );
      await storageDriver.updateOutbox(failedItem);

      // If network exception, stop processing remaining items
      if (e is HasuraNoConnectionException) {
        rethrow;
      }
    }
  }

  void dispose() {
    _networkSubscription?.cancel();
    _syncStateController.close();
    _syncedItemController.close();
  }
}


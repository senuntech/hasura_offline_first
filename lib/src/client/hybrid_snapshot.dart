import 'dart:async';
import 'dart:convert';
import '../contracts/hasura_connect_interface.dart';
import '../contracts/network_status.dart';
import '../core/network_manager.dart';
import '../local_database/local_table_repository.dart';

/// A high-performance Local-First, hybrid implementation of [Snapshot] that provides:
/// - 0ms instant local SQLite data emission
/// - Reactive offline updates via [LocalTableRepository]
/// - Intelligent Content Deduplication to prevent unnecessary UI rebuilds ("Double-Emit")
/// - Microtask coalescing to throttle rapid sequential mutations into a single query
/// - Resilient upstream synchronization via remote WebSocket subscriptions
class HybridSnapshot<T> implements Snapshot<T> {
  final String tableName;
  final String document;
  final Map<String, dynamic>? variables;
  final LocalTableRepository localRepository;
  final NetworkManager networkManager;
  final Future<Snapshot> Function() subscribeRemote;
  final Future<T> Function() queryLocal;
  final Future<void> Function(dynamic remoteData)? onRemoteData;

  final StreamController<T> _controller = StreamController<T>.broadcast();
  T? _lastValue;
  String? _lastJsonSignature;

  StreamSubscription? _localSub;
  StreamSubscription? _networkSub;
  Snapshot? _remoteSnapshot;
  StreamSubscription? _remoteStreamSub;
  bool _isClosed = false;
  bool _isScheduledFetch = false;
  bool _needsAnotherFetch = false;

  HybridSnapshot({
    required this.tableName,
    required this.document,
    this.variables,
    required this.localRepository,
    required this.networkManager,
    required this.subscribeRemote,
    required this.queryLocal,
    this.onRemoteData,
  }) {
    _initialize();
  }

  @override
  Stream<T> get stream => _controller.stream;

  @override
  T? get value => _lastValue;

  Future<void> _initialize() async {
    // 1. Instant 0ms local emission from SQLite replica
    await _fetchAndEmitLocal();

    // 2. React to local SQLite mutations with microtask coalescing
    _localSub = localRepository.onTableChanged.listen((event) {
      if (event.tableName == tableName && !_isClosed) {
        _scheduleCoalescedLocalFetch();
      }
    });

    // 3. Monitor network connectivity for resilient remote reconnection
    _networkSub = networkManager.onStatusChanged.listen((status) {
      if (status == NetworkStatus.online && _remoteSnapshot == null && !_isClosed) {
        _connectRemote();
      }
    });

    // 4. Connect to remote WebSocket if currently online
    if (networkManager.currentStatus == NetworkStatus.online) {
      _connectRemote();
    }
  }

  /// Coalesces rapid sequential changes into a single asynchronous microtask
  /// to protect the UI from frame drops (60-120 FPS).
  void _scheduleCoalescedLocalFetch() {
    if (_isClosed) return;
    if (_isScheduledFetch) {
      _needsAnotherFetch = true;
      return;
    }
    _isScheduledFetch = true;
    scheduleMicrotask(() async {
      try {
        if (!_isClosed) {
          await _fetchAndEmitLocal();
        }
      } finally {
        _isScheduledFetch = false;
        if (_needsAnotherFetch && !_isClosed) {
          _needsAnotherFetch = false;
          _scheduleCoalescedLocalFetch();
        }
      }
    });
  }

  Future<void> _fetchAndEmitLocal() async {
    if (_isClosed) return;
    try {
      final data = await queryLocal();
      _emitIfChanged(data);
    } catch (e, stack) {
      if (!_controller.isClosed) {
        _controller.addError(e, stack);
      }
    }
  }

  /// Deduplicates emissions: if the content has not changed, suppress redundant emission.
  void _emitIfChanged(T data) {
    if (_isClosed) return;

    try {
      final signature = jsonEncode(data);
      if (signature == _lastJsonSignature) {
        // Redundant data: suppress emit to prevent unnecessary widget rebuilds
        return;
      }
      _lastJsonSignature = signature;
    } catch (_) {
      // Fallback if not JSON-serializable
      if (identical(data, _lastValue)) return;
    }

    _lastValue = data;
    if (!_controller.isClosed) {
      _controller.add(data);
    }
  }

  Future<void> _connectRemote() async {
    if (_isClosed || _remoteSnapshot != null) return;

    try {
      final snapshot = await subscribeRemote();
      if (_isClosed) {
        snapshot.close();
        return;
      }

      _remoteSnapshot = snapshot;
      _remoteStreamSub = snapshot.stream.listen(
        (remoteData) async {
          if (_isClosed) return;

          // Non-blocking background sync into local SQLite
          if (onRemoteData != null) {
            unawaited(onRemoteData!(remoteData).catchError((_) {}));
          }

          if (remoteData is T) {
            _emitIfChanged(remoteData);
          }
        },
        onError: (err) {
          // Keep local stream alive even if remote WebSocket errors out
          _remoteSnapshot?.close();
          _remoteSnapshot = null;
          _remoteStreamSub?.cancel();
          _remoteStreamSub = null;
        },
        onDone: () {
          _remoteSnapshot = null;
          _remoteStreamSub?.cancel();
          _remoteStreamSub = null;
        },
      );
    } catch (e) {
      // Remote connection failed (e.g. offline/timeout) - gracefully stay on local SQLite
      _remoteSnapshot = null;
    }
  }

  @override
  void clean() {
    _lastValue = null;
    _lastJsonSignature = null;
    _remoteSnapshot?.clean();
  }

  @override
  void close() {
    _isClosed = true;
    _localSub?.cancel();
    _networkSub?.cancel();
    _remoteStreamSub?.cancel();
    _remoteSnapshot?.close();
    _remoteSnapshot = null;
    _controller.close();
  }
}

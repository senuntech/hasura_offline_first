import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../contracts/network_status.dart';

/// Manages network connectivity detection using `connectivity_plus`.
class NetworkManager {
  final Connectivity _connectivity;
  final StreamController<NetworkStatus> _statusController =
      StreamController<NetworkStatus>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  NetworkStatus _lastKnownStatus = NetworkStatus.offline;
  bool _isSimulatingOffline = false;

  NetworkManager({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity() {
    _init();
  }

  /// Broadcast stream of connectivity changes.
  Stream<NetworkStatus> get onStatusChanged => _statusController.stream;

  /// Returns true if currently simulating offline mode.
  bool get isSimulatingOffline => _isSimulatingOffline;

  /// Returns the current connectivity status.
  NetworkStatus get currentStatus =>
      _isSimulatingOffline ? NetworkStatus.offline : _lastKnownStatus;

  /// Manually simulates offline mode for testing and demonstration purposes.
  void simulateOffline(bool offline) {
    if (_isSimulatingOffline == offline) return;
    _isSimulatingOffline = offline;

    if (offline) {
      _updateStatus(NetworkStatus.offline);
    } else {
      // Restore real connection state
      _connectivity.checkConnectivity().then((results) {
        final status = _parseConnectivityResults(results);
        _updateStatus(status);
      }).catchError((_) {
        _updateStatus(NetworkStatus.offline);
      });
    }
  }

  /// Returns true if currently connected to a network.
  Future<bool> get isConnected async {
    if (_isSimulatingOffline) {
      return false;
    }
    try {
      final results = await _connectivity.checkConnectivity();
      final status = _parseConnectivityResults(results);
      _updateStatus(status);
      return status == NetworkStatus.online;
    } catch (_) {
      return false;
    }
  }

  void _init() {
    // Initial check
    _connectivity.checkConnectivity().then((results) {
      final status = _parseConnectivityResults(results);
      _updateStatus(status);
    }).catchError((_) {
      _updateStatus(NetworkStatus.offline);
    });

    // Listen for changes
    _subscription = _connectivity.onConnectivityChanged.listen(
      (results) {
        final status = _parseConnectivityResults(results);
        _updateStatus(status);
      },
      onError: (_) {
        _updateStatus(NetworkStatus.offline);
      },
    );
  }

  NetworkStatus _parseConnectivityResults(List<ConnectivityResult> results) {
    if (results.isEmpty) {
      return NetworkStatus.offline;
    }
    final hasConnection = results.any((r) => r != ConnectivityResult.none);
    return hasConnection ? NetworkStatus.online : NetworkStatus.offline;
  }

  void _updateStatus(NetworkStatus newStatus) {
    if (_lastKnownStatus != newStatus) {
      _lastKnownStatus = newStatus;
      if (!_statusController.isClosed) {
        _statusController.add(newStatus);
      }
    }
  }

  /// Adds a listener callback with a disposer return function.
  VoidCallback addListener(ConnectivityListener listener) {
    listener(_lastKnownStatus);
    final sub = onStatusChanged.listen(listener);
    return () {
      sub.cancel();
    };
  }

  /// Disposes resources and closes the stream.
  void dispose() {
    _subscription?.cancel();
    _statusController.close();
  }
}


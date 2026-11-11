import 'package:flutter/material.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';

/// Controller that monitors network status changes using HasuraOfflineFirst client.
class ConnectivityController extends ChangeNotifier {
  final HasuraOfflineFirst client;
  NetworkStatus _status = NetworkStatus.online;
  VoidCallback? _cancelListener;

  ConnectivityController(this.client) {
    _init();
  }

  NetworkStatus get status => _status;
  bool get isOnline => _status == NetworkStatus.online;
  bool get isSimulatingOffline => client.isSimulatingOffline;

  /// Toggles manual offline simulation.
  void toggleOfflineSimulation() {
    setSimulateOffline(!isSimulatingOffline);
  }

  /// Sets manual offline simulation status.
  void setSimulateOffline(bool simulate) {
    client.simulateOffline(simulate);
    notifyListeners();
  }

  void _init() {
    _cancelListener = client.addConnectivityListener((newStatus) {
      if (_status != newStatus) {
        _status = newStatus;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _cancelListener?.call();
    super.dispose();
  }
}


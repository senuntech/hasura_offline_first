import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

class FakeConnectivity implements Connectivity {
  final StreamController<List<ConnectivityResult>> _controller =
      StreamController<List<ConnectivityResult>>.broadcast();
  List<ConnectivityResult> _current = [ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      _controller.stream;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    return _current;
  }

  void emit(List<ConnectivityResult> results) {
    _current = results;
    _controller.add(results);
  }

  void dispose() {
    _controller.close();
  }
}


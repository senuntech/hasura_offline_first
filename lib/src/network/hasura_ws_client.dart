import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../contracts/hasura_connect_interface.dart';
import '../core/exceptions.dart';

/// Implementation of [Snapshot] representing an active GraphQL subscription.
class SnapshotImpl<T> implements Snapshot<T> {
  final String id;
  final StreamController<T> _controller = StreamController<T>.broadcast();
  final void Function(String id) _onClose;
  T? _lastValue;

  SnapshotImpl({
    required this.id,
    required void Function(String id) onClose,
  }) : _onClose = onClose;

  @override
  Stream<T> get stream => _controller.stream;

  @override
  T? get value => _lastValue;

  void add(T data) {
    _lastValue = data;
    if (!_controller.isClosed) {
      _controller.add(data);
    }
  }

  void addError(Object error, [StackTrace? stackTrace]) {
    if (!_controller.isClosed) {
      _controller.addError(error, stackTrace);
    }
  }

  @override
  void clean() {
    _lastValue = null;
  }

  @override
  void close() {
    _onClose(id);
    _controller.close();
  }
}

class _ActiveSubscription {
  final String id;
  final String document;
  final Map<String, dynamic>? variables;
  final SnapshotImpl snapshot;

  _ActiveSubscription({
    required this.id,
    required this.document,
    this.variables,
    required this.snapshot,
  });
}

/// WebSocket client managing subscriptions according to Hasura GraphQL WebSocket protocol
/// with automatic resilient reconnection and exponential backoff.
class HasuraWebSocketClient {
  final String url;
  final Map<String, String> Function() headersProvider;
  final _uuid = const Uuid();

  WebSocketChannel? _channel;
  StreamSubscription? _channelSub;
  bool _isConnected = false;
  bool _isDisposed = false;
  Completer<void>? _connectionCompleter;

  final Map<String, _ActiveSubscription> _activeSubscriptions = {};

  // Reconnection backoff state
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectDelaySeconds = 16;

  HasuraWebSocketClient({
    required this.url,
    required this.headersProvider,
  });

  bool get isConnected => _isConnected;

  String get _wsUrl {
    if (url.startsWith('https://')) {
      return url.replaceFirst('https://', 'wss://');
    } else if (url.startsWith('http://')) {
      return url.replaceFirst('http://', 'ws://');
    }
    return url;
  }

  Future<void> _connect() async {
    if (_isConnected) return;
    if (_connectionCompleter != null) {
      return _connectionCompleter!.future;
    }

    _connectionCompleter = Completer<void>();
    try {
      final uri = Uri.parse(_wsUrl);
      _channel = WebSocketChannel.connect(
        uri,
        protocols: ['graphql-ws'],
      );

      _channelSub = _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );

      // Send connection_init
      final initPayload = {
        'type': 'connection_init',
        'payload': {'headers': headersProvider()},
      };
      _channel!.sink.add(jsonEncode(initPayload));
    } catch (e) {
      _isConnected = false;
      _connectionCompleter?.completeError(e);
      _connectionCompleter = null;
      _scheduleReconnect();
      rethrow;
    }

    return _connectionCompleter!.future;
  }

  void _onMessage(dynamic rawMessage) {
    try {
      final Map<String, dynamic> message = jsonDecode(rawMessage.toString());
      final type = message['type'] as String?;
      final id = message['id'] as String?;

      if (type == 'connection_ack') {
        _isConnected = true;
        _reconnectAttempts = 0;
        _reconnectTimer?.cancel();
        _reconnectTimer = null;

        if (_connectionCompleter != null && !_connectionCompleter!.isCompleted) {
          _connectionCompleter!.complete();
        }

        // Resubscribe all active subscriptions upon reconnect
        _resubscribeAll();
      } else if (type == 'data' && id != null) {
        final sub = _activeSubscriptions[id];
        if (sub != null) {
          final payload = message['payload'];
          if (payload is Map<String, dynamic>) {
            if (payload.containsKey('errors') && payload['errors'] is List) {
              final errors = payload['errors'] as List;
              sub.snapshot.addError(HasuraRequestError.fromGraphQLErrors(errors));
            } else {
              sub.snapshot.add(payload['data'] ?? payload);
            }
          } else {
            sub.snapshot.add(payload);
          }
        }
      } else if (type == 'error' && id != null) {
        final sub = _activeSubscriptions[id];
        if (sub != null) {
          sub.snapshot.addError(HasuraError(
            message['payload']?.toString() ?? 'Subscription error',
            extensions: message['payload'],
          ));
        }
      } else if (type == 'complete' && id != null) {
        _activeSubscriptions[id]?.snapshot.close();
        _activeSubscriptions.remove(id);
      }
    } catch (e, stack) {
      for (final sub in _activeSubscriptions.values) {
        sub.snapshot.addError(e, stack);
      }
    }
  }

  void _onError(dynamic error) {
    _isConnected = false;
    _scheduleReconnect();
  }

  void _onDone() {
    _isConnected = false;
    _connectionCompleter = null;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_isDisposed || _activeSubscriptions.isEmpty || _reconnectTimer != null) {
      return;
    }

    final delaySeconds = min(pow(2, _reconnectAttempts).toInt(), _maxReconnectDelaySeconds);
    _reconnectAttempts++;

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      _reconnectTimer = null;
      if (!_isConnected && !_isDisposed && _activeSubscriptions.isNotEmpty) {
        try {
          await _connect();
        } catch (_) {
          _scheduleReconnect();
        }
      }
    });
  }

  /// Explicit trigger to reconnect immediately (e.g. when network becomes available).
  Future<void> reconnect() async {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    try {
      await _connect();
    } catch (_) {}
  }

  void _resubscribeAll() {
    for (final sub in _activeSubscriptions.values) {
      final startMessage = {
        'id': sub.id,
        'type': 'start',
        'payload': {
          'query': sub.document,
          if (sub.variables != null) 'variables': sub.variables,
        },
      };
      try {
        _channel?.sink.add(jsonEncode(startMessage));
      } catch (_) {}
    }
  }

  /// Initiates a GraphQL subscription and returns a reactive [Snapshot].
  Future<Snapshot> subscribe(
    String document, {
    String? key,
    Map<String, dynamic>? variables,
  }) async {
    await _connect();

    final id = _uuid.v4();
    final snapshot = SnapshotImpl(
      id: id,
      onClose: (closedId) => _stopSubscription(closedId),
    );

    final activeSub = _ActiveSubscription(
      id: id,
      document: document,
      variables: variables,
      snapshot: snapshot,
    );
    _activeSubscriptions[id] = activeSub;

    final startMessage = {
      'id': id,
      'type': 'start',
      'payload': {
        'query': document,
        if (variables != null) 'variables': variables,
      },
    };

    _channel?.sink.add(jsonEncode(startMessage));
    return snapshot;
  }

  void _stopSubscription(String id) {
    if (_isConnected && _channel != null) {
      final stopMessage = {
        'id': id,
        'type': 'stop',
      };
      try {
        _channel?.sink.add(jsonEncode(stopMessage));
      } catch (_) {}
    }
    _activeSubscriptions.remove(id);
  }

  void close() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    for (final sub in _activeSubscriptions.values) {
      sub.snapshot.close();
    }
    _activeSubscriptions.clear();
    _channelSub?.cancel();
    _channel?.sink.close();
    _isConnected = false;
  }
}

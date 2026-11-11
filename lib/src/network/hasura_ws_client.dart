import 'dart:async';
import 'dart:convert';
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

/// WebSocket client managing subscriptions according to Hasura GraphQL WebSocket protocol.
class HasuraWebSocketClient {
  final String url;
  final Map<String, String> Function() headersProvider;
  final _uuid = const Uuid();

  WebSocketChannel? _channel;
  StreamSubscription? _channelSub;
  bool _isConnected = false;
  final Map<String, SnapshotImpl> _activeSnapshots = {};
  Completer<void>? _connectionCompleter;

  HasuraWebSocketClient({
    required this.url,
    required this.headersProvider,
  });

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
        if (_connectionCompleter != null &&
            !_connectionCompleter!.isCompleted) {
          _connectionCompleter!.complete();
        }
      } else if (type == 'data' && id != null) {
        final snapshot = _activeSnapshots[id];
        if (snapshot != null) {
          final payload = message['payload'];
          if (payload is Map<String, dynamic>) {
            if (payload.containsKey('errors') && payload['errors'] is List) {
              final errors = payload['errors'] as List;
              snapshot.addError(HasuraRequestError.fromGraphQLErrors(errors));
            } else {
              snapshot.add(payload['data'] ?? payload);
            }
          } else {
            snapshot.add(payload);
          }
        }
      } else if (type == 'error' && id != null) {
        final snapshot = _activeSnapshots[id];
        if (snapshot != null) {
          snapshot.addError(HasuraError(
            message['payload']?.toString() ?? 'Subscription error',
            extensions: message['payload'],
          ));
        }
      } else if (type == 'complete' && id != null) {
        _activeSnapshots[id]?.close();
        _activeSnapshots.remove(id);
      }
    } catch (e, stack) {
      for (final snapshot in _activeSnapshots.values) {
        snapshot.addError(e, stack);
      }
    }
  }

  void _onError(dynamic error) {
    _isConnected = false;
    for (final snapshot in _activeSnapshots.values) {
      snapshot.addError(HasuraError('WebSocket error: $error'));
    }
  }

  void _onDone() {
    _isConnected = false;
    _connectionCompleter = null;
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
    _activeSnapshots[id] = snapshot;

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
      _channel?.sink.add(jsonEncode(stopMessage));
    }
    _activeSnapshots.remove(id);
  }

  void close() {
    for (final snapshot in _activeSnapshots.values) {
      snapshot.close();
    }
    _activeSnapshots.clear();
    _channelSub?.cancel();
    _channel?.sink.close();
    _isConnected = false;
  }
}

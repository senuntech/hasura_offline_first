import 'dart:async';
import 'network_status.dart';
import '../core/exceptions.dart';

/// HTTP/GraphQL request envelope passed through interceptors.
class Request {
  final String url;
  final String document;
  final Map<String, dynamic>? variables;
  final Map<String, String> headers;
  final String? key;
  final String type; // 'query', 'mutation', 'subscription'

  Request({
    required this.url,
    required this.document,
    this.variables,
    Map<String, String>? headers,
    this.key,
    required this.type,
  }) : headers = headers ?? {};

  Request copyWith({
    String? url,
    String? document,
    Map<String, dynamic>? variables,
    Map<String, String>? headers,
    String? key,
    String? type,
  }) {
    return Request(
      url: url ?? this.url,
      document: document ?? this.document,
      variables: variables ?? this.variables,
      headers: headers ?? this.headers,
      key: key ?? this.key,
      type: type ?? this.type,
    );
  }
}

/// HTTP/GraphQL response envelope returned from network calls.
class Response {
  final dynamic data;
  final int statusCode;
  final Request request;

  Response({
    required this.data,
    required this.statusCode,
    required this.request,
  });
}

/// Base class for HasuraConnect-compatible interceptors.
abstract class Interceptor {
  FutureOr<Request?> onRequest(Request request) async => request;
  FutureOr<Response?> onResponse(Response response) async => response;
  FutureOr<HasuraError?> onError(HasuraError error) async => error;
  FutureOr<void> onSubscription(Request request, Snapshot snapshot) async {}
}

/// Reactive snapshot representing a live subscription over WebSocket, compatible with HasuraConnect.
abstract class Snapshot<T> {
  Stream<T> get stream;
  T? get value;
  void close();
  void clean();
}

/// Public interface reproducing the HasuraConnect API surface + connectivity contracts.
abstract class IHasuraConnect {
  String get url;
  Map<String, String> get headers;

  /// Executes a GraphQL query. Online: queries server and updates cache. Offline: returns cached result.
  Future<dynamic> query(
    String document, {
    String? key,
    Map<String, dynamic>? variables,
  });

  /// Executes a GraphQL mutation. Online: sends directly. Offline: enqueues into Outbox.
  Future<dynamic> mutation(
    String document, {
    String? key,
    Map<String, dynamic>? variables,
  });

  /// Creates a live GraphQL subscription over WebSocket.
  Future<Snapshot> subscription(
    String document, {
    String? key,
    Map<String, dynamic>? variables,
  });

  /// Reative stream that emits whenever network status changes.
  Stream<NetworkStatus> get onConnectivityChanged;

  /// Instant check whether network is currently connected.
  Future<bool> get isConnected;

  /// Registers a connectivity listener callback with a disposer function.
  VoidCallback addConnectivityListener(ConnectivityListener callback);

  /// Synchronizes all pending mutations currently stored in the Outbox.
  Future<void> synchronize();

  /// Closes active connections and listeners.
  void dispose();
}


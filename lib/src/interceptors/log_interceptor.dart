import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import '../contracts/hasura_connect_interface.dart';
import '../core/exceptions.dart';

/// Interceptor to log requests, responses, and errors.
class LogInterceptor extends Interceptor {
  final bool request;
  final bool response;
  final bool error;

  LogInterceptor({
    this.request = true,
    this.response = true,
    this.error = true,
  });

  @override
  FutureOr<Request?> onRequest(Request request) async {
    if (this.request) {
      dev.log(
        '--> ${request.type.toUpperCase()} ${request.url}\n'
        'Headers: ${request.headers}\n'
        'Document: ${request.document}\n'
        'Variables: ${jsonEncode(request.variables ?? {})}',
        name: 'HasuraConnect',
      );
    }
    return request;
  }

  @override
  FutureOr<Response?> onResponse(Response response) async {
    if (this.response) {
      dev.log(
        '<-- ${response.statusCode} ${response.request.url}\n'
        'Payload: ${jsonEncode(response.data)}',
        name: 'HasuraConnect',
      );
    }
    return response;
  }

  @override
  FutureOr<HasuraError?> onError(HasuraError error) async {
    if (this.error) {
      dev.log(
        '<-- ERROR: ${error.message}\n'
        'Extensions: ${error.extensions}',
        name: 'HasuraConnect',
        error: error,
      );
    }
    return error;
  }
}

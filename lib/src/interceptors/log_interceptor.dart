import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import '../contracts/hasura_connect_interface.dart';
import '../core/exceptions.dart';

/// Interceptor to log requests, responses, and errors with ANSI colors.
class LogInterceptor extends Interceptor {
  static const String _reset = '\x1B[0m';
  static const String _blue = '\x1B[34m';
  static const String _green = '\x1B[32m';
  static const String _red = '\x1B[31m';

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
        '$_blue--> ${request.type.toUpperCase()} ${request.url}\n'
        'Headers: ${request.headers}\n'
        'Document: ${request.document}\n'
        'Variables: ${jsonEncode(request.variables ?? {})}$_reset',
        name: 'HasuraConnect',
      );
    }
    return request;
  }

  @override
  FutureOr<Response?> onResponse(Response response) async {
    if (this.response) {
      final hasGraphQLErrors = response.data is Map &&
          (response.data as Map).containsKey('errors') &&
          (response.data as Map)['errors'] != null;
      final isSuccess = response.statusCode >= 200 &&
          response.statusCode < 300 &&
          !hasGraphQLErrors;
      final color = isSuccess ? _green : _red;

      dev.log(
        '$color<-- ${response.statusCode} ${response.request.url}\n'
        'Payload: ${jsonEncode(response.data)}$_reset',
        name: 'HasuraConnect',
      );
    }
    return response;
  }

  @override
  FutureOr<HasuraError?> onError(HasuraError error) async {
    if (this.error) {
      dev.log(
        '$_red<-- ERROR: ${error.message}\n'
        'Extensions: ${error.extensions}$_reset',
        name: 'HasuraConnect',
        error: error,
      );
    }
    return error;
  }
}

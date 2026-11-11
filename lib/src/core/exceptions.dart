import 'dart:convert';

/// Base exception for all Hasura operations.
class HasuraError implements Exception {
  final String message;
  final dynamic request;
  final dynamic response;
  final dynamic extensions;

  const HasuraError(
    this.message, {
    this.request,
    this.response,
    this.extensions,
  });

  @override
  String toString() {
    final buffer = StringBuffer('HasuraError: $message');
    if (extensions != null) {
      buffer.write('\nExtensions: ${jsonEncode(extensions)}');
    }
    return buffer.toString();
  }
}

/// Thrown when Hasura returns an array of GraphQL errors in the response payload.
class HasuraRequestError extends HasuraError {
  final List<dynamic>? errors;

  const HasuraRequestError(
    super.message, {
    super.request,
    super.response,
    super.extensions,
    this.errors,
  });

  factory HasuraRequestError.fromGraphQLErrors(
    List<dynamic> errors, {
    dynamic request,
    dynamic response,
  }) {
    final message = errors.isNotEmpty && errors.first is Map
        ? (errors.first['message']?.toString() ?? 'GraphQL error')
        : 'GraphQL error';
    final extensions = errors.isNotEmpty && errors.first is Map
        ? errors.first['extensions']
        : null;

    return HasuraRequestError(
      message,
      request: request,
      response: response,
      extensions: extensions,
      errors: errors,
    );
  }

  @override
  String toString() => 'HasuraRequestError: $message (errors: $errors)';
}

/// Thrown when a network operation is requested while offline and cannot proceed.
class HasuraNoConnectionException extends HasuraError {
  const HasuraNoConnectionException([
    super.message = 'No active internet connection available.',
  ]);
}

/// Thrown when an offline query does not match any entry in local cache.
class HasuraCacheMissException extends HasuraError {
  final String queryHash;

  const HasuraCacheMissException({
    required this.queryHash,
    String message = 'Query result not found in local cache.',
  }) : super(message);

  @override
  String toString() => 'HasuraCacheMissException: $message (hash: $queryHash)';
}


import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../contracts/hasura_connect_interface.dart';
import '../core/exceptions.dart';

/// Handles HTTP GraphQL communications with Hasura, pipeline of interceptors, and error extraction.
class HasuraHttpClient {
  final http.Client _client;
  final List<Interceptor> interceptors;

  HasuraHttpClient({
    http.Client? client,
    List<Interceptor>? interceptors,
  })  : _client = client ?? http.Client(),
        interceptors = interceptors ?? [];

  /// Executes a GraphQL request through interceptors and extracts the response payload.
  Future<dynamic> execute(Request request) async {
    Request currentRequest = request;

    // Execute onRequest interceptors
    for (final interceptor in interceptors) {
      final intercepted = await interceptor.onRequest(currentRequest);
      if (intercepted != null) {
        currentRequest = intercepted;
      }
    }

    try {
      final headers = Map<String, String>.from(currentRequest.headers);
      headers.putIfAbsent('Content-Type', () => 'application/json');
      headers.putIfAbsent('Accept', () => 'application/json');

      final body = jsonEncode({
        'query': currentRequest.document,
        if (currentRequest.variables != null)
          'variables': currentRequest.variables,
      });

      final httpResponse = await _client.post(
        Uri.parse(currentRequest.url),
        headers: headers,
        body: body,
      );

      dynamic decodedBody;
      try {
        decodedBody = jsonDecode(utf8.decode(httpResponse.bodyBytes));
      } catch (_) {
        decodedBody = httpResponse.body;
      }

      var response = Response(
        data: decodedBody,
        statusCode: httpResponse.statusCode,
        request: currentRequest,
      );

      // Execute onResponse interceptors
      for (final interceptor in interceptors) {
        final intercepted = await interceptor.onResponse(response);
        if (intercepted != null) {
          response = intercepted;
        }
      }

      if (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300) {
        if (response.data is Map<String, dynamic>) {
          final dataMap = response.data as Map<String, dynamic>;
          if (dataMap.containsKey('errors') && dataMap['errors'] is List) {
            final errorList = dataMap['errors'] as List;
            if (errorList.isNotEmpty) {
              throw HasuraRequestError.fromGraphQLErrors(
                errorList,
                request: currentRequest,
                response: response,
              );
            }
          }

          final data = dataMap['data'];
          if (currentRequest.key != null && data is Map<String, dynamic>) {
            return data[currentRequest.key];
          }
          return data ?? dataMap;
        }
        return response.data;
      } else {
        throw HasuraError(
          'HTTP ${httpResponse.statusCode}: ${httpResponse.reasonPhrase}',
          request: currentRequest,
          response: response,
        );
      }
    } on HasuraError catch (e) {
      var currentError = e;
      for (final interceptor in interceptors) {
        final intercepted = await interceptor.onError(currentError);
        if (intercepted != null) {
          currentError = intercepted;
        }
      }
      throw currentError;
    } catch (e) {
      var currentError = HasuraError(
        e.toString(),
        request: currentRequest,
      );
      for (final interceptor in interceptors) {
        final intercepted = await interceptor.onError(currentError);
        if (intercepted != null) {
          currentError = intercepted;
        }
      }
      throw currentError;
    }
  }

  void close() {
    _client.close();
  }
}


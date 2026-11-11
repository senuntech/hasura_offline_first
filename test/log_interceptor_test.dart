import 'package:flutter_test/flutter_test.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';

void main() {
  group('LogInterceptor', () {
    test('onRequest should log and return request unchanged', () async {
      final interceptor = LogInterceptor();
      final request = Request(
        url: 'https://example.com/graphql',
        type: 'query',
        document: 'query { teste }',
        variables: {'param': 1},
      );

      final result = await interceptor.onRequest(request);
      expect(result, equals(request));
    });

    test('onResponse should log and return response unchanged for success and error payloads', () async {
      final interceptor = LogInterceptor();
      final request = Request(
        url: 'https://example.com/graphql',
        type: 'query',
        document: 'query { teste }',
      );

      final successResponse = Response(
        statusCode: 200,
        data: {'data': {'teste': true}},
        request: request,
      );
      final res1 = await interceptor.onResponse(successResponse);
      expect(res1, equals(successResponse));

      final errorPayloadResponse = Response(
        statusCode: 200,
        data: {'errors': [{'message': 'Fail'}]},
        request: request,
      );
      final res2 = await interceptor.onResponse(errorPayloadResponse);
      expect(res2, equals(errorPayloadResponse));
    });

    test('onError should log and return HasuraError unchanged', () async {
      final interceptor = LogInterceptor();
      final error = HasuraError(
        'Network error',
        request: Request(
          url: 'https://example.com/graphql',
          type: 'query',
          document: 'query { teste }',
        ),
      );

      final result = await interceptor.onError(error);
      expect(result, equals(error));
    });
  });
}

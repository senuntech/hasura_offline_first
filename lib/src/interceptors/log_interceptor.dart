import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import '../contracts/hasura_connect_interface.dart';
import '../core/exceptions.dart';

/// Interceptor to log requests, responses, and errors with ANSI colors
/// and formatted box borders for clear readability in the debug console.
class LogInterceptor extends Interceptor {
  static const String _reset = '\x1B[0m';
  static const String _blue = '\x1B[34m';
  static const String _green = '\x1B[32m';
  static const String _red = '\x1B[31m';
  static const JsonEncoder _encoder = JsonEncoder.withIndent('  ');

  final bool request;
  final bool response;
  final bool error;
  final bool pretty;

  LogInterceptor({
    this.request = true,
    this.response = true,
    this.error = true,
    this.pretty = true,
  });

  String _formatJson(dynamic data) {
    if (data == null) return '{}';
    if (!pretty) return jsonEncode(data);
    try {
      return _encoder.convert(data);
    } catch (_) {
      return data.toString();
    }
  }

  String _formatBox({
    required String color,
    required String title,
    required List<String> sections,
  }) {
    final buffer = StringBuffer();
    const width = 64;
    final titleTag = '── [ $title ] ';
    final topPadding = '─' * (width - titleTag.length).clamp(4, width);

    buffer.writeln('$color┌$titleTag$topPadding');

    for (var i = 0; i < sections.length; i++) {
      if (i > 0) {
        buffer.writeln('├${'┄' * (width + 1)}');
      }
      final lines = sections[i].split('\n');
      for (final line in lines) {
        buffer.writeln('│ $line');
      }
    }

    buffer.write('└${'─' * (width + 1)}$_reset');
    return buffer.toString();
  }

  @override
  FutureOr<Request?> onRequest(Request request) async {
    if (this.request) {
      final sections = <String>[
        'URL: ${request.url}\nType: ${request.type.toUpperCase()}',
        if (request.headers.isNotEmpty) 'Headers: ${request.headers}',
        'Variables:\n${_formatJson(request.variables)}',
        'Document:\n${request.document.trim()}',
      ];

      dev.log(
        _formatBox(
          color: _blue,
          title: 'REQUEST : ${request.type.toUpperCase()}',
          sections: sections,
        ),
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
      final statusLabel = isSuccess ? 'SUCCESS' : 'GRAPHQL ERROR';

      final sections = <String>[
        'URL: ${response.request.url}\nStatus: ${response.statusCode} ($statusLabel)',
        'Payload:\n${_formatJson(response.data)}',
      ];

      dev.log(
        _formatBox(
          color: color,
          title: 'RESPONSE : ${response.statusCode}',
          sections: sections,
        ),
        name: 'HasuraConnect',
      );
    }
    return response;
  }

  @override
  FutureOr<HasuraError?> onError(HasuraError error) async {
    if (this.error) {
      final sections = <String>[
        if (error.request != null) 'URL: ${error.request!.url}',
        'Message: ${error.message}',
        if (error.extensions != null)
          'Extensions:\n${_formatJson(error.extensions)}',
      ];

      dev.log(
        _formatBox(
          color: _red,
          title: 'ERROR',
          sections: sections,
        ),
        name: 'HasuraConnect',
        error: error,
      );
    }
    return error;
  }
}

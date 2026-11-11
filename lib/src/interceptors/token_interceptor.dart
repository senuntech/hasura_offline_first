import 'dart:async';
import '../contracts/hasura_connect_interface.dart';

/// Interceptor to automatically attach authorization Bearer tokens to requests.
class TokenInterceptor extends Interceptor {
  final FutureOr<String?> Function() tokenProvider;

  TokenInterceptor(this.tokenProvider);

  @override
  FutureOr<Request?> onRequest(Request request) async {
    final token = await tokenProvider();
    if (token != null && token.isNotEmpty) {
      final updatedHeaders = Map<String, String>.from(request.headers);
      updatedHeaders['Authorization'] =
          token.startsWith('Bearer ') ? token : 'Bearer $token';
      return request.copyWith(headers: updatedHeaders);
    }
    return request;
  }
}

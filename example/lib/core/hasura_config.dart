import 'package:hasura_offline_first/hasura_offline_first.dart';

class HasuraConfig {
  static const String endpoint = 'https://formularios.hasura.app/v1/graphql';
  static const String adminSecret =
      '3rokPyyerSO2dl740GxpdkJ3lx2kkWevYm7fDiblyn6yZQaQMU2PpkLCm7UG6srN';

  static HasuraOfflineFirst createClient() {
    return HasuraOfflineFirst(
      endpoint,
      headers: {
        'x-hasura-admin-secret': adminSecret,
        'Content-Type': 'application/json',
      },
      interceptors: [
        LogInterceptor(request: true, response: true, error: true),
      ],
    );
  }
}


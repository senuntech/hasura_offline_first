import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'mocks/fake_connectivity.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('Multi-Tenant vs Single-Tenant Architecture Tests', () {
    test('Single-Tenant mode uses default database and does not require tenant column', () async {
      final dbProvider = DatabaseProvider(
        dbName: DatabaseProvider.resolveDatabaseName(null),
        customDatabaseFactory: databaseFactoryFfi,
      );
      final repo = LocalTableRepository(databaseProvider: dbProvider);

      await repo.insert('tarefas', {'id': 'st-1', 'title': 'Lavar carro'});

      final rows = await repo.query('tarefas');
      expect(rows.length, equals(1));
      expect(rows.first['id'], equals('st-1'));
      expect(rows.first.containsKey('tenant_id'), isFalse);

      await dbProvider.deleteDatabaseFile();
    });

    test('Multi-Tenant mode auto-injects tenantId and isolates data between tenants', () async {
      const tenantA = TenantConfig(tenantId: 'empresa_alfa');
      const tenantB = TenantConfig(tenantId: 'empresa_beta');

      final dbProviderA = DatabaseProvider(
        dbName: DatabaseProvider.resolveDatabaseName(tenantA),
        customDatabaseFactory: databaseFactoryFfi,
      );
      final dbProviderB = DatabaseProvider(
        dbName: DatabaseProvider.resolveDatabaseName(tenantB),
        customDatabaseFactory: databaseFactoryFfi,
      );

      final repoA = LocalTableRepository(
        databaseProvider: dbProviderA,
        tenantConfig: tenantA,
      );
      final repoB = LocalTableRepository(
        databaseProvider: dbProviderB,
        tenantConfig: tenantB,
      );

      // Inserção no Tenant A (sem passar tenant_id explicitamente)
      await repoA.insert('pedidos', {'id': 'ped-1', 'valor': 150.0});

      // Inserção no Tenant B
      await repoB.insert('pedidos', {'id': 'ped-2', 'valor': 300.0});

      // Consulta no Tenant A: deve conter apenas o pedido 1 com tenant_id auto-injetado
      final rowsA = await repoA.query('pedidos');
      expect(rowsA.length, equals(1));
      expect(rowsA.first['id'], equals('ped-1'));
      expect(rowsA.first['tenant_id'], equals('empresa_alfa'));

      // Consulta no Tenant B: deve conter apenas o pedido 2
      final rowsB = await repoB.query('pedidos');
      expect(rowsB.length, equals(1));
      expect(rowsB.first['id'], equals('ped-2'));
      expect(rowsB.first['tenant_id'], equals('empresa_beta'));

      // Validação de isolamento: Tenant A nunca contém o id do Tenant B
      expect(rowsA.any((r) => r['id'] == 'ped-2'), isFalse);
      expect(rowsB.any((r) => r['id'] == 'ped-1'), isFalse);

      await dbProviderA.deleteDatabaseFile();
      await dbProviderB.deleteDatabaseFile();
    });

    test('HasuraOfflineFirst switchTenant switches active database safely', () async {
      final fakeConn = FakeConnectivity()..emit([ConnectivityResult.none]);
      final netManager = NetworkManager(connectivity: fakeConn);

      const tenant1 = TenantConfig(tenantId: 'tenant_prime');
      const tenant2 = TenantConfig(tenantId: 'tenant_secundario');

      final client = HasuraOfflineFirst(
        'https://example.com/graphql',
        networkManager: netManager,
        tenantConfig: tenant1,
        customDatabaseProvider: DatabaseProvider(
          dbName: DatabaseProvider.resolveDatabaseName(tenant1),
          customDatabaseFactory: databaseFactoryFfi,
        ),
      );

      // Inserir registro no tenant 1
      await client.localRepository.insert('clientes', {'id': 'c-1', 'nome': 'Cliente 1'});
      final res1 = await client.localRepository.query('clientes');
      expect(res1.length, equals(1));
      expect(res1.first['nome'], equals('Cliente 1'));

      // Alternar para tenant 2
      await client.switchTenant(tenant2);
      expect(client.tenantConfig?.tenantId, equals('tenant_secundario'));

      // No tenant 2, a tabela clientes deve estar vazia inicialmente
      final res2 = await client.localRepository.query('clientes');
      expect(res2, isEmpty);

      // Inserir registro no tenant 2
      await client.localRepository.insert('clientes', {'id': 'c-2', 'nome': 'Cliente 2'});
      final res2After = await client.localRepository.query('clientes');
      expect(res2After.length, equals(1));
      expect(res2After.first['nome'], equals('Cliente 2'));

      // Voltar para tenant 1
      await client.switchTenant(tenant1);
      final res1Return = await client.localRepository.query('clientes');
      expect(res1Return.length, equals(1));
      expect(res1Return.first['nome'], equals('Cliente 1'));

      // Limpeza de testes
      await client.clearTenantData('tenant_prime');
      await client.clearTenantData('tenant_secundario');
      client.dispose();
    });

    test('SyncEngine _pullDeltas scopes query with where: { tenant_id: { _eq: \$tenantId } } when Multi-Tenant', () async {
      late String interceptedQuery;
      Map<String, dynamic>? interceptedVariables;

      final mockHttp = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        interceptedQuery = body['query'] as String;
        interceptedVariables = body['variables'] as Map<String, dynamic>?;

        return http.Response(
          jsonEncode({
            'data': {
              'produtos': [
                {'id': 'prod-1', 'nome': 'Notebook', 'empresa_id': 'org_super'}
              ]
            }
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      const multiConfig = TenantConfig(tenantId: 'org_super', tenantColumn: 'empresa_id');
      final dbProvider = DatabaseProvider(
        dbName: DatabaseProvider.resolveDatabaseName(multiConfig),
        customDatabaseFactory: databaseFactoryFfi,
      );

      final fakeConn = FakeConnectivity()..emit([ConnectivityResult.none]);
      final netManager = NetworkManager(connectivity: fakeConn);

      final client = HasuraOfflineFirst(
        'https://example.com/graphql',
        httpClient: mockHttp,
        networkManager: netManager,
        tenantConfig: multiConfig,
        customDatabaseProvider: dbProvider,
        tables: {'produtos'},
      );

      // Pré-inicializar tabela localmente
      await client.localRepository.insert('produtos', {'id': 'prod-local', 'nome': 'Mouse'});

      // Simular volta da conexão para disparar pull
      fakeConn.emit([ConnectivityResult.wifi]);
      await client.synchronize();

      // Verificar que a query gerada pelo Pull continha o filtro de tenant
      expect(interceptedQuery, contains(r'($tenantId: String!)'));
      expect(interceptedQuery, contains('where: { empresa_id: { _eq: \$tenantId } }'));
      expect(interceptedVariables?['tenantId'], equals('org_super'));

      await dbProvider.deleteDatabaseFile();
      client.dispose();
    });
  });
}

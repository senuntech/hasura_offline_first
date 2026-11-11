# Hasura Offline First

Um cliente GraphQL autônomo, reativo e **Local-First / Offline-First** para Dart e Flutter, projetado com contratos públicos compatíveis com o `hasura_connect: ^5.0.0+3`, agregando suporte nativo a **Réplica Local em Banco SQLite (0ms de latência)**, **Auto-Migração dinâmica de Schema via introspecção**, **Resolução de Conflitos com Server Authority (Remote-Wins)**, **cache automático de queries**, **outbox pattern para mutations offline** e **monitoramento centralizado de conectividade de rede**.

Compatível com **Android, iOS, Windows, macOS, Linux e Web**.

---

## ✨ Características Principais

- 🔌 **Compatibilidade Direta com `hasura_connect`**: Migre sem refatorar suas camadas de repositories/services. O typedef `HasuraConnect` aponta diretamente para `HasuraOfflineFirst`.
- 💾 **Local-First Database Replica (SQLite)**: Operações de leitura e escrita com latência zero (0ms), operando 100% offline através de uma réplica SQLite local com sincronização bidirecional em segundo plano.
- 📐 **Sincronização Dinâmica de Schema (Auto-Migration)**: Introspecção GraphQL contínua (`__type`) que detecta colunas adicionadas no Hasura/PostgreSQL e aplica migrações não-destrutivas (`ALTER TABLE ADD COLUMN`) automaticamente no SQLite local.
- 👑 **Resolução de Conflitos Server Authority (Remote-Wins)**: O banco Hasura/Postgres é a autoridade suprema. Se um registro for alterado localmente offline, mas já tiver sido excluído no servidor por outro usuário (`affected_rows: 0`), o registro local é expurgado e a UI notificada reativamente via stream `onConflictPurge`.
- 🪟 **Suporte Completo ao Windows Desktop**: Utiliza `sqflite_common_ffi` e `sqlite3_flutter_libs` para incluir os binários nativos do SQLite (`sqlite3.dll`) automaticamente no Windows, sem necessidade de configuração manual.
- 📡 **Monitoramento Centralizado de Rede**: Encapsula `connectivity_plus: ^7.3.2` e expõe streams e listeners reativos (`onConnectivityChanged`, `isConnected`, `addConnectivityListener`).
- ⚡ **Cache Transparente de Queries**: Consultas GraphQL tradicionais online atualizam o cache local indexado por hash SHA-256 normalizado de `(document + variables)`.
- 📦 **Outbox Pattern de Mutations**: Mutations tradicionais executadas offline são enfileiradas de forma persistente (UUID) e sincronizadas automaticamente em ordem FIFO ao restabelecer a conexão.
- 🔄 **Subscriptions GraphQL**: Suporte a subscriptions reativas sobre WebSocket (`graphql-ws` protocol) retornando objetos `Snapshot`.
- 🛡️ **Cadeia de Interceptors**: Suporte completo a interceptors (`TokenInterceptor`, `LogInterceptor`, tratamento customizado de erros).

---

## 🚀 Instalação

Adicione ao seu `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  hasura_offline_first: ^1.0.0
```

---

## 🛠️ Como Usar

### 1. Inicialização do Cliente com Local-First

```dart
import 'package:hasura_offline_first/hasura_offline_first.dart';

final client = HasuraOfflineFirst(
  'https://sua-instancia-hasura.app/v1/graphql',
  headers: {
    'x-hasura-admin-secret': 'meu-segredo',
  },
  tables: {'minha_tabela'}, // Registra tabelas para réplica local SQLite
  token: () async => 'Bearer meu_jwt_token',
  interceptors: [
    LogInterceptor(),
  ],
);
```

### 2. Operações Local-First (Latência Zero & Offline Total)

```dart
// 1. Inserir localmente (salva no SQLite e agenda push em background)
final item = await client.insertLocal('minha_tabela', {
  'id': 'uuid-123',
  'task': 'Comprar café',
  'check': false,
});

// 2. Consultar localmente com 0ms de latência
final itens = await client.queryLocal(
  'minha_tabela',
  where: 'check = ?',
  whereArgs: [0],
  orderBy: 'task ASC',
);

// 3. Atualizar localmente
await client.updateLocal('minha_tabela', 'uuid-123', {'check': true});

// 4. Deletar localmente (tombstone com sync em background)
await client.deleteLocal('minha_tabela', 'uuid-123');
```

### 3. Reagindo a Conflitos e Server Authority (Remote-Wins)

```dart
// Escuta quando um registro for expurgado localmente porque outro usuário o deletou na nuvem
client.onConflictPurge.listen((event) {
  print('Item ${event.id} da tabela ${event.tableName} foi removido pois não existe mais no servidor!');
});
```

### 4. Monitoramento de Conexão na UI (Snackbars / Banners)

```dart
// Opção A: Callback direto com função de cancelamento (disposer)
final cancelListener = client.addConnectivityListener((status) {
  if (status == NetworkStatus.offline) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Você está sem internet. Operações estão sendo salvas localmente.'),
        backgroundColor: Colors.red,
      ),
    );
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Conexão restabelecida! Sincronizando dados com o Hasura...'),
        backgroundColor: Colors.green,
      ),
    );
  }
});

// Para desinscrever no dispose do StatefulWidget:
cancelListener();

// Opção B: Stream reativo em StreamBuilder
StreamBuilder<NetworkStatus>(
  stream: client.onConnectivityChanged,
  builder: (context, snapshot) {
    final status = snapshot.data ?? NetworkStatus.online;
    return Text('Status: ${status.name}');
  },
);

// Opção C: Checagem pontual assíncrona
final isOnline = await client.isConnected;
```

### 5. Executando Queries com Cache Transparente

```dart
const queryDoc = '''
  query GetUsers {
    users {
      id
      name
      email
    }
  }
''';

try {
  // Com internet: busca no Hasura e atualiza cache local
  // Sem internet: recupera automaticamente do cache
  final data = await client.query(queryDoc);
  print('Usuários: $data');
} on HasuraCacheMissException catch (e) {
  print('Sem internet e sem dados no cache: ${e.message}');
}
```

### 6. Executando Mutations com Outbox Offline

```dart
const mutationDoc = '''
  mutation CreateUser(\$name: String!, \$email: String!) {
    insert_users_one(object: {name: \$name, email: \$email}) {
      id
      name
    }
  }
''';

final result = await client.mutation(
  mutationDoc,
  variables: {'name': 'Fulano', 'email': 'fulano@example.com'},
);

if (result is Map && result['_offline'] == true) {
  print('Operação salva offline na fila Outbox!');
}
```

### 7. Arquitetura Híbrida: Single-Tenant vs Multi-Tenant

O package oferece flexibilidade total para operar tanto em **bases globais únicas** quanto em **arquiteturas multi-empresa (Multi-Tenant)** com isolamento estrito de segurança e conformidade LGPD/GDPR:

#### A. Modo Single-Tenant (Padrão)
Sem nenhuma configuração adicional, todas as tabelas usam o banco SQLite padrão (`hasura_local_replica.db`) e sincronizam de forma aberta:
```dart
final client = HasuraOfflineFirst('https://meu-app.hasura.app/v1/graphql');
```

#### B. Modo Multi-Tenant (Isolamento por Empresa / Workspace)
Ao informar `tenantConfig`:
1. Cada organização ganha um arquivo SQLite dedicado (`hasura_tenant_<tenantId>.db`), impedindo contaminação de dados.
2. O `SyncEngine` injeta automaticamente a restrição `where: { tenant_id: { _eq: $tenantId } }` em todas as sincronizações de `Pull`.
3. Inserções locais offline recebem o `tenant_id` automaticamente.

```dart
final client = HasuraOfflineFirst(
  'https://meu-saas.hasura.app/v1/graphql',
  tenantConfig: const TenantConfig(
    tenantId: 'empresa_alfa',
    tenantColumn: 'empresa_id', // opcional, padrão 'tenant_id'
  ),
);

// Alternar entre empresas/tenants de forma limpa e segura:
await client.switchTenant(const TenantConfig(tenantId: 'empresa_beta'));

// Expurgo físico de dados locais (útil em logout de usuários sensíveis):
await client.clearTenantData('empresa_alfa');
```

### 8. Simulação de Modo Offline (Para Testes e Demonstrações)

```dart
// Força o cliente a se comportar como offline instantaneamente:
client.simulateOffline(true);

// Volta ao comportamento de rede real e dispara o sync automático:
client.simulateOffline(false);

final isSimulating = client.isSimulatingOffline;
```

### 8. Subscriptions GraphQL em Tempo Real

```dart
const subDoc = '''
  subscription OnUserAdded {
    users(order_by: {created_at: desc}, limit: 1) {
      id
      name
    }
  }
''';

final snapshot = await client.subscription(subDoc);

snapshot.stream.listen((data) {
  print('Novo dado recebido: $data');
});

// Fechar subscription quando necessário:
snapshot.close();
```

---

## 🏗️ Arquitetura Interna

```
lib/
├── hasura_offline_first.dart            # Exportações públicas da biblioteca
└── src/
    ├── contracts/                      # Interfaces desacopladas (IHasuraConnect, Snapshot, ILocalStorageDriver, NetworkStatus)
    ├── core/                           # NetworkManager, HashGenerator SHA-256, Exceções customizadas
    ├── local_database/                 # DatabaseProvider (SQLite móvel/desktop/FFI), LocalTableRepository, SchemaMigrator
    ├── sync/                           # SyncEngine (Push/Pull Delta), ConflictResolver (Server Authority), SyncManager
    ├── storage/                        # Drivers de persistência de documentos (InMemoryStorageDriver, FileStorageDriver)
    ├── network/                        # Clientes HasuraHttpClient e HasuraWebSocketClient
    ├── interceptors/                   # TokenInterceptor, LogInterceptor
    └── client/                         # HasuraOfflineFirst e typedef HasuraConnect
```

---

## 🧪 Testes

Execute a suíte de testes com:

```bash
flutter test
```


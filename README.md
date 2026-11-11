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

O package suporta nativamente tanto **aplicações de base única (Single-Tenant)** quanto **aplicações multi-empresa ou multi-usuário (Multi-Tenant)**.

Em aplicações SaaS B2B ou sistemas com múltiplos clientes compartilhando a mesma infraestrutura Hasura, **é crítico não misturar os dados locais** no mesmo banco de dados por questões de segurança da informação, privacidade e conformidade com **LGPD/GDPR**.

---

#### 🅰️ Modo Single-Tenant (Padrão)

Ideal para apps pessoais, ferramentas internas com uma única base corporativa ou quando todo o catálogo do Hasura é compartilhado:

- **Banco SQLite**: Usa o arquivo padrão `hasura_local_replica.db`.
- **Sincronização**: O `Pull` de dados é aberto e consome toda a tabela liberada pelas permissões do Hasura.
- **Configuração**: Nenhuma configuração extra necessária.

```dart
final client = HasuraOfflineFirst(
  'https://meu-app.hasura.app/v1/graphql',
  headers: {'x-hasura-admin-secret': 'segredo'},
  tables: {'produtos', 'tarefas'},
);
```

---

#### 🅱️ Modo Multi-Tenant (Segurança e Isolamento por Tenant)

Ideal para SaaS, sistemas multi-empresa, franquias ou qualquer aplicação onde cada cliente deve acessar **apenas os seus próprios dados**:

##### 🛡️ Garantias de Segurança:
1. **Isolamento Físico de Disco**: Cada tenant possui seu próprio arquivo SQLite independente (`hasura_tenant_<tenantId>.db`). O Tenant A nunca tem dados do Tenant B gravados em seu dispositivo.
2. **Pull Escopado no Hasura**: O motor de sincronização nunca executa queries abertas; ele injeta automaticamente o filtro `where: { <coluna_tenant>: { _eq: $tenantId } }`.
3. **Auto-Injeção de Tenant**: Ao criar registros locais offline, a coluna do tenant é preenchida automaticamente antes da persistência e do log de sincronização.
4. **Troca e Expurgo Seguros**: Permite alternar de organização ou apagar fisicamente o banco do tenant no logout.

---

##### 🔑 Como o Hasura gerencia Multi-Tenancy com JWT (Hasura Session Variables)

No Hasura, a segurança e o particionamento de dados multi-tenant baseiam-se em **Claims JWT** no namespace oficial `https://hasura.io/jwt/claims`.

Exemplo de payload do token JWT gerado pelo seu backend de autenticação:
```json
{
  "sub": "user_123",
  "name": "Maria Silva",
  "https://hasura.io/jwt/claims": {
    "x-hasura-default-role": "user",
    "x-hasura-allowed-roles": ["user"],
    "x-hasura-user-id": "user_123",
    "x-hasura-tenant-id": "empresa_alfa"
  }
}
```

No **Hasura Console (Data -> Tabela -> Permissions)**, a regra de permissão de Select / Insert / Update / Delete é configurada como:
```json
{
  "tenant_id": {
    "_eq": "X-Hasura-Tenant-Id"
  }
}
```

###### 🔄 Por que o app cliente precisa do `TenantConfig` no modo Local-First?
- **Online (Hasura)**: O servidor Hasura valida o JWT e restringe os dados automaticamente.
- **Offline (Dispositivo)**: Quando o celular ou desktop está **sem internet**, o Hasura não está presente. O `hasura_offline_first` utiliza o `TenantConfig` para:
  1. Abrir a base SQLite exclusiva da empresa (`hasura_tenant_empresa_alfa.db`).
  2. Preencher automaticamente `"tenant_id": "empresa_alfa"` nos novos registros criados offline.
  3. Ao restabelecer a conexão, o Hasura valida que o `tenant_id` da mutação coincide com o `X-Hasura-Tenant-Id` do JWT, aprovando a sincronização com **zero erros de permissão**.

---

##### ⚡ Extração Automática do Tenant direto do JWT (`TenantConfig.fromJwt`)

Em vez de fazer parsing manual do token no seu app, você pode utilizar o construtor `TenantConfig.fromJwt`:

```dart
// 1. Seu app obtém o token JWT após o login
final String jwtToken = await authService.getAccessToken();

// 2. Extrai automaticamente o claim 'x-hasura-tenant-id' do token
final tenantConfig = TenantConfig.fromJwt(
  jwtToken,
  claimName: 'x-hasura-tenant-id', // customizável se usar outro nome
  tenantColumn: 'tenant_id',       // nome da coluna na tabela Hasura
);

// 3. Inicializa o cliente com isolamento automático
final client = HasuraOfflineFirst(
  'https://meu-saas.hasura.app/v1/graphql',
  token: () => 'Bearer $jwtToken',
  tenantConfig: tenantConfig,
  tables: {'pedidos', 'produtos'},
);
```

---

##### 📋 Parâmetros da `TenantConfig`:
| Parâmetro | Tipo | Padrão | Descrição |
|---|---|---|---|
| `tenantId` | `String` | *(Obrigatório)* | Identificador único do tenant, organização, filial ou workspace. |
| `tenantColumn` | `String` | `'tenant_id'` | Nome da coluna correspondente ao tenant nas tabelas do Hasura. |
| `autoInjectTenantOnInsert` | `bool` | `true` | Se `true`, injeta automaticamente `tenantColumn: tenantId` nos inserts caso omitido. |

##### 💻 Exemplo Prático de Uso Multi-Tenant:

```dart
import 'package:hasura_offline_first/hasura_offline_first.dart';

// 1. Inicializando o cliente para a empresa 'empresa_alfa'
final client = HasuraOfflineFirst(
  'https://meu-saas.hasura.app/v1/graphql',
  headers: {
    'x-hasura-admin-secret': 'segredo',
  },
  tenantConfig: const TenantConfig(
    tenantId: 'empresa_alfa',
    tenantColumn: 'empresa_id', // customizável (padrão é 'tenant_id')
    autoInjectTenantOnInsert: true,
  ),
  tables: {'pedidos', 'clientes'},
);

// 2. Inserindo dados offline:
// O campo 'empresa_id': 'empresa_alfa' será injetado automaticamente!
final novoPedido = await client.insertLocal('pedidos', {
  'valor': 250.0,
  'descricao': 'Licença Anual',
});

// 3. Consultando dados locais:
// Apenas registros pertencentes à 'empresa_alfa' são retornados
final pedidosAlfa = await client.queryLocal('pedidos');

// 4. Alternando de empresa/tenant em tempo de execução (Account Switching):
// Fecha com segurança a conexão da empresa anterior e abre a nova base SQLite
await client.switchTenant(
  const TenantConfig(
    tenantId: 'empresa_beta',
    tenantColumn: 'empresa_id',
  ),
);

// Agora a base ativa é 'hasura_tenant_empresa_beta.db'
final pedidosBeta = await client.queryLocal('pedidos');

// 5. Logout Seguro (Expurgo Físico do Banco de Dados):
// Remove fisicamente o arquivo SQLite correspondente do disco
await client.clearTenantData('empresa_alfa');
```

---

### 8. Simulação de Modo Offline (Para Testes e Demonstrações)

```dart
// Força o cliente a se comportar como offline instantaneamente:
client.simulateOffline(true);

// Volta ao comportamento de rede real e dispara o sync automático:
client.simulateOffline(false);

final isSimulating = client.isSimulatingOffline;
```

### 9. Subscriptions GraphQL em Tempo Real

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


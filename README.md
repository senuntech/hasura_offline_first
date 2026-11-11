# Hasura Offline First

Um cliente GraphQL autônomo, reativo e offline-first para Dart e Flutter, projetado com contratos públicos compatíveis com o `hasura_connect: ^5.0.0+3`, agregando suporte nativo a **cache automático de queries**, **outbox pattern para mutations offline** e **monitoramento centralizado de conectividade de rede**.

---

## ✨ Características Principais

- 🔌 **Compatibilidade Direta com `hasura_connect`**: Migre sem refatorar suas camadas de repositories/services. O typedef `HasuraConnect` aponta diretamente para `HasuraOfflineFirst`.
- 📡 **Monitoramento Centralizado de Rede**: Encapsula `connectivity_plus: ^7.3.2` e expõe streams e listeners reativos (`onConnectivityChanged`, `isConnected`, `addConnectivityListener`).
- ⚡ **Cache Automático de Queries**: Consultas online atualizam o cache local indexado por hash SHA-256 normalizado de `(document + variables)`. Em caso de ausência de rede, os dados são entregues instantaneamente do cache.
- 📦 **Outbox Pattern de Mutations**: Mutations executadas offline são enfileiradas de forma persistente com identificadores únicos (UUID) e timestamp, e sincronizadas automaticamente em ordem FIFO assim que a conexão retornar.
- 🗄️ **Armazenamento Desacoplado (`ILocalStorageDriver`)**: Acompanha drivers prontos para uso em memória (`InMemoryStorageDriver`) e em disco (`FileStorageDriver`), permitindo plugar facilmente implementações customizadas como SQLite ou Hive.
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

### 1. Inicialização do Cliente

```dart
import 'package:hasura_offline_first/hasura_offline_first.dart';

final client = HasuraOfflineFirst(
  'https://sua-instancia-hasura.app/v1/graphql',
  headers: {
    'x-hasura-admin-secret': 'meu-segredo',
  },
  token: () async => 'Bearer meu_jwt_token',
  interceptors: [
    LogInterceptor(),
  ],
);
```

### 2. Monitoramento de Conexão na UI (Snackbars / Banners)

```dart
// Opção A: Callback direto com função de cancelamento (disposer)
final cancelListener = client.addConnectivityListener((status) {
  if (status == NetworkStatus.offline) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Você está sem internet. Operações serão salvas localmente.'),
        backgroundColor: Colors.red,
      ),
    );
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Conexão restabelecida! Sincronizando dados...'),
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

### 3. Executando Queries com Cache Transparente

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

### 4. Executando Mutations com Outbox Offline

```dart
const mutationDoc = '''
  mutation CreateUser(\$name: String!, \$email: String!) {
    insert_users_one(object: {name: \$name, email: \$email}) {
      id
      name
    }
  }
''';

// Com internet: executa imediatamente
// Sem internet: enfileira no Outbox e sincroniza assim que a internet voltar
final result = await client.mutation(
  mutationDoc,
  variables: {'name': 'Fulano', 'email': 'fulano@example.com'},
);

if (result is Map && result['_offline'] == true) {
  print('Operação salva offline para envio posterior!');
}
```

### 5. Simulação de Modo Offline (Para Testes e Demonstrações)

```dart
// Força o cliente a se comportar como offline instantaneamente:
client.simulateOffline(true);

// Volta ao comportamento de rede real e dispara o sync automático:
client.simulateOffline(false);

final isSimulating = client.isSimulatingOffline;
```

### 6. Subscriptions GraphQL em Tempo Real

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
├── hasura_offline_first.dart            # Exportações principais
└── src/
    ├── contracts/                      # Interfaces desacopladas (IHasuraConnect, Snapshot, ILocalStorageDriver, NetworkStatus)
    ├── core/                           # NetworkManager, HashGenerator SHA-256, Exceções
    ├── storage/                        # Drivers de persistência (InMemoryStorageDriver, FileStorageDriver)
    ├── network/                        # Clientes HasuraHttpClient e HasuraWebSocketClient
    ├── sync/                           # SyncManager com drenagem automática em FIFO
    ├── interceptors/                   # TokenInterceptor, LogInterceptor
    └── client/                         # HasuraOfflineFirst e typedef HasuraConnect
```

---

## 🧪 Testes

Execute a suíte de testes com:

```bash
flutter test
```


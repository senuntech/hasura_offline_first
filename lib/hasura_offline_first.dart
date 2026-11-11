/// A lightweight, offline-first GraphQL client compatible with HasuraConnect,
/// powered by an embedded SQLite database replica, dynamic schema auto-migrations,
/// and Server Authority conflict resolution.
library hasura_offline_first;

// Contracts
export 'src/contracts/hasura_connect_interface.dart';
export 'src/contracts/network_status.dart';
export 'src/contracts/storage_interface.dart';
export 'src/contracts/tenant_config.dart';

// Core
export 'src/core/exceptions.dart';
export 'src/core/hash_generator.dart';
export 'src/core/network_manager.dart';

// Interceptors
export 'src/interceptors/log_interceptor.dart';
export 'src/interceptors/token_interceptor.dart';

// Network
export 'src/network/hasura_http_client.dart';
export 'src/network/hasura_ws_client.dart';

// Storage
export 'src/storage/file_storage_driver.dart';
export 'src/storage/in_memory_storage_driver.dart';

// Local Database (Local-First Engine)
export 'src/local_database/database_provider.dart';
export 'src/local_database/local_table_repository.dart';
export 'src/local_database/schema_migrator.dart';

// Sync & Conflict Resolution (Server Authority)
export 'src/sync/conflict_resolver.dart';
export 'src/sync/sync_engine.dart';
export 'src/sync/sync_manager.dart';

// Client & Alias
export 'src/client/hasura_offline_first_client.dart';

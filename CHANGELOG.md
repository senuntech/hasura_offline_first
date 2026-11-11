## 1.1.0

- **Hybrid Multi-Tenant & Single-Tenant Architecture**: Physical SQLite database isolation per tenant (`hasura_tenant_<tenantId>.db`), auto-detection of tenant from JWT claims (`x-hasura-tenant-id`) with zero boilerplate, auto-injection on local mutations, scoped server pull synchronization, runtime tenant switching (`switchTenant`), and secure physical data purging (`clearTenantData`).
- **GraphQL `where` Parser for SQLite**: Queries targeting registered tables now automatically translate Hasura `where` filter clauses (`_eq`, `_neq`, `_gt`, `_gte`, `_lt`, `_lte`, `_like`, `_ilike`, `_is_null`), as well as `order_by`, `limit`, and `offset`, into local SQLite parameters with 0ms latency.
- **Reactive Sync Metrics Stream (`syncStatusStream`)**: Real-time emission of `SyncStatusSnapshot` containing exact pending mutation count (`pendingCount`), sync state (`idle`, `syncing`, `synced`, `error`), and `lastSyncedAt` timestamp for reactive UI badges.
- **Delimited ANSI Console Logs**: Box-drawing Unicode borders with semantic ANSI color formatting (Blue for requests, Green for responses, Red for errors) and pretty-printed JSON in `LogInterceptor`.
- **Fast Sequential Updates Optimization**: Coalescence of pending mutations in `_sync_log` and protection of unpushed local state against stale server responses during pull delta cycles.

## 1.0.0

- Initial stable release.
- **Local-First Architecture**: Embedded SQLite database replica with 0ms latency for registered tables (`queryLocal`, `insertLocal`, `updateLocal`, `deleteLocal`).
- **Dynamic Schema Auto-Migration**: GraphQL introspection (`__type`) detecting remote changes and applying non-destructive `ALTER TABLE ADD COLUMN` automatically.
- **Server Authority Conflict Resolution**: Remote-wins conflict policy purging deleted records locally on `affected_rows == 0` with reactive `onConflictPurge` stream.
- **Cross-Platform Support**: Native support for Android, iOS, Windows desktop, macOS, Linux, and Web (with bundled `sqlite3_flutter_libs` and `sqflite_common_ffi`).
- HasuraConnect compatible public interface (`query`, `mutation`, `subscription`).
- Offline-first caching with deterministic SHA-256 query hashing.
- Outbox pattern for queuing offline mutations with automatic FIFO background synchronization.
- Automatic local cache reconciliation for offline mutations (`insert`, `update`, `delete`).
- Centralized network monitoring using `connectivity_plus: ^7.3.2`.
- Reactive `onConnectivityChanged` stream, `isConnected` check, and listener callbacks with unsubscribe support.
- Simulated offline mode via `simulateOffline(bool)` for automated tests and UI demos.
- Decoupled `ILocalStorageDriver` interface with `InMemoryStorageDriver` and persistent `FileStorageDriver`.


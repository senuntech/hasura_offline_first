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


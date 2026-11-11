## 1.0.0

- Initial stable release.
- HasuraConnect compatible public interface (`query`, `mutation`, `subscription`).
- Offline-first caching with deterministic SHA-256 query hashing.
- Outbox pattern for queuing offline mutations with automatic FIFO background synchronization.
- Automatic local cache reconciliation for offline mutations (`insert`, `update`, `delete`).
- Centralized network monitoring using `connectivity_plus: ^7.3.2`.
- Reactive `onConnectivityChanged` stream, `isConnected` check, and listener callbacks with unsubscribe support.
- Simulated offline mode via `simulateOffline(bool)` for automated tests and UI demos.
- Decoupled `ILocalStorageDriver` interface with `InMemoryStorageDriver` and persistent `FileStorageDriver`.


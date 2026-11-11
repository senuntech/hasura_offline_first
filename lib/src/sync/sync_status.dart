/// State of the background synchronization engine.
enum SyncState {
  /// The sync engine is idle, waiting for changes or network restoration.
  idle,

  /// Full synchronization (Push / Pull) is currently in progress.
  syncing,

  /// All pending mutations have been successfully pushed to the server.
  synced,

  /// An error occurred during the last synchronization attempt.
  error,
}

/// Immutable snapshot representing the current synchronization metrics and state.
class SyncStatusSnapshot {
  /// Current state of synchronization.
  final SyncState state;

  /// Number of pending mutations waiting in the `_sync_log` outbox.
  final int pendingCount;

  /// Timestamp of the last successful synchronization attempt.
  final DateTime? lastSyncedAt;

  /// The error that occurred during the last sync attempt, if any.
  final Object? lastError;

  const SyncStatusSnapshot({
    required this.state,
    required this.pendingCount,
    this.lastSyncedAt,
    this.lastError,
  });

  /// Whether there are pending mutations waiting for network synchronization.
  bool get hasPendingMutations => pendingCount > 0;

  /// Whether the engine is currently performing synchronization.
  bool get isSyncing => state == SyncState.syncing;

  SyncStatusSnapshot copyWith({
    SyncState? state,
    int? pendingCount,
    DateTime? lastSyncedAt,
    Object? lastError,
  }) {
    return SyncStatusSnapshot(
      state: state ?? this.state,
      pendingCount: pendingCount ?? this.pendingCount,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      lastError: lastError ?? this.lastError,
    );
  }

  @override
  String toString() =>
      'SyncStatusSnapshot(state: $state, pendingCount: $pendingCount, lastSyncedAt: $lastSyncedAt, error: $lastError)';
}


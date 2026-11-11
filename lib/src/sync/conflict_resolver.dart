import 'dart:async';
import 'dart:developer' as dev;
import 'package:sqflite/sqflite.dart' as sqflite;

/// Event emitted when a local record is purged due to server authority (e.g. deleted remotely by another user).
class ConflictPurgeEvent {
  final String tableName;
  final String id;
  final String reason;

  ConflictPurgeEvent({
    required this.tableName,
    required this.id,
    required this.reason,
  });
}

/// Implements the "Server Authority / Remote-Wins" conflict resolution policy.
/// The online PostgreSQL / Hasura database is always the ultimate source of truth.
class ConflictResolver {
  final StreamController<ConflictPurgeEvent> _conflictController =
      StreamController<ConflictPurgeEvent>.broadcast();

  Stream<ConflictPurgeEvent> get onConflictPurge => _conflictController.stream;

  /// Called when a local UPDATE/DELETE mutation returns 0 affected rows from Hasura,
  /// meaning another user has already deleted the record on the server.
  Future<void> handleRemoteNotFound(
    sqflite.Database db, {
    required String tableName,
    required String rowId,
    required String logId,
  }) async {
    dev.log(
      'Server Authority Conflict: Record "$rowId" in table "$tableName" was deleted by another user on the server. Purging locally...',
      name: 'ConflictResolver',
    );

    // 1. Remove the pending mutation from the sync log
    await db.delete(
      '_sync_log',
      where: 'id = ?',
      whereArgs: [logId],
    );

    // 2. Remove the record from the local SQLite table so local state aligns with remote truth
    await db.delete(
      tableName,
      where: 'id = ?',
      whereArgs: [rowId],
    );

    // 3. Notify listeners / UI that this item was purged by remote authority
    if (!_conflictController.isClosed) {
      _conflictController.add(
        ConflictPurgeEvent(
          tableName: tableName,
          id: rowId,
          reason: 'Deleted remotely on server by another user.',
        ),
      );
    }
  }

  /// Resolves conflicts during Pull Sync by prioritizing server data over local values.
  Map<String, dynamic> resolveServerWin({
    required Map<String, dynamic> localData,
    required Map<String, dynamic> remoteData,
  }) {
    final merged = Map<String, dynamic>.from(localData);
    merged.addAll(remoteData);
    merged['__sync_status'] = 'synced';
    merged['__is_deleted'] = 0;
    merged['__updated_at'] = DateTime.now().toIso8601String();
    return merged;
  }

  void dispose() {
    _conflictController.close();
  }
}

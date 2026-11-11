import 'package:flutter/material.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';
import 'package:provider/provider.dart';

/// Interactive AppBar widget displaying the real-time synchronization state
/// and pending mutation count from [HasuraOfflineFirst.syncStatusStream].
class SyncStatusBadge extends StatelessWidget {
  const SyncStatusBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final client = context.watch<HasuraOfflineFirst>();

    return StreamBuilder<SyncStatusSnapshot>(
      stream: client.syncStatusStream,
      initialData: client.syncStatus,
      builder: (context, snapshot) {
        final status = snapshot.data ?? client.syncStatus;

        if (status.isSyncing) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Syncing (${status.pendingCount})...',
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ],
            ),
          );
        }

        if (status.hasPendingMutations) {
          return InkWell(
            onTap: () => client.synchronize(),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.amber.shade700,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_upload_outlined,
                      size: 16, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    '${status.pendingCount} offline',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return IconButton(
          icon: const Icon(Icons.cloud_done, color: Colors.white70),
          tooltip: status.lastSyncedAt != null
              ? 'Sincronizado às ${_formatTime(status.lastSyncedAt!)}'
              : 'Sincronizado',
          onPressed: () => client.synchronize(),
        );
      },
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}


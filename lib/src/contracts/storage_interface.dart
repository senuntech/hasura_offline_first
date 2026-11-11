import 'dart:convert';

/// Status of an item stored in the Outbox sync queue.
enum OutboxStatus {
  pending,
  processing,
  completed,
  failed,
}

/// Represents a cached GraphQL query payload.
class CacheEntry {
  final String key;
  final String queryHash;
  final Map<String, dynamic> data;
  final DateTime updatedAt;

  CacheEntry({
    required this.key,
    required this.queryHash,
    required this.data,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'key': key,
        'queryHash': queryHash,
        'data': data,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory CacheEntry.fromMap(Map<String, dynamic> map) {
    return CacheEntry(
      key: map['key'] as String,
      queryHash: map['queryHash'] as String,
      data: Map<String, dynamic>.from(map['data'] as Map),
      updatedAt: DateTime.parse(map['updatedAt'] as String),
    );
  }
}

/// Represents an offline GraphQL mutation queued for background synchronization.
class OutboxItem {
  final String id;
  final String document;
  final Map<String, dynamic>? variables;
  final DateTime createdAt;
  final OutboxStatus status;
  final int retryCount;
  final String? lastError;

  OutboxItem({
    required this.id,
    required this.document,
    this.variables,
    DateTime? createdAt,
    this.status = OutboxStatus.pending,
    this.retryCount = 0,
    this.lastError,
  }) : createdAt = createdAt ?? DateTime.now();

  OutboxItem copyWith({
    String? id,
    String? document,
    Map<String, dynamic>? variables,
    DateTime? createdAt,
    OutboxStatus? status,
    int? retryCount,
    String? lastError,
  }) {
    return OutboxItem(
      id: id ?? this.id,
      document: document ?? this.document,
      variables: variables ?? this.variables,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      lastError: lastError ?? this.lastError,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'document': document,
        'variables': variables,
        'createdAt': createdAt.toIso8601String(),
        'status': status.name,
        'retryCount': retryCount,
        'lastError': lastError,
      };

  factory OutboxItem.fromMap(Map<String, dynamic> map) {
    return OutboxItem(
      id: map['id'] as String,
      document: map['document'] as String,
      variables: map['variables'] != null
          ? Map<String, dynamic>.from(map['variables'] as Map)
          : null,
      createdAt: DateTime.parse(map['createdAt'] as String),
      status: OutboxStatus.values.firstWhere(
        (e) => e.name == map['status'],
        orElse: () => OutboxStatus.pending,
      ),
      retryCount: (map['retryCount'] as num?)?.toInt() ?? 0,
      lastError: map['lastError'] as String?,
    );
  }

  String toJson() => jsonEncode(toMap());
  factory OutboxItem.fromJson(String source) =>
      OutboxItem.fromMap(jsonDecode(source) as Map<String, dynamic>);
}

/// Decoupled local storage driver interface for caching and outbox queues.
abstract class ILocalStorageDriver {
  Future<void> init();

  Future<void> saveCache(String key, Map<String, dynamic> data);
  Future<Map<String, dynamic>?> getCache(String key);
  Future<List<String>> getAllCacheKeys();
  Future<void> removeCache(String key);
  Future<void> clearCache();

  Future<void> enqueueOutbox(OutboxItem item);
  Future<List<OutboxItem>> getPendingOutbox();
  Future<void> updateOutbox(OutboxItem item);
  Future<void> removeOutbox(String id);
  Future<void> clearOutbox();

  Future<void> close();
}

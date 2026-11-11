import '../contracts/storage_interface.dart';

/// In-memory implementation of [ILocalStorageDriver], ideal for testing and volatile environments.
class InMemoryStorageDriver implements ILocalStorageDriver {
  final Map<String, CacheEntry> _cache = {};
  final List<OutboxItem> _outbox = [];

  @override
  Future<void> init() async {}

  @override
  Future<void> saveCache(String key, Map<String, dynamic> data) async {
    _cache[key] = CacheEntry(
      key: key,
      queryHash: key,
      data: data,
    );
  }

  @override
  Future<Map<String, dynamic>?> getCache(String key) async {
    final entry = _cache[key];
    return entry?.data;
  }

  @override
  Future<void> removeCache(String key) async {
    _cache.remove(key);
  }

  @override
  Future<void> clearCache() async {
    _cache.clear();
  }

  @override
  Future<void> enqueueOutbox(OutboxItem item) async {
    _outbox.removeWhere((i) => i.id == item.id);
    _outbox.add(item);
  }

  @override
  Future<List<OutboxItem>> getPendingOutbox() async {
    return _outbox
        .where((i) =>
            i.status == OutboxStatus.pending || i.status == OutboxStatus.failed)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<void> updateOutbox(OutboxItem item) async {
    final index = _outbox.indexWhere((i) => i.id == item.id);
    if (index != -1) {
      _outbox[index] = item;
    } else {
      _outbox.add(item);
    }
  }

  @override
  Future<void> removeOutbox(String id) async {
    _outbox.removeWhere((i) => i.id == id);
  }

  @override
  Future<void> clearOutbox() async {
    _outbox.clear();
  }

  @override
  Future<void> close() async {
    _cache.clear();
    _outbox.clear();
  }
}


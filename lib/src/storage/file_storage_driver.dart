import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../contracts/storage_interface.dart';

/// File-based JSON persistent implementation of [ILocalStorageDriver].
class FileStorageDriver implements ILocalStorageDriver {
  String? _resolvedPath;
  final String? customBasePath;
  final Map<String, CacheEntry> _cache = {};
  final List<OutboxItem> _outbox = [];
  bool _initialized = false;
  Future<void>? _initFuture;

  FileStorageDriver({String? basePath}) : customBasePath = basePath;

  /// Returns the resolved directory path where cache and outbox files are stored.
  String get basePath => _resolvedPath ?? customBasePath ?? '.hasura_storage';

  File get _cacheFile => File('$basePath/hasura_cache.json');
  File get _outboxFile => File('$basePath/hasura_outbox.json');

  @override
  Future<void> init() {
    if (_initialized) return Future.value();
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    if (_initialized) return;

    if (customBasePath != null) {
      _resolvedPath = customBasePath;
    } else {
      try {
        final docDir = await getApplicationDocumentsDirectory();
        _resolvedPath = '${docDir.path}/hasura_storage';
      } catch (_) {
        // Fallback for unit tests or headless environments where path_provider plugin is not registered
        _resolvedPath = '${Directory.systemTemp.path}/hasura_storage';
      }
    }

    try {
      final dir = Directory(basePath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (_) {
      // If path is on a read-only filesystem (OS error 30 on mobile), safely fallback to systemTemp
      _resolvedPath = '${Directory.systemTemp.path}/hasura_storage';
      final fallbackDir = Directory(basePath);
      if (!await fallbackDir.exists()) {
        await fallbackDir.create(recursive: true);
      }
    }

    await _loadCacheFromDisk();
    await _loadOutboxFromDisk();
    _initialized = true;
  }

  Future<void> _loadCacheFromDisk() async {
    try {
      if (await _cacheFile.exists()) {
        final content = await _cacheFile.readAsString();
        if (content.isNotEmpty) {
          final Map<String, dynamic> json = jsonDecode(content);
          _cache.clear();
          json.forEach((key, value) {
            _cache[key] = CacheEntry.fromMap(Map<String, dynamic>.from(value));
          });
        }
      }
    } catch (e) {
      dev.log('Erro ao ler cache do disco: $e', name: 'FileStorageDriver');
      _cache.clear();
    }
  }

  Future<void> _loadOutboxFromDisk() async {
    try {
      if (await _outboxFile.exists()) {
        final content = await _outboxFile.readAsString();
        if (content.isNotEmpty) {
          final List<dynamic> json = jsonDecode(content);
          _outbox.clear();
          for (final item in json) {
            _outbox.add(OutboxItem.fromMap(Map<String, dynamic>.from(item)));
          }
        }
      }
    } catch (e) {
      dev.log('Erro ao ler outbox do disco: $e', name: 'FileStorageDriver');
      _outbox.clear();
    }
  }

  Future<void> _persistCache() async {
    try {
      final dir = Directory(basePath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final map = _cache.map((key, value) => MapEntry(key, value.toMap()));
      await _cacheFile.writeAsString(jsonEncode(map), flush: true);
    } catch (e) {
      dev.log('Erro ao persistir cache no disco: $e', name: 'FileStorageDriver', error: e);
    }
  }

  Future<void> _persistOutbox() async {
    try {
      final dir = Directory(basePath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final list = _outbox.map((i) => i.toMap()).toList();
      await _outboxFile.writeAsString(jsonEncode(list), flush: true);
    } catch (e) {
      dev.log('Erro ao persistir outbox no disco: $e', name: 'FileStorageDriver', error: e);
    }
  }

  @override
  Future<void> saveCache(String key, Map<String, dynamic> data) async {
    await init();
    _cache[key] = CacheEntry(
      key: key,
      queryHash: key,
      data: data,
    );
    await _persistCache();
  }

  @override
  Future<Map<String, dynamic>?> getCache(String key) async {
    await init();
    final entry = _cache[key];
    return entry?.data;
  }

  @override
  Future<List<String>> getAllCacheKeys() async {
    await init();
    return _cache.keys.toList();
  }

  @override
  Future<void> removeCache(String key) async {
    await init();
    _cache.remove(key);
    await _persistCache();
  }

  @override
  Future<void> clearCache() async {
    await init();
    _cache.clear();
    await _persistCache();
  }

  @override
  Future<void> enqueueOutbox(OutboxItem item) async {
    await init();
    _outbox.removeWhere((i) => i.id == item.id);
    _outbox.add(item);
    await _persistOutbox();
  }

  @override
  Future<List<OutboxItem>> getPendingOutbox() async {
    await init();
    return _outbox
        .where((i) =>
            i.status == OutboxStatus.pending || i.status == OutboxStatus.failed)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  @override
  Future<void> updateOutbox(OutboxItem item) async {
    await init();
    final index = _outbox.indexWhere((i) => i.id == item.id);
    if (index != -1) {
      _outbox[index] = item;
    } else {
      _outbox.add(item);
    }
    await _persistOutbox();
  }

  @override
  Future<void> removeOutbox(String id) async {
    await init();
    _outbox.removeWhere((i) => i.id == id);
    await _persistOutbox();
  }

  @override
  Future<void> clearOutbox() async {
    await init();
    _outbox.clear();
    await _persistOutbox();
  }

  @override
  Future<void> close() async {
    await _persistCache();
    await _persistOutbox();
  }
}

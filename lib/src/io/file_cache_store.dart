import 'dart:convert';
import 'dart:io';

import '../cache.dart';

/// Keeps cached responses as files in a folder, so the last data is still
/// there when the app starts without a connection.
///
/// ```dart
/// final dir = await getApplicationCacheDirectory(); // path_provider
/// final store = FileCacheStore('${dir.path}/offline_fetch');
/// ```
class FileCacheStore implements CacheStore {
  /// Creates a cache in the folder at [directoryPath].
  FileCacheStore(String directoryPath) : _dir = Directory(directoryPath);

  final Directory _dir;

  @override
  Future<CacheEntry?> read(String key) async {
    final file = _fileFor(key);
    if (!await file.exists()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      // Two keys can share a file name; the stored key tells them apart.
      if (json['key'] != key) return null;
      return CacheEntry.fromJson(json['entry'] as Map<String, dynamic>);
    } on FormatException {
      await file.delete();
      return null;
    }
  }

  @override
  Future<void> write(String key, CacheEntry entry) async {
    await _dir.create(recursive: true);
    final file = _fileFor(key);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode({'key': key, 'entry': entry.toJson()}),
        flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<void> delete(String key) async {
    final file = _fileFor(key);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> clear() async {
    if (await _dir.exists()) await _dir.delete(recursive: true);
  }

  File _fileFor(String key) =>
      File('${_dir.path}${Platform.pathSeparator}${_hash(key)}.json');

  /// Two FNV-1a 32-bit hashes with different seeds, as 16 hex characters.
  static String _hash(String key) {
    final bytes = utf8.encode(key);
    String fnv(int seed) {
      var hash = seed;
      for (final b in bytes) {
        hash = ((hash ^ b) * 0x01000193) & 0xFFFFFFFF;
      }
      return hash.toRadixString(16).padLeft(8, '0');
    }

    return fnv(0x811c9dc5) + fnv(0x050c5d1f);
  }
}

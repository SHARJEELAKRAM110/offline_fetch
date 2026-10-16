import 'dart:convert';
import 'dart:typed_data';

/// How a `GET` request uses the response cache.
enum CachePolicy {
  /// Always use the network and never read or write the cache.
  networkOnly,

  /// Try the network first. If it is down (or the server answers 502, 503 or
  /// 504), return the last cached response, however old. Successful
  /// responses are saved to the cache. This is the default.
  networkFirst,

  /// Return a cached response if it is younger than the client's
  /// `cacheMaxAge`. Otherwise use the network, and fall back to an older
  /// cached response if the network is down.
  cacheFirst,

  /// Only read the cache. Throws a `FetchException` if nothing is cached.
  cacheOnly,
}

/// A stored response.
class CacheEntry {
  /// Creates a cache entry.
  CacheEntry({
    required this.statusCode,
    required this.headers,
    required List<int> bodyBytes,
    required this.storedAt,
  }) : bodyBytes =
            bodyBytes is Uint8List ? bodyBytes : Uint8List.fromList(bodyBytes);

  /// Restores an entry saved with [toJson].
  factory CacheEntry.fromJson(Map<String, dynamic> json) => CacheEntry(
        statusCode: json['statusCode'] as int,
        headers: (json['headers'] as Map).cast<String, String>(),
        bodyBytes: base64Decode(json['body'] as String),
        storedAt: DateTime.parse(json['storedAt'] as String),
      );

  /// The HTTP status code.
  final int statusCode;

  /// Response headers.
  final Map<String, String> headers;

  /// The raw response body.
  final Uint8List bodyBytes;

  /// When the response was stored.
  final DateTime storedAt;

  /// Converts the entry to JSON.
  Map<String, dynamic> toJson() => {
        'statusCode': statusCode,
        'headers': headers,
        'body': base64Encode(bodyBytes),
        'storedAt': storedAt.toUtc().toIso8601String(),
      };
}

/// Where cached responses are kept.
///
/// Implement this to store the cache somewhere else, such as Hive,
/// SharedPreferences or SQLite.
abstract interface class CacheStore {
  /// Returns the entry for [key], or `null` if there is none.
  Future<CacheEntry?> read(String key);

  /// Saves [entry] under [key], replacing any older entry.
  Future<void> write(String key, CacheEntry entry);

  /// Removes the entry for [key].
  Future<void> delete(String key);

  /// Removes every entry.
  Future<void> clear();
}

/// Keeps cached responses in memory. They are lost when the app closes.
///
/// When more than [maxEntries] are stored, the least recently used entry is
/// removed.
class MemoryCacheStore implements CacheStore {
  /// Creates an in-memory cache.
  MemoryCacheStore({this.maxEntries = 100});

  /// The most entries kept at once.
  final int maxEntries;

  final Map<String, CacheEntry> _entries = {};

  @override
  Future<CacheEntry?> read(String key) async {
    final entry = _entries.remove(key);
    if (entry != null) _entries[key] = entry;
    return entry;
  }

  @override
  Future<void> write(String key, CacheEntry entry) async {
    _entries.remove(key);
    _entries[key] = entry;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  @override
  Future<void> delete(String key) async => _entries.remove(key);

  @override
  Future<void> clear() async => _entries.clear();
}

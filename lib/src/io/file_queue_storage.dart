import 'dart:convert';
import 'dart:io';

import '../queue.dart';

/// Keeps the offline queue in a JSON file, so queued requests survive app
/// restarts.
///
/// In Flutter, put the file in the app's documents or support directory:
///
/// ```dart
/// final dir = await getApplicationSupportDirectory(); // path_provider
/// final storage = FileQueueStorage('${dir.path}/offline_queue.json');
/// ```
///
/// Use one instance per file. Writes go to a temporary file first and then
/// replace the real one, so a crash mid-write does not corrupt the queue.
class FileQueueStorage implements QueueStorage {
  /// Creates storage backed by the file at [path].
  FileQueueStorage(String path) : _file = File(path);

  final File _file;
  List<QueuedRequest>? _items;
  Future<void> _lock = Future.value();

  @override
  Future<List<QueuedRequest>> loadAll() =>
      _synchronized(() async => List.of(await _load()));

  @override
  Future<void> add(QueuedRequest item) => _synchronized(() async {
        (await _load()).add(item);
        await _save();
      });

  @override
  Future<void> update(QueuedRequest item) => _synchronized(() async {
        final items = await _load();
        final index = items.indexWhere((e) => e.id == item.id);
        if (index == -1) return;
        items[index] = item;
        await _save();
      });

  @override
  Future<void> remove(String id) => _synchronized(() async {
        (await _load()).removeWhere((e) => e.id == id);
        await _save();
      });

  @override
  Future<void> clear() => _synchronized(() async {
        _items = [];
        await _save();
      });

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<List<QueuedRequest>> _load() async {
    final cached = _items;
    if (cached != null) return cached;
    if (!await _file.exists()) return _items = [];
    final text = await _file.readAsString();
    if (text.trim().isEmpty) return _items = [];
    try {
      final list = jsonDecode(text) as List;
      return _items = [
        for (final e in list) QueuedRequest.fromJson(e as Map<String, dynamic>)
      ];
    } on FormatException {
      // Keep the damaged file for inspection and start with an empty queue.
      await _file.rename('${_file.path}.corrupt');
      return _items = [];
    }
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(jsonEncode(_items), flush: true);
    await temp.rename(_file.path);
  }
}

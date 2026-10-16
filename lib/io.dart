/// File-based storage for `offline_fetch`, so queued requests and cached
/// responses survive app restarts.
///
/// Uses `dart:io`, so it works on Android, iOS, macOS, Windows, Linux and
/// the Dart VM, but not on the web.
library;

export 'src/io/file_cache_store.dart';
export 'src/io/file_queue_storage.dart';

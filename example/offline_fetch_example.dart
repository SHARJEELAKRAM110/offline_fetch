import 'dart:io';

import 'package:offline_fetch/io.dart';
import 'package:offline_fetch/offline_fetch.dart';

/// Run with `dart run example/offline_fetch_example.dart`.
///
/// Try it once online, then turn off Wi-Fi and run it again: the GET comes
/// from the cache and the POST goes to the queue. Turn Wi-Fi back on and run
/// it a third time to see the queued POST being sent.
Future<void> main() async {
  final dir = '${Directory.systemTemp.path}/offline_fetch_example';

  final api = OfflineFetch(
    baseUrl: 'https://jsonplaceholder.typicode.com',
    headers: {'accept': 'application/json'},
    timeout: const Duration(seconds: 10),
    // Keep the queue and cache on disk so they survive restarts.
    queueStorage: FileQueueStorage('$dir/queue.json'),
    cacheStore: FileCacheStore('$dir/cache'),
    interceptors: [AuthInterceptor()],
  );

  api.queueEvents.listen((event) {
    switch (event) {
      case RequestQueued(:final item):
        print('Queued ${item.request.method} ${item.request.url}');
      case QueuedRequestSent(:final item, :final response):
        print('Sent queued ${item.id}: ${response.statusCode}');
      case QueuedRequestFailed(:final item, :final error):
        print('Will retry ${item.id} later: $error');
      case QueuedRequestDropped(:final item, :final reason):
        print('Dropped ${item.id}: $reason');
    }
  });

  // Requests left over from a previous run are sent first.
  final sent = await api.flushQueue();
  if (sent > 0) print('Sent $sent request(s) from the last run');

  try {
    final todo = await api.get('/todos/1');
    final from = todo.isFromCache ? 'cache (offline)' : 'network';
    print('GET /todos/1 from $from: ${todo.json()['title']}');
  } on FetchException catch (e) {
    print('Offline and nothing cached yet: ${e.message}');
  }

  final created = await api.post('/posts', body: {
    'title': 'Hello from offline_fetch',
    'userId': 1,
  });
  if (created.isQueued) {
    print('Offline: POST saved to the queue (${created.queuedRequestId})');
  } else {
    print('POST /posts: ${created.statusCode} ${created.body}');
  }

  print('Still waiting in queue: ${(await api.pendingRequests()).length}');
  await api.close();
}

/// Adds a token to every request, including queued ones when they are sent
/// later, so an expired token is never replayed.
class AuthInterceptor extends FetchInterceptor {
  @override
  FetchRequest onRequest(FetchRequest request) => request.copyWith(
        headers: {...request.headers, 'authorization': 'Bearer demo-token'},
      );
}

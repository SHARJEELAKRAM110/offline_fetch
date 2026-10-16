@TestOn('vm')
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_fetch/io.dart';
import 'package:offline_fetch/offline_fetch.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('offline_fetch_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('queued requests survive a restart', () async {
    final path = '${dir.path}/queue.json';

    final offline = OfflineFetch(
      baseUrl: 'https://api.test',
      httpClient:
          MockClient((r) async => throw http.ClientException('offline', r.url)),
      queueStorage: FileQueueStorage(path),
      retryPolicy: RetryPolicy.none,
      autoFlushInterval: null,
    );
    await offline.post('/orders', body: {'n': 1});
    await offline.post('/orders', body: {'n': 2});
    await offline.close();

    final received = <String>[];
    final online = OfflineFetch(
      baseUrl: 'https://api.test',
      httpClient: MockClient((r) async {
        received.add(r.body);
        return http.Response('', 201);
      }),
      queueStorage: FileQueueStorage(path),
      autoFlushInterval: null,
    );
    // The new client flushes leftovers on start; this joins that flush.
    await online.flushQueue();
    expect(received, ['{"n":1}', '{"n":2}']);
    expect(await online.pendingRequests(), isEmpty);
    expect(await FileQueueStorage(path).loadAll(), isEmpty);
    await online.close();
  });

  test('a damaged queue file is set aside', () async {
    final path = '${dir.path}/queue.json';
    await File(path).writeAsString('{not json');
    expect(await FileQueueStorage(path).loadAll(), isEmpty);
    expect(await File('$path.corrupt').exists(), isTrue);
  });

  test('FileCacheStore stores, reads and clears entries', () async {
    final store = FileCacheStore('${dir.path}/cache');
    final entry = CacheEntry(
      statusCode: 200,
      headers: {'content-type': 'text/plain'},
      bodyBytes: [104, 105],
      storedAt: DateTime.utc(2026, 1, 1),
    );
    await store.write('GET https://api.test/a', entry);
    await store.write('GET https://api.test/a', entry); // replace existing

    final read = await FileCacheStore('${dir.path}/cache')
        .read('GET https://api.test/a');
    expect(read?.bodyBytes, [104, 105]);
    expect(read?.storedAt, DateTime.utc(2026, 1, 1));
    expect(await store.read('GET https://api.test/b'), isNull);

    await store.clear();
    expect(await store.read('GET https://api.test/a'), isNull);
  });
}

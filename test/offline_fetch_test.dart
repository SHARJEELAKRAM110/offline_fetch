import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_fetch/offline_fetch.dart';
import 'package:test/test.dart';

/// A fake server that can be switched offline.
class FakeServer {
  bool online = true;
  final List<http.Request> received = [];
  http.Response Function(http.Request request) handler =
      (_) => http.Response('{"ok":true}', 200);

  late final MockClient client = MockClient((request) async {
    if (!online) throw http.ClientException('No internet', request.url);
    received.add(request);
    return handler(request);
  });
}

void main() {
  late FakeServer server;
  late List<Duration> sleeps;

  OfflineFetch makeClient({
    RetryPolicy retryPolicy = const RetryPolicy(jitter: false),
    CachePolicy cachePolicy = CachePolicy.networkFirst,
    Duration cacheMaxAge = const Duration(minutes: 5),
    QueueStorage? queueStorage,
    int maxQueueAttempts = 10,
    List<FetchInterceptor> interceptors = const [],
    Duration timeout = const Duration(seconds: 5),
  }) {
    return OfflineFetch(
      baseUrl: 'https://api.test/v1/',
      httpClient: server.client,
      retryPolicy: retryPolicy,
      cachePolicy: cachePolicy,
      cacheMaxAge: cacheMaxAge,
      queueStorage: queueStorage,
      maxQueueAttempts: maxQueueAttempts,
      interceptors: interceptors,
      timeout: timeout,
      autoFlushInterval: null,
      sleep: (d) async => sleeps.add(d),
    );
  }

  setUp(() {
    server = FakeServer();
    sleeps = [];
  });

  group('requests', () {
    test('joins baseUrl, path and query', () async {
      final api = makeClient();
      await api.get('/items', query: {
        'page': 2,
        'tag': ['a', 'b']
      });
      expect(server.received.single.url.toString(),
          'https://api.test/v1/items?page=2&tag=a&tag=b');
    });

    test('encodes a map body as JSON', () async {
      final api = makeClient();
      await api.put('items/1', body: {'name': 'Tea'});
      final request = server.received.single;
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(jsonDecode(request.body), {'name': 'Tea'});
    });

    test('returns 4xx responses instead of throwing', () async {
      server.handler = (_) => http.Response('nope', 404);
      final api = makeClient();
      final response = await api.get('/missing');
      expect(response.statusCode, 404);
      expect(response.isSuccess, isFalse);
    });
  });

  group('retry', () {
    test('retries 503 with backoff, then succeeds', () async {
      var calls = 0;
      server.handler = (_) =>
          ++calls < 3 ? http.Response('busy', 503) : http.Response('done', 200);
      final api = makeClient(cachePolicy: CachePolicy.networkOnly);
      final response = await api.get('/slow');
      expect(response.body, 'done');
      expect(calls, 3);
      expect(sleeps, [
        const Duration(milliseconds: 300),
        const Duration(milliseconds: 600),
      ]);
    });

    test('honours Retry-After, capped at maxDelay', () async {
      var calls = 0;
      server.handler = (_) => ++calls == 1
          ? http.Response('slow down', 429, headers: {'retry-after': '60'})
          : http.Response('ok', 200);
      final api = makeClient();
      await api.get('/limited');
      expect(sleeps, [const Duration(seconds: 10)]);
    });

    test('does not retry a POST without an idempotency key', () async {
      server.handler = (_) => http.Response('error', 500);
      final api = makeClient();
      final response = await api.post('/pay', body: 'x', queueIfOffline: false);
      expect(response.statusCode, 500);
      expect(server.received, hasLength(1));
    });

    test('retries a queueable POST, which carries an idempotency key',
        () async {
      server.handler = (_) => http.Response('error', 500);
      final api = makeClient();
      await api.post('/orders', body: 'x');
      expect(server.received, hasLength(3));
      final keys =
          server.received.map((r) => r.headers['Idempotency-Key']).toSet();
      expect(keys, hasLength(1));
      expect(keys.single, isNotNull);
    });

    test('delay grows and stops at maxDelay', () {
      const policy = RetryPolicy(
        jitter: false,
        initialDelay: Duration(seconds: 1),
        maxDelay: Duration(seconds: 5),
      );
      expect(policy.delayFor(1), const Duration(seconds: 1));
      expect(policy.delayFor(2), const Duration(seconds: 2));
      expect(policy.delayFor(3), const Duration(seconds: 4));
      expect(policy.delayFor(4), const Duration(seconds: 5));
    });
  });

  group('cache', () {
    test('networkFirst serves the cached copy when offline', () async {
      server.handler = (_) => http.Response('fresh', 200);
      final api = makeClient(retryPolicy: RetryPolicy.none);
      final online = await api.get('/menu');
      expect(online.source, ResponseSource.network);

      server.online = false;
      final offline = await api.get('/menu');
      expect(offline.isFromCache, isTrue);
      expect(offline.body, 'fresh');
      expect(offline.cachedAt, isNotNull);
    });

    test('networkFirst serves the cached copy on 503', () async {
      final api = makeClient(retryPolicy: RetryPolicy.none);
      await api.get('/menu');
      server.handler = (_) => http.Response('down', 503);
      final response = await api.get('/menu');
      expect(response.isFromCache, isTrue);
    });

    test('throws when offline with nothing cached', () async {
      server.online = false;
      final api = makeClient(retryPolicy: RetryPolicy.none);
      expect(
        () => api.get('/menu'),
        throwsA(isA<FetchException>()
            .having((e) => e.isNetworkError, 'isNetworkError', isTrue)),
      );
    });

    test('cacheFirst skips the network while the entry is fresh', () async {
      final api = makeClient(cachePolicy: CachePolicy.cacheFirst);
      await api.get('/menu');
      await api.get('/menu');
      expect(server.received, hasLength(1));
    });

    test('cacheFirst goes to the network when the entry is old', () async {
      final api = makeClient(
          cachePolicy: CachePolicy.cacheFirst, cacheMaxAge: Duration.zero);
      await api.get('/menu');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await api.get('/menu');
      expect(server.received, hasLength(2));
    });

    test('does not cache error responses', () async {
      server.handler = (_) => http.Response('nope', 500);
      final api = makeClient(retryPolicy: RetryPolicy.none);
      await api.get('/menu');
      expect(() => api.get('/menu', cachePolicy: CachePolicy.cacheOnly),
          throwsA(isA<FetchException>()));
    });

    test('networkOnly never reads the cache', () async {
      final api = makeClient(retryPolicy: RetryPolicy.none);
      await api.get('/menu');
      server.online = false;
      expect(() => api.get('/menu', cachePolicy: CachePolicy.networkOnly),
          throwsA(isA<FetchException>()));
    });
  });

  group('offline queue', () {
    test('queues a POST when offline and sends it later', () async {
      server.online = false;
      final api = makeClient(retryPolicy: RetryPolicy.none);
      final events = <QueueEvent>[];
      api.queueEvents.listen(events.add);

      final response = await api.post('/orders', body: {'item': 1});
      expect(response.isQueued, isTrue);
      expect(response.isSuccess, isFalse);
      expect(response.statusCode, 202);
      expect(await api.pendingRequests(), hasLength(1));

      server.online = true;
      expect(await api.notifyOnline(), 1);
      expect(await api.pendingRequests(), isEmpty);

      final sent = server.received.single;
      expect(jsonDecode(sent.body), {'item': 1});
      expect(sent.headers['Idempotency-Key'], response.queuedRequestId);

      await Future<void>.delayed(Duration.zero);
      expect(
          events.map((e) => e.runtimeType), [RequestQueued, QueuedRequestSent]);
    });

    test('queues on 503 from the server', () async {
      server.handler = (_) => http.Response('down', 503);
      final api = makeClient(retryPolicy: RetryPolicy.none);
      final response = await api.delete('/orders/7');
      expect(response.isQueued, isTrue);
    });

    test('does not queue when queueIfOffline is false', () async {
      server.online = false;
      final api = makeClient(retryPolicy: RetryPolicy.none);
      expect(() => api.post('/login', body: 'x', queueIfOffline: false),
          throwsA(isA<FetchException>()));
      expect(await api.pendingRequests(), isEmpty);
    });

    test('sends in order and stops while still offline', () async {
      server.online = false;
      final api = makeClient(retryPolicy: RetryPolicy.none);
      await api.post('/a');
      await api.post('/b');
      await api.post('/c');

      expect(await api.flushQueue(), 0);
      expect(await api.pendingRequests(), hasLength(3));
      // Network failures are not counted as attempts.
      expect((await api.pendingRequests()).first.attempts, 0);

      server.online = true;
      await api.flushQueue();
      expect(
          server.received.map((r) => r.url.path), ['/v1/a', '/v1/b', '/v1/c']);
    });

    test('drops a request the server rejects and carries on', () async {
      server.online = false;
      final api = makeClient(retryPolicy: RetryPolicy.none);
      final events = <QueueEvent>[];
      api.queueEvents.listen(events.add);
      await api.post('/bad');
      await api.post('/good');

      server.online = true;
      server.handler = (r) => r.url.path.endsWith('bad')
          ? http.Response('invalid', 422)
          : http.Response('ok', 201);
      expect(await api.flushQueue(), 1);
      expect(await api.pendingRequests(), isEmpty);

      await Future<void>.delayed(Duration.zero);
      final dropped = events.whereType<QueuedRequestDropped>().single;
      expect(dropped.response?.statusCode, 422);
    });

    test('keeps a request after a server error, drops it after the limit',
        () async {
      server.online = false;
      final api =
          makeClient(retryPolicy: RetryPolicy.none, maxQueueAttempts: 2);
      await api.post('/orders');

      server.online = true;
      server.handler = (_) => http.Response('error', 500);
      await api.flushQueue();
      final pending = await api.pendingRequests();
      expect(pending.single.attempts, 1);

      await api.flushQueue();
      expect(await api.pendingRequests(), isEmpty);
    });

    test('runs interceptors again when a queued request is sent', () async {
      final auth = _TokenInterceptor('old');
      server.online = false;
      final api =
          makeClient(retryPolicy: RetryPolicy.none, interceptors: [auth]);
      await api.post('/orders');

      auth.token = 'new';
      server.online = true;
      await api.flushQueue();
      expect(server.received.single.headers['authorization'], 'Bearer new');
    });

    test('a successful request triggers a flush', () async {
      server.online = false;
      final api = makeClient(retryPolicy: RetryPolicy.none);
      await api.post('/orders');

      server.online = true;
      await api.get('/menu');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await api.pendingRequests(), isEmpty);
      expect(server.received.map((r) => r.method), ['GET', 'POST']);
    });

    test('treats a timeout as offline', () async {
      final slow = OfflineFetch(
        baseUrl: 'https://api.test',
        httpClient: MockClient((_) => Completer<http.Response>().future),
        timeout: const Duration(milliseconds: 20),
        retryPolicy: RetryPolicy.none,
        autoFlushInterval: null,
      );
      final response = await slow.post('/orders');
      expect(response.isQueued, isTrue);
    });
  });

  group('serialisation', () {
    test('FetchRequest survives a JSON round trip', () {
      final request = FetchRequest(
        method: 'post',
        url: Uri.parse('https://api.test/x?y=1'),
        headers: {'a': 'b'},
        bodyBytes: [0, 1, 2, 255],
        timeout: const Duration(seconds: 3),
      );
      final copy = FetchRequest.fromJson(
          jsonDecode(jsonEncode(request.toJson())) as Map<String, dynamic>);
      expect(copy.method, 'POST');
      expect(copy.url, request.url);
      expect(copy.headers, {'a': 'b'});
      expect(copy.bodyBytes, [0, 1, 2, 255]);
      expect(copy.timeout, const Duration(seconds: 3));
    });
  });

  test('cannot be used after close', () async {
    final api = makeClient();
    await api.close();
    expect(() => api.get('/menu'), throwsStateError);
  });
}

class _TokenInterceptor extends FetchInterceptor {
  _TokenInterceptor(this.token);

  String token;

  @override
  FetchRequest onRequest(FetchRequest request) => request.copyWith(
      headers: {...request.headers, 'authorization': 'Bearer $token'});
}

# offline_fetch

An offline-first HTTP client for Dart and Flutter.

Your app keeps working when the internet doesn't:

- **Retries** failed requests with exponential backoff and jitter, and respects `Retry-After`.
- **Caches `GET` responses**, and returns the last good copy when the network is down.
- **Queues `POST` / `PUT` / `PATCH` / `DELETE`** when offline, then sends them **in order** once the connection is back, even after an app restart.
- **Idempotency keys** on queued requests, so the server can ignore duplicates.
- **Interceptors** run again when a queued request is replayed, so auth tokens are always fresh.
- Works on Android, iOS, web, Windows, macOS, Linux and the Dart VM. Its only dependency is [`http`](https://pub.dev/packages/http).

```dart
final api = OfflineFetch(baseUrl: 'https://api.example.com');

final order = await api.post('/orders', body: {'item': 42, 'qty': 2});
if (order.isQueued) {
  showSnackBar('Saved offline. It will sync automatically.');
}
```

## Why not just http or dio?

`http` and `dio` are great at sending requests. When there is no connection they throw, and you have to build retry, caching and an outbox yourself. `offline_fetch` does those three things for you. It's made for apps used in shops, warehouses, deliveries and anywhere else the signal comes and goes.

## Install

```bash
dart pub add offline_fetch
```

## Usage

### Create a client

```dart
import 'package:offline_fetch/offline_fetch.dart';

final api = OfflineFetch(
  baseUrl: 'https://api.example.com/v1',
  headers: {'accept': 'application/json'},
  timeout: const Duration(seconds: 15),
);
```

### Read data (works offline)

```dart
final response = await api.get('/products', query: {'page': 1});

if (response.isFromCache) {
  showBanner('Offline. Showing data from ${response.cachedAt}');
}
final products = response.json() as List;
```

If the network is down and nothing has been cached yet, a `FetchException` is thrown.

### Send data (queued when offline)

```dart
final response = await api.post('/sales', body: {'total': 1500});

if (response.isQueued) {
  // Saved to the queue; response.queuedRequestId identifies it.
} else if (response.isSuccess) {
  // The server accepted it right away.
} else {
  // The server answered with an error, such as 400 or 500.
}
```

`body` can be a `Map` or `List` (sent as JSON), a `String`, or a `List<int>` of raw bytes.

Turn queueing off for requests that only make sense live, such as logging in:

```dart
await api.post('/login', body: credentials, queueIfOffline: false);
```

### Keep the queue across app restarts

The default queue and cache live in memory. On mobile and desktop, store them in files instead:

```dart
import 'package:offline_fetch/io.dart';
import 'package:path_provider/path_provider.dart';

final dir = await getApplicationSupportDirectory();

final api = OfflineFetch(
  baseUrl: 'https://api.example.com',
  queueStorage: FileQueueStorage('${dir.path}/offline_queue.json'),
  cacheStore: FileCacheStore('${dir.path}/http_cache'),
);
```

On the web, implement `QueueStorage` and `CacheStore` yourself (for example on top of `shared_preferences` or Hive). Each interface has only four or five methods.

### Send the queue as soon as the connection is back

The queue is sent automatically:

- when the client is created,
- every 30 seconds (`autoFlushInterval`),
- after any request that reaches the server.

For an instant sync, hook up [`connectivity_plus`](https://pub.dev/packages/connectivity_plus):

```dart
Connectivity().onConnectivityChanged.listen((results) {
  if (!results.contains(ConnectivityResult.none)) api.notifyOnline();
});
```

### Listen to the queue

```dart
api.queueEvents.listen((event) {
  switch (event) {
    case RequestQueued(:final item):
      print('Saved for later: ${item.request.url}');
    case QueuedRequestSent(:final item, :final response):
      print('Synced ${item.id}: ${response.statusCode}');
    case QueuedRequestFailed(:final item, :final error):
      print('Server error, will retry: $error');
    case QueuedRequestDropped(:final item, :final reason):
      print('Gave up on ${item.id}: $reason');
  }
});

final waiting = await api.pendingRequests();
print('${waiting.length} changes waiting to sync');
```

How queued requests are handled:

| Result when sending | What happens |
|---|---|
| Still offline | Stays in the queue. Not counted as an attempt, so a long time offline never loses data. Later items wait, to keep the order. |
| 2xx or 3xx | Removed. `QueuedRequestSent`. |
| 408, 429, 5xx | Stays in the queue and counts as an attempt. After `maxQueueAttempts` (default 10) it is dropped. |
| Other 4xx | The server rejected it, so it is removed. `QueuedRequestDropped` includes the response, so you can show the error. |

### Caching options

```dart
await api.get('/menu', cachePolicy: CachePolicy.cacheFirst);
```

| Policy | Behaviour |
|---|---|
| `networkFirst` (default) | Network first. If the network is down or the server answers 502/503/504, returns the last cached copy. |
| `cacheFirst` | Returns the cached copy if it is younger than `cacheMaxAge` (default 5 minutes). Otherwise uses the network, falling back to the old copy. |
| `cacheOnly` | Never touches the network. |
| `networkOnly` | Never touches the cache. |

The cache key is the method plus the full URL. Headers are not part of it, so call `api.clearCache()` when a user logs out.

### Retry options

```dart
final api = OfflineFetch(
  retryPolicy: const RetryPolicy(
    maxAttempts: 4,
    initialDelay: Duration(milliseconds: 500),
    maxDelay: Duration(seconds: 8),
    retryStatusCodes: {429, 500, 502, 503, 504},
  ),
);
```

Only requests that are safe to repeat are retried: `GET`, `HEAD`, `OPTIONS`, `PUT`, `DELETE`, and any request with an idempotency key. Queued requests always get a key, sent in the `Idempotency-Key` header, so offline-capable `POST`s are retried too. Use `RetryPolicy.none` to turn retries off.

> **Server tip:** store the `Idempotency-Key` of each request you process and ignore repeats. Then a request that reached the server but lost its response can never be saved twice.

### Interceptors

```dart
class AuthInterceptor extends FetchInterceptor {
  @override
  Future<FetchRequest> onRequest(FetchRequest request) async {
    final token = await secureStorage.read(key: 'token');
    return request.copyWith(
      headers: {...request.headers, 'authorization': 'Bearer $token'},
    );
  }
}

final api = OfflineFetch(interceptors: [AuthInterceptor()]);
```

Interceptors run each time a request is actually sent, including replays from the queue. A request queued yesterday is sent with today's token.

### Use your own `http.Client`

```dart
final api = OfflineFetch(httpClient: myCustomClient);
```

This lets you add certificate pinning, logging, or a `MockClient` in tests.

## Good to know

- When the device is offline, a request still makes its retry attempts before it falls back to the cache or queue. With the default policy that takes about one second. Use a smaller `RetryPolicy` if you want it faster.
- Non-2xx responses are returned, not thrown, the same as `package:http`. Check `response.isSuccess`.
- A queued response has status `202` and `isQueued == true`, and `isSuccess` is `false`, because the server hasn't answered yet.
- Call `api.close()` when you're done. Queued requests stay in storage for next time.

## Contributing

Issues and pull requests are welcome on [GitHub](https://github.com/SHARJEELAKRAM110/offline_fetch).

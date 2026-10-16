import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'cache.dart';
import 'fetch_exception.dart';
import 'fetch_request.dart';
import 'fetch_response.dart';
import 'interceptor.dart';
import 'queue.dart';
import 'retry_policy.dart';

/// An offline-first HTTP client.
///
/// * Failed requests are retried with backoff (see [retryPolicy]).
/// * `GET` responses are cached, and the cached copy is returned when the
///   network is down (see [cachePolicy]).
/// * `POST`, `PUT`, `PATCH` and `DELETE` requests that cannot reach the
///   server are saved to a queue and sent later, in order (see
///   [queueWhenOffline]). The call returns straight away with a response
///   whose `isQueued` is `true`.
///
/// ```dart
/// final api = OfflineFetch(baseUrl: 'https://api.example.com');
///
/// final products = await api.get('/products');
/// if (products.isFromCache) showOfflineBanner();
///
/// final order = await api.post('/orders', body: {'item': 42});
/// if (order.isQueued) showSnackBar('Saved. Will sync when online.');
/// ```
///
/// Call [close] when you no longer need the client.
class OfflineFetch {
  /// Creates a client.
  ///
  /// The queue is flushed when the client is created, every
  /// [autoFlushInterval] (set it to `null` to turn this off), after any
  /// request that reaches the server, and whenever you call [flushQueue] or
  /// [notifyOnline].
  OfflineFetch({
    this.baseUrl,
    Map<String, String> headers = const {},
    this.timeout = const Duration(seconds: 30),
    this.retryPolicy = const RetryPolicy(),
    this.cachePolicy = CachePolicy.networkFirst,
    CacheStore? cacheStore,
    this.cacheMaxAge = const Duration(minutes: 5),
    QueueStorage? queueStorage,
    this.queueWhenOffline = true,
    this.maxQueueAttempts = 10,
    Duration? autoFlushInterval = const Duration(seconds: 30),
    this.idempotencyKeyHeader = 'Idempotency-Key',
    List<FetchInterceptor> interceptors = const [],
    http.Client? httpClient,
    Future<void> Function(Duration duration)? sleep,
  })  : headers = Map.unmodifiable(headers),
        cacheStore = cacheStore ?? MemoryCacheStore(),
        queueStorage = queueStorage ?? MemoryQueueStorage(),
        interceptors = List.unmodifiable(interceptors),
        _http = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _sleep = sleep ?? Future<void>.delayed {
    if (autoFlushInterval != null) {
      _timer = Timer.periodic(autoFlushInterval, (_) => _flushIfPending());
    }
    // Requests may be left over from a previous run.
    _flushIfPending();
  }

  /// Prefix for relative paths, for example `https://api.example.com/v1`.
  final String? baseUrl;

  /// Headers added to every request. Per-request headers win.
  final Map<String, String> headers;

  /// How long to wait for a response before treating the network as down.
  final Duration timeout;

  /// When to retry failed requests.
  final RetryPolicy retryPolicy;

  /// Default cache behaviour for `GET` requests.
  final CachePolicy cachePolicy;

  /// Where `GET` responses are cached.
  final CacheStore cacheStore;

  /// How long a cached response counts as fresh for [CachePolicy.cacheFirst].
  /// Older responses are still used as a fallback when offline.
  final Duration cacheMaxAge;

  /// Where queued requests are kept.
  final QueueStorage queueStorage;

  /// Whether to queue `POST`, `PUT`, `PATCH` and `DELETE` requests when the
  /// network is down. Can be changed per request.
  final bool queueWhenOffline;

  /// How many server errors a queued request may get before it is dropped.
  final int maxQueueAttempts;

  /// Header that carries a unique key on every queueable request, so the
  /// server can ignore duplicates if a request is sent twice. Set to `null`
  /// to leave it out.
  final String? idempotencyKeyHeader;

  /// Interceptors, run in order.
  final List<FetchInterceptor> interceptors;

  final http.Client _http;
  final bool _ownsHttpClient;
  final Future<void> Function(Duration) _sleep;
  final StreamController<QueueEvent> _events =
      StreamController<QueueEvent>.broadcast();
  Timer? _timer;
  Future<int>? _flushing;
  bool _hasPending = true;
  bool _closed = false;

  /// Events from the offline queue: requests queued, sent, failed or dropped.
  Stream<QueueEvent> get queueEvents => _events.stream;

  /// Sends a `GET` request.
  Future<FetchResponse> get(
    String path, {
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    CachePolicy? cachePolicy,
    Duration? timeout,
  }) =>
      send(_build('GET', path,
          headers: headers,
          query: query,
          cachePolicy: cachePolicy,
          timeout: timeout));

  /// Sends a `POST` request.
  ///
  /// [body] can be a `String`, a `List<int>` of bytes, or anything
  /// `jsonEncode` accepts (sent as JSON).
  Future<FetchResponse> post(
    String path, {
    Object? body,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    bool? queueIfOffline,
    Duration? timeout,
  }) =>
      send(_build('POST', path,
          body: body,
          headers: headers,
          query: query,
          queueIfOffline: queueIfOffline,
          timeout: timeout));

  /// Sends a `PUT` request. See [post] for [body].
  Future<FetchResponse> put(
    String path, {
    Object? body,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    bool? queueIfOffline,
    Duration? timeout,
  }) =>
      send(_build('PUT', path,
          body: body,
          headers: headers,
          query: query,
          queueIfOffline: queueIfOffline,
          timeout: timeout));

  /// Sends a `PATCH` request. See [post] for [body].
  Future<FetchResponse> patch(
    String path, {
    Object? body,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    bool? queueIfOffline,
    Duration? timeout,
  }) =>
      send(_build('PATCH', path,
          body: body,
          headers: headers,
          query: query,
          queueIfOffline: queueIfOffline,
          timeout: timeout));

  /// Sends a `DELETE` request. See [post] for [body].
  Future<FetchResponse> delete(
    String path, {
    Object? body,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    bool? queueIfOffline,
    Duration? timeout,
  }) =>
      send(_build('DELETE', path,
          body: body,
          headers: headers,
          query: query,
          queueIfOffline: queueIfOffline,
          timeout: timeout));

  /// Sends [request], using the cache, retries and offline queue as set up.
  ///
  /// Returns the server's response, even for 4xx and 5xx statuses. Throws a
  /// [FetchException] only when the server cannot be reached and there is
  /// nothing to fall back on.
  Future<FetchResponse> send(FetchRequest request) async {
    _checkOpen();
    var base = request;

    final queueable =
        base.isMutation && (base.queueIfOffline ?? queueWhenOffline);
    final queueId = queueable ? _newId() : null;
    final keyHeader = idempotencyKeyHeader;
    if (queueable &&
        keyHeader != null &&
        !_hasHeader(base.headers, keyHeader)) {
      base = base.copyWith(headers: {...base.headers, keyHeader: queueId!});
    }

    final policy = base.method == 'GET'
        ? (base.cachePolicy ?? cachePolicy)
        : CachePolicy.networkOnly;
    final cacheKey = _cacheKey(base);
    CacheEntry? cached;
    if (policy != CachePolicy.networkOnly) {
      cached = await cacheStore.read(cacheKey);
      if (policy == CachePolicy.cacheOnly) {
        if (cached == null) {
          throw FetchException('No cached response', request: base);
        }
        return _applyResponseInterceptors(_fromCache(base, cached));
      }
      if (policy == CachePolicy.cacheFirst &&
          cached != null &&
          DateTime.now().difference(cached.storedAt) <= cacheMaxAge) {
        return _applyResponseInterceptors(_fromCache(base, cached));
      }
    }

    final prepared = await _applyRequestInterceptors(base);
    final http.Response raw;
    try {
      raw = await _sendWithRetry(prepared);
    } on FetchException catch (e) {
      if (!e.isNetworkError) rethrow;
      if (cached != null) {
        return _applyResponseInterceptors(_fromCache(base, cached));
      }
      if (queueable) return _enqueue(queueId!, base, e.message);
      rethrow;
    }

    if (_serverUnavailable(raw.statusCode)) {
      if (cached != null) {
        return _applyResponseInterceptors(_fromCache(base, cached));
      }
      if (queueable) {
        return _enqueue(
            queueId!, base, 'Server unavailable (${raw.statusCode})');
      }
    }

    final response = _fromHttp(prepared, raw);
    if (policy != CachePolicy.networkOnly && response.isSuccess) {
      await cacheStore.write(
        cacheKey,
        CacheEntry(
          statusCode: raw.statusCode,
          headers: raw.headers,
          bodyBytes: raw.bodyBytes,
          storedAt: DateTime.now(),
        ),
      );
    }
    // The server is reachable, so this is a good moment to send the queue.
    _flushIfPending();
    return _applyResponseInterceptors(response);
  }

  /// Sends queued requests now, oldest first. Returns how many were sent.
  ///
  /// Stops at the first request that still cannot reach the server, so
  /// requests are always delivered in the order they were made. If a flush is
  /// already running, returns that flush's result instead of starting a new
  /// one.
  Future<int> flushQueue() {
    _checkOpen();
    return _flushing ??= _flush().whenComplete(() => _flushing = null);
  }

  /// Tells the client the device is back online, so it sends the queue now.
  ///
  /// Call this from a connectivity listener, for example with the
  /// `connectivity_plus` package.
  Future<int> notifyOnline() => flushQueue();

  /// Returns the requests waiting in the queue, oldest first.
  Future<List<QueuedRequest>> pendingRequests() => queueStorage.loadAll();

  /// Removes every request from the queue without sending it.
  Future<void> clearQueue() async {
    await queueStorage.clear();
    _hasPending = false;
  }

  /// Removes every cached response. Call this when the user logs out.
  Future<void> clearCache() => cacheStore.clear();

  /// Stops the auto-flush timer and releases resources. The client cannot be
  /// used afterwards. Queued requests stay in storage for next time.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    await _flushing?.catchError((Object _) => 0);
    await _events.close();
    if (_ownsHttpClient) _http.close();
  }

  Future<int> _flush() async {
    final items = await queueStorage.loadAll();
    var sent = 0;
    for (final item in items) {
      final prepared = await _applyRequestInterceptors(item.request);
      final http.Response raw;
      try {
        raw = await _sendOnce(prepared);
      } on FetchException {
        // Still offline. Not counted as an attempt, so a long time offline
        // never drops requests. Stop to keep the order.
        break;
      }
      final response = _fromHttp(prepared, raw);
      if (raw.statusCode < 400) {
        await queueStorage.remove(item.id);
        sent++;
        _emit(QueuedRequestSent(item, response));
      } else if (retryPolicy.retryStatusCodes.contains(raw.statusCode)) {
        final updated = item.copyWith(
          attempts: item.attempts + 1,
          lastError: 'Server answered ${raw.statusCode}',
        );
        if (updated.attempts >= maxQueueAttempts) {
          await queueStorage.remove(item.id);
          _emit(QueuedRequestDropped(
            updated,
            'Gave up after ${updated.attempts} attempts: ${updated.lastError}',
            response: response,
          ));
          continue;
        }
        await queueStorage.update(updated);
        _emit(QueuedRequestFailed(updated, updated.lastError!));
        break;
      } else {
        await queueStorage.remove(item.id);
        _emit(QueuedRequestDropped(
          item,
          'Server rejected the request (${raw.statusCode})',
          response: response,
        ));
      }
    }
    _hasPending = (await queueStorage.loadAll()).isNotEmpty;
    return sent;
  }

  void _flushIfPending() {
    if (_closed || !_hasPending || _flushing != null) return;
    unawaited(flushQueue().catchError((Object _) => 0));
  }

  Future<FetchResponse> _enqueue(
      String id, FetchRequest request, String reason) async {
    final item = QueuedRequest(
      id: id,
      request: request,
      createdAt: DateTime.now(),
      lastError: reason,
    );
    await queueStorage.add(item);
    _hasPending = true;
    _emit(RequestQueued(item));
    return FetchResponse(
      statusCode: 202,
      request: request,
      source: ResponseSource.queue,
      reasonPhrase: 'Queued: $reason',
      queuedRequestId: id,
    );
  }

  Future<http.Response> _sendWithRetry(FetchRequest request) async {
    final keyHeader = idempotencyKeyHeader;
    final canRetry = request.isIdempotent ||
        retryPolicy.retryNonIdempotent ||
        (keyHeader != null && _hasHeader(request.headers, keyHeader));
    final maxAttempts = canRetry ? retryPolicy.maxAttempts : 1;

    for (var attempt = 1;; attempt++) {
      try {
        final response = await _sendOnce(request);
        if (attempt < maxAttempts &&
            retryPolicy.retryStatusCodes.contains(response.statusCode)) {
          await _sleep(retryPolicy.delayFor(attempt,
              retryAfter: _parseRetryAfter(response.headers['retry-after'])));
          continue;
        }
        return response;
      } on FetchException catch (e) {
        if (!e.isNetworkError || attempt >= maxAttempts) rethrow;
        await _sleep(retryPolicy.delayFor(attempt));
      }
    }
  }

  Future<http.Response> _sendOnce(FetchRequest request) async {
    final req = http.Request(request.method, request.url)
      ..headers.addAll(request.headers);
    final body = request.bodyBytes;
    if (body != null) req.bodyBytes = body;
    final limit = request.timeout ?? timeout;
    try {
      return await () async {
        final streamed = await _http.send(req);
        return http.Response.fromStream(streamed);
      }()
          .timeout(limit);
    } on TimeoutException catch (e) {
      throw FetchException(
        'Timed out after ${limit.inMilliseconds} ms',
        request: request,
        cause: e,
        isNetworkError: true,
      );
    } on http.ClientException catch (e) {
      throw FetchException(
        'Network error: ${e.message}',
        request: request,
        cause: e,
        isNetworkError: true,
      );
    }
  }

  Future<FetchRequest> _applyRequestInterceptors(FetchRequest request) async {
    var result = request;
    for (final interceptor in interceptors) {
      result = await interceptor.onRequest(result);
    }
    return result;
  }

  Future<FetchResponse> _applyResponseInterceptors(
      FetchResponse response) async {
    var result = response;
    for (final interceptor in interceptors) {
      result = await interceptor.onResponse(result);
    }
    return result;
  }

  FetchRequest _build(
    String method,
    String path, {
    Object? body,
    Map<String, String>? headers,
    Map<String, dynamic>? query,
    bool? queueIfOffline,
    CachePolicy? cachePolicy,
    Duration? timeout,
  }) {
    final merged = {...this.headers, ...?headers};
    final (bytes, contentType) = _encodeBody(body);
    if (contentType != null && !_hasHeader(merged, 'content-type')) {
      merged['content-type'] = contentType;
    }
    return FetchRequest(
      method: method,
      url: _resolveUrl(path, query),
      headers: merged,
      bodyBytes: bytes,
      queueIfOffline: queueIfOffline,
      cachePolicy: cachePolicy,
      timeout: timeout,
    );
  }

  Uri _resolveUrl(String path, Map<String, dynamic>? query) {
    final isAbsolute =
        path.startsWith('http://') || path.startsWith('https://');
    if (!isAbsolute && baseUrl == null) {
      throw ArgumentError.value(
          path, 'path', 'Relative path given but no baseUrl is set');
    }
    final base = baseUrl == null ? '' : baseUrl!.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse(isAbsolute
        ? path
        : '$base${path.startsWith('/') || path.isEmpty ? '' : '/'}$path');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: {
      ...uri.queryParametersAll,
      for (final entry in query.entries)
        entry.key: entry.value is Iterable
            ? (entry.value as Iterable).map((v) => '$v').toList()
            : '${entry.value}',
    });
  }

  static (List<int>?, String?) _encodeBody(Object? body) => switch (body) {
        null => (null, null),
        String text => (utf8.encode(text), 'text/plain; charset=utf-8'),
        List<int> bytes => (bytes, 'application/octet-stream'),
        _ => (utf8.encode(jsonEncode(body)), 'application/json; charset=utf-8'),
      };

  FetchResponse _fromHttp(FetchRequest request, http.Response raw) =>
      FetchResponse(
        statusCode: raw.statusCode,
        request: request,
        source: ResponseSource.network,
        headers: raw.headers,
        bodyBytes: raw.bodyBytes,
        reasonPhrase: raw.reasonPhrase,
      );

  FetchResponse _fromCache(FetchRequest request, CacheEntry entry) =>
      FetchResponse(
        statusCode: entry.statusCode,
        request: request,
        source: ResponseSource.cache,
        headers: entry.headers,
        bodyBytes: entry.bodyBytes,
        cachedAt: entry.storedAt,
      );

  static String _cacheKey(FetchRequest request) =>
      '${request.method} ${request.url}';

  static bool _serverUnavailable(int status) =>
      status == 502 || status == 503 || status == 504;

  static bool _hasHeader(Map<String, String> headers, String name) {
    final lower = name.toLowerCase();
    return headers.keys.any((k) => k.toLowerCase() == lower);
  }

  static Duration? _parseRetryAfter(String? value) {
    final seconds = value == null ? null : int.tryParse(value.trim());
    return seconds == null ? null : Duration(seconds: seconds);
  }

  static final Random _random = () {
    try {
      return Random.secure();
    } on UnsupportedError {
      return Random();
    }
  }();

  static String _newId() {
    final time = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final rand = List.generate(
      4,
      (_) => _random.nextInt(1 << 16).toRadixString(16).padLeft(4, '0'),
    ).join();
    return '$time-$rand';
  }

  void _emit(QueueEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _checkOpen() {
    if (_closed) throw StateError('OfflineFetch has been closed');
  }
}

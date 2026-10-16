import 'dart:convert';
import 'dart:typed_data';

import 'fetch_request.dart';

/// Where a [FetchResponse] came from.
enum ResponseSource {
  /// A live response from the server.
  network,

  /// A stored response, returned because of the cache policy or because the
  /// network was down.
  cache,

  /// The network was down, so the request was saved to the offline queue and
  /// will be sent later. The response has no body.
  queue,
}

/// The result of a request sent with `OfflineFetch`.
class FetchResponse {
  /// Creates a response.
  FetchResponse({
    required this.statusCode,
    required this.request,
    required this.source,
    Map<String, String>? headers,
    List<int>? bodyBytes,
    this.reasonPhrase,
    this.cachedAt,
    this.queuedRequestId,
  })  : headers = Map.unmodifiable(headers ?? const <String, String>{}),
        bodyBytes = bodyBytes == null
            ? Uint8List(0)
            : bodyBytes is Uint8List
                ? bodyBytes
                : Uint8List.fromList(bodyBytes);

  /// The HTTP status code. Queued responses use `202 Accepted`.
  final int statusCode;

  /// Response headers. Names are lower-case.
  final Map<String, String> headers;

  /// The raw response body.
  final Uint8List bodyBytes;

  /// The request this response answers.
  final FetchRequest request;

  /// Where this response came from.
  final ResponseSource source;

  /// The reason phrase from the server, if any.
  final String? reasonPhrase;

  /// When the response was stored, for responses served from the cache.
  final DateTime? cachedAt;

  /// The offline queue ID, for queued responses. Matches the ID in queue
  /// events, so you can tell when this request is finally sent.
  final String? queuedRequestId;

  /// The body decoded as UTF-8.
  String get body => utf8.decode(bodyBytes, allowMalformed: true);

  /// The body parsed as JSON.
  dynamic json() => jsonDecode(body);

  /// Whether the server answered with a 2xx status. Always `false` for queued
  /// responses, because the server has not answered yet.
  bool get isSuccess => !isQueued && statusCode >= 200 && statusCode < 300;

  /// Whether the request was saved to the offline queue.
  bool get isQueued => source == ResponseSource.queue;

  /// Whether the response was served from the cache.
  bool get isFromCache => source == ResponseSource.cache;

  @override
  String toString() =>
      'FetchResponse($statusCode from ${source.name}, ${request.method} ${request.url})';
}

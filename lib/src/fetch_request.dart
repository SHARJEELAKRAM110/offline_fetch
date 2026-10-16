import 'dart:convert';

import 'cache.dart';

/// An HTTP request that `OfflineFetch` can send, retry, cache or queue.
///
/// Requests are immutable. Use [copyWith] to change one, for example inside a
/// `FetchInterceptor`.
class FetchRequest {
  /// Creates a request. [method] is upper-cased.
  FetchRequest({
    required String method,
    required this.url,
    Map<String, String>? headers,
    this.bodyBytes,
    this.queueIfOffline,
    this.cachePolicy,
    this.timeout,
  })  : method = method.toUpperCase(),
        headers = Map.unmodifiable(headers ?? const <String, String>{});

  /// Restores a request saved with [toJson].
  factory FetchRequest.fromJson(Map<String, dynamic> json) {
    final body = json['body'] as String?;
    final timeoutMs = json['timeoutMs'] as int?;
    return FetchRequest(
      method: json['method'] as String,
      url: Uri.parse(json['url'] as String),
      headers: (json['headers'] as Map?)?.cast<String, String>(),
      bodyBytes: body == null ? null : base64Decode(body),
      timeout: timeoutMs == null ? null : Duration(milliseconds: timeoutMs),
    );
  }

  /// The HTTP method, for example `GET` or `POST`.
  final String method;

  /// The full request URL.
  final Uri url;

  /// Request headers.
  final Map<String, String> headers;

  /// The raw request body, or `null` for no body.
  final List<int>? bodyBytes;

  /// Whether to queue this request when the network is down.
  ///
  /// `null` uses the client's `queueWhenOffline` setting. Only applies to
  /// methods that change data (`POST`, `PUT`, `PATCH`, `DELETE`).
  final bool? queueIfOffline;

  /// How to use the cache for this request. `null` uses the client default.
  /// Only applies to `GET`.
  final CachePolicy? cachePolicy;

  /// Timeout for this request. `null` uses the client default.
  final Duration? timeout;

  /// The body decoded as UTF-8, or `null` when there is no body.
  String? get body =>
      bodyBytes == null ? null : utf8.decode(bodyBytes!, allowMalformed: true);

  /// Whether sending this request twice has the same effect as sending it
  /// once, so it is safe to retry.
  bool get isIdempotent => const {
        'GET',
        'HEAD',
        'OPTIONS',
        'PUT',
        'DELETE',
      }.contains(method);

  /// Whether this request changes data on the server.
  bool get isMutation => !const {'GET', 'HEAD', 'OPTIONS'}.contains(method);

  /// Returns a copy with the given fields replaced.
  FetchRequest copyWith({
    String? method,
    Uri? url,
    Map<String, String>? headers,
    List<int>? bodyBytes,
    bool? queueIfOffline,
    CachePolicy? cachePolicy,
    Duration? timeout,
  }) {
    return FetchRequest(
      method: method ?? this.method,
      url: url ?? this.url,
      headers: headers ?? this.headers,
      bodyBytes: bodyBytes ?? this.bodyBytes,
      queueIfOffline: queueIfOffline ?? this.queueIfOffline,
      cachePolicy: cachePolicy ?? this.cachePolicy,
      timeout: timeout ?? this.timeout,
    );
  }

  /// Converts the request to JSON so it can be stored in the offline queue.
  Map<String, dynamic> toJson() => {
        'method': method,
        'url': url.toString(),
        'headers': headers,
        'body': bodyBytes == null ? null : base64Encode(bodyBytes!),
        if (timeout != null) 'timeoutMs': timeout!.inMilliseconds,
      };

  @override
  String toString() => 'FetchRequest($method $url)';
}

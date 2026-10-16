import 'fetch_request.dart';

/// Thrown when a request fails and there is no cached response or queue to
/// fall back on.
///
/// Non-2xx responses from the server are not exceptions; they are returned as
/// a normal `FetchResponse`. Check `FetchResponse.isSuccess`.
class FetchException implements Exception {
  /// Creates an exception.
  const FetchException(
    this.message, {
    this.request,
    this.cause,
    this.isNetworkError = false,
  });

  /// What went wrong.
  final String message;

  /// The request that failed, if known.
  final FetchRequest? request;

  /// The underlying error, if any.
  final Object? cause;

  /// Whether the server could not be reached at all (no connection, DNS
  /// failure, timeout).
  final bool isNetworkError;

  @override
  String toString() => request == null
      ? 'FetchException: $message'
      : 'FetchException: $message (${request!.method} ${request!.url})';
}

import 'dart:async';

import 'fetch_request.dart';
import 'fetch_response.dart';

/// Changes requests before they are sent and responses before they are
/// returned.
///
/// Interceptors run every time a request is actually sent, including when a
/// queued request is replayed later. So an interceptor that adds an
/// `Authorization` header always uses the current token, not the one from
/// when the request was queued.
///
/// ```dart
/// class AuthInterceptor extends FetchInterceptor {
///   @override
///   Future<FetchRequest> onRequest(FetchRequest request) async {
///     final token = await tokenStore.read();
///     return request.copyWith(
///       headers: {...request.headers, 'Authorization': 'Bearer $token'},
///     );
///   }
/// }
/// ```
abstract class FetchInterceptor {
  /// Const constructor for subclasses.
  const FetchInterceptor();

  /// Called before a request is sent. Return the request to send.
  FutureOr<FetchRequest> onRequest(FetchRequest request) => request;

  /// Called before a network or cached response is returned. Return the
  /// response to give back to the caller.
  FutureOr<FetchResponse> onResponse(FetchResponse response) => response;
}

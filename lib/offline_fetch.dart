/// Offline-first HTTP client for Dart and Flutter.
///
/// Retries failed requests with exponential backoff, serves cached `GET`
/// responses when the network is down, and queues `POST`, `PUT`, `PATCH`
/// and `DELETE` requests until the device is back online.
///
/// For storage that survives app restarts on mobile and desktop, also import
/// `package:offline_fetch/io.dart`.
library;

export 'src/cache.dart';
export 'src/client.dart';
export 'src/fetch_exception.dart';
export 'src/fetch_request.dart';
export 'src/fetch_response.dart';
export 'src/interceptor.dart';
export 'src/queue.dart';
export 'src/retry_policy.dart';

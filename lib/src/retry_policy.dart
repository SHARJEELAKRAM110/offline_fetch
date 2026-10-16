import 'dart:math';

/// When and how often to retry a failed request.
///
/// A request is retried after a network error or when the server answers
/// with one of [retryStatusCodes]. Delays grow exponentially:
/// [initialDelay], then `initialDelay * multiplier`, and so on, never more
/// than [maxDelay].
///
/// Only requests that are safe to repeat are retried: `GET`, `HEAD`,
/// `OPTIONS`, `PUT`, `DELETE`, and any request with an idempotency key header.
/// Set [retryNonIdempotent] to also retry other `POST` and `PATCH` requests.
class RetryPolicy {
  /// Creates a retry policy.
  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(milliseconds: 300),
    this.multiplier = 2,
    this.maxDelay = const Duration(seconds: 10),
    this.jitter = true,
    this.retryStatusCodes = const {408, 429, 500, 502, 503, 504},
    this.retryNonIdempotent = false,
  }) : assert(maxAttempts >= 1, 'maxAttempts must be at least 1');

  /// A policy that never retries.
  static const RetryPolicy none = RetryPolicy(maxAttempts: 1);

  /// Total number of tries, including the first one.
  final int maxAttempts;

  /// Wait before the first retry.
  final Duration initialDelay;

  /// How much the wait grows after each retry.
  final double multiplier;

  /// The longest wait between two tries, including waits asked for by a
  /// server's `Retry-After` header.
  final Duration maxDelay;

  /// Whether to randomise each wait between 50% and 100% of its value, so
  /// many devices coming back online do not all retry at the same moment.
  final bool jitter;

  /// Server status codes that are worth retrying.
  final Set<int> retryStatusCodes;

  /// Whether to retry `POST` and `PATCH` requests that have no idempotency
  /// key. This can create duplicates if the server received the first try.
  final bool retryNonIdempotent;

  static final Random _random = Random();

  /// The wait before retry number [attempt] (1 for the first retry).
  ///
  /// [retryAfter] is the wait the server asked for, if any; it takes
  /// priority but is still capped at [maxDelay].
  Duration delayFor(int attempt, {Duration? retryAfter}) {
    if (retryAfter != null) {
      return retryAfter > maxDelay ? maxDelay : retryAfter;
    }
    final base = initialDelay.inMicroseconds * pow(multiplier, attempt - 1);
    var micros = min(base, maxDelay.inMicroseconds.toDouble());
    if (jitter) micros = micros * (0.5 + _random.nextDouble() * 0.5);
    return Duration(microseconds: micros.round());
  }
}

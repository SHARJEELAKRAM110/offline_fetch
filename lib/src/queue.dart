import 'fetch_request.dart';
import 'fetch_response.dart';

/// A request waiting in the offline queue.
class QueuedRequest {
  /// Creates a queued request.
  const QueuedRequest({
    required this.id,
    required this.request,
    required this.createdAt,
    this.attempts = 0,
    this.lastError,
  });

  /// Restores a queued request saved with [toJson].
  factory QueuedRequest.fromJson(Map<String, dynamic> json) => QueuedRequest(
        id: json['id'] as String,
        request: FetchRequest.fromJson(json['request'] as Map<String, dynamic>),
        createdAt: DateTime.parse(json['createdAt'] as String),
        attempts: json['attempts'] as int? ?? 0,
        lastError: json['lastError'] as String?,
      );

  /// Unique ID. Also sent as the idempotency key header, unless that header
  /// is turned off.
  final String id;

  /// The request to send.
  final FetchRequest request;

  /// When the request was queued.
  final DateTime createdAt;

  /// How many times the server answered with an error while replaying this
  /// request. Network failures while still offline are not counted.
  final int attempts;

  /// The last error seen while replaying this request.
  final String? lastError;

  /// Returns a copy with the given fields replaced.
  QueuedRequest copyWith({int? attempts, String? lastError}) => QueuedRequest(
        id: id,
        request: request,
        createdAt: createdAt,
        attempts: attempts ?? this.attempts,
        lastError: lastError ?? this.lastError,
      );

  /// Converts the queued request to JSON.
  Map<String, dynamic> toJson() => {
        'id': id,
        'request': request.toJson(),
        'createdAt': createdAt.toUtc().toIso8601String(),
        'attempts': attempts,
        if (lastError != null) 'lastError': lastError,
      };

  @override
  String toString() => 'QueuedRequest($id, ${request.method} ${request.url})';
}

/// Where the offline queue is kept.
///
/// Requests are replayed in the order [loadAll] returns them, so keep them in
/// the order they were added. Implement this to store the queue somewhere
/// else, such as Hive, SharedPreferences or SQLite.
abstract interface class QueueStorage {
  /// Returns every queued request, oldest first.
  Future<List<QueuedRequest>> loadAll();

  /// Adds [item] to the end of the queue.
  Future<void> add(QueuedRequest item);

  /// Replaces the stored item that has the same ID as [item].
  Future<void> update(QueuedRequest item);

  /// Removes the item with this [id].
  Future<void> remove(String id);

  /// Removes every item.
  Future<void> clear();
}

/// Keeps the offline queue in memory. It is lost when the app closes.
class MemoryQueueStorage implements QueueStorage {
  final List<QueuedRequest> _items = [];

  @override
  Future<List<QueuedRequest>> loadAll() async => List.of(_items);

  @override
  Future<void> add(QueuedRequest item) async => _items.add(item);

  @override
  Future<void> update(QueuedRequest item) async {
    final index = _items.indexWhere((e) => e.id == item.id);
    if (index != -1) _items[index] = item;
  }

  @override
  Future<void> remove(String id) async => _items.removeWhere((e) => e.id == id);

  @override
  Future<void> clear() async => _items.clear();
}

/// Something that happened in the offline queue. Listen with
/// `OfflineFetch.queueEvents`.
sealed class QueueEvent {
  const QueueEvent(this.item);

  /// The queued request this event is about.
  final QueuedRequest item;
}

/// A request could not reach the server and was added to the queue.
final class RequestQueued extends QueueEvent {
  /// Creates the event.
  const RequestQueued(super.item);
}

/// A queued request was sent and the server accepted it.
final class QueuedRequestSent extends QueueEvent {
  /// Creates the event.
  const QueuedRequestSent(super.item, this.response);

  /// The server's response.
  final FetchResponse response;
}

/// A queued request reached the server but got a temporary error (such as
/// 503). It stays in the queue and will be tried again.
final class QueuedRequestFailed extends QueueEvent {
  /// Creates the event.
  const QueuedRequestFailed(super.item, this.error);

  /// What went wrong.
  final String error;
}

/// A queued request was removed without succeeding, either because the
/// server rejected it (such as 400 or 404) or because it failed too many
/// times.
final class QueuedRequestDropped extends QueueEvent {
  /// Creates the event.
  const QueuedRequestDropped(super.item, this.reason, {this.response});

  /// Why it was dropped.
  final String reason;

  /// The server's response, if the server rejected the request.
  final FetchResponse? response;
}

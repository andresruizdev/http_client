import 'dart:async';

import '../http_client.dart';
import 'tracking_client.dart';

/// Creates a HTTP client asynchronously.
typedef CreateClientFn = Future<Client> Function();

/// Closes a HTTP client.
typedef CloseClientFn = Future Function(TrackingClient client, bool forceClose);

/// Automatically updates the underlying client after the specified use limits.
class UpdatingClient implements Client {
  final CreateClientFn _createClientFn;
  final CloseClientFn _closeClientFn;
  final int _requestLimit;
  final Duration _timeLimit;
  final bool _invalidateOnError;
  final bool _forceCloseOnError;

  Timer? _cleanupTimer;
  final _pastClients = <_Client?>[];
  _Client? _current;
  Completer? _nextCompleter;
  bool _isClosing = false;

  ///
  UpdatingClient({
    required CreateClientFn createClientFn,
    CloseClientFn? closeClientFn,
    int requestLimit = 1000,
    Duration timeLimit = const Duration(hours: 1),
    bool invalidateOnError = false,
    bool forceCloseOnError = false,
  })  : _createClientFn = createClientFn,
        _closeClientFn =
            closeClientFn ?? ((client, force) => client.close(force: force)),
        _requestLimit = requestLimit,
        _timeLimit = timeLimit,
        _invalidateOnError = invalidateOnError,
        _forceCloseOnError = forceCloseOnError;

  @override
  Future<Response> send(Request request) {
    return withClient((client) => client.send(request));
  }

  /// Runs a function with a [TrackingClient] as parameter and handles
  /// invalidation on exceptions.
  ///
  /// The client remains the same until the function completes.
  Future<R> withClient<R>(
    Future<R> Function(TrackingClient client) fn, {
    bool invalidateOnError = false,
    bool forceCloseOnError = false,
  }) async {
    _initCleanupTimer();
    final client = await _allocate();
    try {
      return await fn(client._client);
    } catch (_) {
      if (_invalidateOnError ||
          invalidateOnError ||
          _forceCloseOnError ||
          forceCloseOnError) {
        client._forceClose = _forceCloseOnError || forceCloseOnError;
        if (_current == client) {
          _current = null;
          _pastClients.add(client);
        }
      }
      rethrow;
    } finally {
      await _release(client);
    }
  }

  @override
  Future close({bool force = false}) async {
    _isClosing = true;
    expireCurrent();
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    await _cleanupPastClients(force);
    if (_current != null) {
      await _closeClientFn(_current!._client, force);
    }
  }

  void _initCleanupTimer() {
    if (_cleanupTimer != null) return;
    _cleanupTimer = Timer.periodic(Duration(minutes: 4), (_) {
      if (_pastClients.isEmpty) return;
      _cleanupPastClients(false, Duration(minutes: 3, seconds: 45));
    });
  }

  Future _cleanupPastClients(bool force, [Duration? timeout]) async {
    if (_pastClients.isEmpty) return;
    final pastClients = List<_Client>.from(_pastClients);
    final futures = pastClients
        .map((c) => _closeClientFn(c._client, force || c._forceClose))
        .map((f) => timeout == null ? f : f.timeout(timeout))
        .map((f) => f.catchError((_) async => null))
        .toList();
    await Future.wait(futures);
    pastClients.forEach(_pastClients.remove);
  }

  Future<_Client> _allocate() async {
    if (_isClosing) {
      throw StateError('HTTP Client closing.');
    }
    // expire if needed
    if (_current != null && _current!.isExpired(_requestLimit, _timeLimit)) {
      expireCurrent();
    }
    // wait for ongoing creation
    if (_nextCompleter != null) {
      await _nextCompleter!.future;
    }
    // return if available
    if (_current != null) {
      _current!._useCount++;
      return _current!;
    }
    // create new
    _nextCompleter = Completer();
    try {
      final client = await _createClientFn();
      final trackingClient =
          client is TrackingClient ? client : TrackingClient(client);
      expireCurrent();
      _current = _Client(trackingClient);
      _current!._useCount++;
      _nextCompleter!.complete();
      return _current!;
    } finally {
      _nextCompleter = null;
    }
  }

  /// Marks the currently active client as expired, next calls should trigger a
  /// new client creation.
  void expireCurrent({bool force = false}) {
    if (_current != null) {
      _current!._forceClose = force;
      _pastClients.add(_current);
      _current = null;
    }
  }

  Future _release(_Client client) async {
    client._useCount--;
  }
}

class _Client {
  final TrackingClient _client;
  final _created = DateTime.now();
  int _useCount = 0;
  bool _forceClose = false;

  _Client(this._client);

  int get requestCount => _client.ongoingCount + _client.completedCount;

  bool isExpired(int requestLimit, Duration timeLimit) {
    if (requestCount > requestLimit) return true;
    final now = DateTime.now();
    final diff = now.difference(_created);
    if (diff > timeLimit) return true;
    return false;
  }
}

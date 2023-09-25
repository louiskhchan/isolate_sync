import 'dart:async';
import 'dart:isolate';

import 'package:isolate_sync/src/sync_value.dart';

abstract class IsolateSync {
  factory IsolateSync() {
    try {
      return _IsolateSync();
    } catch (_) {
      return _DummySync();
    }
  }

  bool get shouldOpen;

  /// Close the isolate helper
  Future<void> close();

  /// Run a function in the isolate.
  Future<T> run<T>(
    FutureOr<T> Function({required List args}) func, {
    required List args,
  });

  /// Stream in the isolate.
  Stream<T> stream<T>(
    Stream<T> Function({required List args}) func, {
    required List args,
  });
}

// Main implementation
class _IsolateSync implements IsolateSync {
  final _receivePort = ReceivePort();
  SendPort? _sendPort;
  final _startCompleter = Completer();
  final _endCompleter = Completer();
  final Map<int, Completer<dynamic>> _futureCompleters = {};
  final Map<int, _RunFutureRequest> _futureRequests = {};
  final Map<int, StreamController<dynamic>> _streamControllers = {};
  final Map<int, _RunStreamRequest> _streamRequests = {};
  bool _isClosed = false;

  @override
  bool get shouldOpen => _isClosed;

  _IsolateSync() {
    Isolate.spawn(
      _IsolateInstance().main,
      _receivePort.sendPort,
    ).then((_) => _processResponses());
  }

  void _processResponses() async {
    await for (final response in _receivePort) {
      if (_sendPort == null) {
        // The first message is sendPort
        _sendPort = response as SendPort;
        _startCompleter.complete();
      } else if (response is _FutureErrorResponse) {
        _futureCompleters[response.key]?.complete(
          Future.error(
            response.e,
            response.s,
          ),
        );
      } else if (response is SyncResponse) {
        if (_futureRequests[response.key]?.args[response.arg.key]
            case SyncValue syncValue) {
          syncValue.value = response.arg.value;
        }
        response.arg.value;
      } else if (response is _FutureResultResponse) {
        _futureCompleters[response.key]?.complete(response.result);
      } else if (response is _StreamDoneResponse) {
        _streamControllers[response.key]?.close();
      } else if (response is _StreamEventResponse) {
        _streamControllers[response.key]?.add(response.event);
      } else if (response is _StreamErrorResponse) {
        _streamControllers[response.key]?.addError(
          response.e,
          response.s,
        );
      } else if (response is _StreamAllDoneResponse) {
        for (var e in _streamControllers.values) {
          e.close();
        }
      } else if (response is _CloseIsolateEcho) {
        break;
      }
    }
    _receivePort.close();
    _endCompleter.complete();
  }

  void _checkIsClosed() {
    if (_isClosed) throw '$runtimeType is closed already.';
  }

  @override
  Future<void> close() async {
    _checkIsClosed();
    _isClosed = true;
    await _startCompleter.future;
    _sendPort!.send(_StreamCancelAllRequest());
    _sendPort!.send(_CloseIsolateEcho());
    await Future.wait([
      for (final e in _futureCompleters.values) e.future,
      for (final e in _streamControllers.values)
        if (e.hasListener) e.done,
    ]);
    _futureCompleters.clear();
    _futureRequests.clear();
    _streamControllers.clear();

    await _endCompleter.future;
  }

  @override
  Future<T> run<T>(
    FutureOr<T> Function({required List args}) func, {
    required List args,
  }) async {
    _checkIsClosed();
    await _startCompleter.future;

    final request = _RunFutureRequest(
      args,
      func,
    );
    _futureRequests[request.key] = request;
    final completer = _futureCompleters[request.key] = Completer<T>();
    _sendPort!.send(request);
    final result = await completer.future;
    _futureCompleters.remove(request.key);
    _futureRequests.remove(request.key);
    return result;
  }

  @override
  Stream<T> stream<T>(
    Stream<T> Function({required List args}) func, {
    required List args,
  }) async* {
    _checkIsClosed();
    await _startCompleter.future;

    final request = _RunStreamRequest(
      args,
      func,
    );
    // The sink will be closed by:
    // request.createCancelRequest() -> _StreamDoneResponse
    // ignore: close_sinks
    _streamRequests[request.key] = request;
    final controller = _streamControllers[request.key] = StreamController<T>();
    controller.onCancel = () async {
      if (!controller.isClosed) {
        _sendPort!.send(request.createCancelRequest());
        await controller.done;
        _streamControllers.remove(request.key);
        _streamRequests.remove(request.key);
      }
    };

    _sendPort!.send(request);
    yield* controller.stream;
    _streamControllers.remove(request.key);
    _streamRequests.remove(request.key);
  }
}

// Inter-isolate message classes
abstract class _ParentMessage {
  static int _requestCount = 0;
  late int key;
  _ParentMessage() {
    key = _requestCount++;
  }
}

abstract class _Message {
  int key;
  _Message(this.key);
}

class _CloseIsolateEcho extends _ParentMessage {}

class SyncableRequest extends _ParentMessage {
  SyncResponse createSyncResponse(
    int index,
    dynamic arg,
  ) =>
      SyncResponse(key, MapEntry(index, arg));
}

class _FutureRequest<T> extends SyncableRequest {
  _FutureErrorResponse createErrorResponse(
    dynamic e,
    dynamic s,
  ) =>
      _FutureErrorResponse(key, e, s);
  _FutureResultResponse createResultResponse(
    T result,
  ) =>
      _FutureResultResponse(key, result);
}

class _RunFutureRequest<T> extends _FutureRequest<T> {
  List args;
  FutureOr<T> Function({required List args}) func;
  _RunFutureRequest(
    this.args,
    this.func,
  );
}

class _FutureErrorResponse<T> extends _Message {
  dynamic e, s;
  _FutureErrorResponse(
    super.key,
    this.e,
    this.s,
  );
}

class SyncResponse<T> extends _Message {
  MapEntry<int, T> arg;
  SyncResponse(
    super.key,
    this.arg,
  );
}

class _FutureResultResponse<T> extends _Message {
  T result;
  _FutureResultResponse(
    super.key,
    this.result,
  );
}

class _StreamRequest<T> extends SyncableRequest {
  _StreamErrorResponse createErrorResponse(
    dynamic e,
    dynamic s,
  ) =>
      _StreamErrorResponse(key, e, s);
  _StreamEventResponse<T> createEventResponse(
    T event,
  ) =>
      _StreamEventResponse(key, event);
  _StreamDoneResponse createDoneResponse() => _StreamDoneResponse(key);
  _StreamCancelRequest createCancelRequest() => _StreamCancelRequest(key);
}

class _StreamErrorResponse extends _Message {
  dynamic e, s;
  _StreamErrorResponse(
    super.key,
    this.e,
    this.s,
  );
}

class _StreamEventResponse<T> extends _Message {
  T event;
  _StreamEventResponse(
    super.key,
    this.event,
  );
}

class _StreamDoneResponse extends _Message {
  _StreamDoneResponse(
    super.key,
  );
}

class _StreamCancelRequest extends _Message {
  _StreamCancelRequest(
    super.key,
  );
  _StreamDoneResponse createDoneResponse() => _StreamDoneResponse(key);
}

class _StreamCancelAllRequest extends _ParentMessage {
  _StreamCancelAllRequest();
  _StreamAllDoneResponse createAllDoneResponse() => _StreamAllDoneResponse(key);
}

class _StreamAllDoneResponse extends _Message {
  _StreamAllDoneResponse(
    super.key,
  );
}

class _RunStreamRequest<T> extends _StreamRequest<T> {
  List args;
  Stream<T> Function({required List args}) func;
  _RunStreamRequest(
    this.args,
    this.func,
  );
}

// The class that holds everything in the isolate.
class _IsolateInstance {
  late final SendPort _sendPort;
  final Map<int, StreamSubscription> _streamSubscriptions = {};

  void main(SendPort sendPort) async {
    _sendPort = sendPort;
    final receivePort = ReceivePort();
    _sendPort.send(receivePort.sendPort);
    await for (final request in receivePort) {
      if (request is _CloseIsolateEcho) {
        _sendPort.send(request);
        break;
      } else if (request is _StreamCancelRequest) {
        _streamSubscriptions[request.key]?.cancel().then(
          (value) {
            _streamSubscriptions.remove(request.key);
            _sendPort.send(request.createDoneResponse());
          },
        );
      } else if (request is _StreamCancelAllRequest) {
        Future.wait([..._streamSubscriptions.values.map((e) => e.cancel())])
            .then(
          (_) {
            _streamSubscriptions.clear();
            _sendPort.send(request.createAllDoneResponse());
          },
        );
      } else if (request is _RunFutureRequest) {
        try {
          for (final (i, arg) in request.args.indexed) {
            if (arg is SyncValue) {
              arg.attachRequest(sendPort, request, i);
            }
          }
          final value = await Future.sync(() => request.func(
                args: request.args,
              ));
          _sendPort.send(request.createResultResponse(value));
        } catch (e, s) {
          _sendPort.send(request.createErrorResponse(e, s));
        }
        // List? requestedResHandles =
        //     request.resKeys?.map((e) => _resHandles[e]).toList();
        // if (requestedResHandles?.every((element) => element != null) != false) {
        // } else {
        //   _sendPort.send(request.createErrorResponse(
        //     '_RealIsolateHelper.run: Registered resource not found in isolate.',
        //     StackTrace.current,
        //   ));
        // }
      } else if (request is _RunStreamRequest) {
        try {
          _streamSubscriptions[request.key] = request
              .func(
            args: request.args,
          )
              .listen(
            (event) {
              _sendPort.send(request.createEventResponse(event));
            },
            onError: (e, s) {
              _sendPort.send(request.createErrorResponse(e, s));
            },
            onDone: () {
              _streamSubscriptions.remove(request.key);
              _sendPort.send(request.createDoneResponse());
            },
          );
        } catch (e, s) {
          _streamSubscriptions.remove(request.key);
          _sendPort.send(request.createErrorResponse(e, s));
          _sendPort.send(request.createDoneResponse());
        }
        // List? requestedResHandles =
        //     request.resKeys?.map((e) => _resHandles[e]).toList();
        // if (requestedResHandles?.every((element) => element != null) != false) {
        // } else {
        //   _sendPort.send(request.createErrorResponse(
        //     '_RealIsolateHelper.stream: Registered resource not found in isolate.',
        //     StackTrace.current,
        //   ));
        // }
      }
    }
    receivePort.close();
  }
}

// When we can't spawn an isolate, just fall back to calling the provided
// functions.
class _DummySync implements IsolateSync {
  @override
  bool get shouldOpen => true;

  @override
  Future<void> close() async {}

  @override
  Future<T> run<T>(
    FutureOr<T> Function({required List args}) func, {
    required List args,
  }) {
    return Future.sync(() => func(args: args));
  }

  @override
  Stream<T> stream<T>(
    Stream<T> Function({required List args}) func, {
    required List args,
  }) {
    return func(args: args);
  }
}

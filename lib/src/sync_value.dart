import 'dart:isolate';

import 'package:isolate_sync/isolate_sync.dart';

class SyncValue<T> {
  SyncValue(this._value);
  T _value;

  T get value => _value;

  set value(T value) {
    _syncValue(value);
    _value = value;
  }

  SendPort? _sendPort;
  SyncableRequest? _request;
  int? _index;

  void attachRequest(
    SendPort sendPort,
    SyncableRequest request,
    int index,
  ) {
    _sendPort = sendPort;
    _request = request;
    _index = index;
  }

  void sync() => _syncValue(value);

  void _syncValue(T value) {
    if (_sendPort != null && _request != null && _index != null) {
      _sendPort!.send(_request!.createSyncResponse(_index!, value));
    }
  }
}

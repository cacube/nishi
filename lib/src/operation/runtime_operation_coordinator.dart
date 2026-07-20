import 'package:flutter/foundation.dart';

final class RuntimeOperationCoordinator extends ChangeNotifier {
  String? _activeOperation;
  Object? _activeToken;

  String? get activeOperation => _activeOperation;
  bool get busy => _activeToken != null;

  RuntimeOperationLease? tryAcquire(String operation) {
    if (_activeToken != null) return null;
    final token = Object();
    _activeToken = token;
    _activeOperation = operation;
    notifyListeners();
    return RuntimeOperationLease._(this, token);
  }

  void _release(Object token) {
    if (!identical(_activeToken, token)) return;
    _activeToken = null;
    _activeOperation = null;
    notifyListeners();
  }
}

final class RuntimeOperationLease {
  RuntimeOperationLease._(this._coordinator, this._token);

  final RuntimeOperationCoordinator _coordinator;
  final Object _token;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _coordinator._release(_token);
  }
}

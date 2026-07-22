import 'package:flutter/foundation.dart';

import 'environment_component.dart';
import 'environment_scanner.dart';

class EnvironmentController extends ChangeNotifier {
  EnvironmentController({
    EnvironmentScanner scanner = const EnvironmentScanner(),
  }) : _scanner = scanner;

  final EnvironmentScanner _scanner;
  Future<void>? _scanInFlight;
  List<EnvironmentComponent> components = const [];
  bool scanning = false;
  Object? scanError;

  bool get ready =>
      components.isNotEmpty &&
      components
          .where((component) => component.required)
          .every((component) => component.status == ComponentStatus.ready);

  int get readyCount => components
      .where((component) => component.status == ComponentStatus.ready)
      .length;

  int get requiredActionCount => components
      .where(
        (component) =>
            component.required && component.status != ComponentStatus.ready,
      )
      .length;

  Future<void> scan() {
    final inFlight = _scanInFlight;
    if (inFlight != null) return inFlight;
    final scan = _performScan();
    _scanInFlight = scan;
    return scan;
  }

  Future<void> _performScan() async {
    scanning = true;
    scanError = null;
    notifyListeners();
    try {
      components = await _scanner.scan();
    } on Object catch (error) {
      scanError = error;
    } finally {
      scanning = false;
      _scanInFlight = null;
      notifyListeners();
    }
  }
}

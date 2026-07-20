import 'package:flutter/foundation.dart';

import 'environment_component.dart';
import 'environment_scanner.dart';

class EnvironmentController extends ChangeNotifier {
  EnvironmentController({
    EnvironmentScanner scanner = const EnvironmentScanner(),
  }) : _scanner = scanner;

  final EnvironmentScanner _scanner;
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

  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    scanError = null;
    notifyListeners();
    try {
      components = await _scanner.scan();
    } on Object catch (error) {
      scanError = error;
    } finally {
      scanning = false;
      notifyListeners();
    }
  }
}

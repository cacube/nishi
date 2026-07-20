import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../operation/runtime_operation_coordinator.dart';
import '../storage/runtime_layout.dart';
import 'settings_models.dart';
import 'settings_store.dart';

typedef CacheUsageReader = Future<int> Function(Directory cache);

final class SettingsController extends ChangeNotifier {
  SettingsController({
    required SettingsStore store,
    RuntimeLayout? layout,
    Future<void> Function()? repairEnvironment,
    CacheUsageReader? cacheUsageReader,
    RuntimeOperationCoordinator? operations,
    DateTime Function()? clock,
  }) : _store = store,
       _layout = layout,
       _repairEnvironment = repairEnvironment,
       _cacheUsageReader = cacheUsageReader ?? _measureDirectoryBytes,
       _operations = operations,
       _clock = clock ?? DateTime.now;

  final SettingsStore _store;
  final RuntimeLayout? _layout;
  final Future<void> Function()? _repairEnvironment;
  final CacheUsageReader _cacheUsageReader;
  final RuntimeOperationCoordinator? _operations;
  final DateTime Function() _clock;
  Future<void> _storeOperations = Future<void>.value();

  AppSettings settings = const AppSettings();
  bool loading = false;
  bool saving = false;
  String? errorMessage;
  int cacheBytes = 0;
  bool storageBusy = false;
  bool repairingEnvironment = false;

  String? get cachePath => _layout?.cache.path;
  String? get runtimesPath => _layout?.runtimes.path;
  String? get logsPath => _layout?.logs.path;

  Future<void> load() => _serializeStoreOperation(_load);

  Future<void> _load() async {
    loading = true;
    errorMessage = null;
    notifyListeners();
    try {
      settings = await _store.load();
    } on Object {
      settings = const AppSettings();
      errorMessage = '设置文件无法读取，已使用安全默认值';
    }
    try {
      await refreshCacheUsage();
    } on Object {
      cacheBytes = 0;
      errorMessage ??= '缓存使用量统计失败';
    }
    loading = false;
    notifyListeners();
  }

  Future<void> setAutoCheckUpdates(bool value) => _save(
    settings.copyWith(
      autoCheckUpdates: value,
      autoDownloadUpdates: value ? settings.autoDownloadUpdates : false,
    ),
  );

  Future<void> setAutoDownloadUpdates(bool value) => _save(
    settings.copyWith(
      autoCheckUpdates: value ? true : settings.autoCheckUpdates,
      autoDownloadUpdates: value,
    ),
  );

  Future<void> setDownloadSourcePreference(DownloadSourcePreference value) =>
      _save(settings.copyWith(downloadSourcePreference: value));

  List<Uri> orderDownloadSources(List<Uri> sources) {
    if (sources.length < 2) return List.unmodifiable(sources);
    return switch (settings.downloadSourcePreference) {
      DownloadSourcePreference.automatic => List.unmodifiable(sources),
      DownloadSourcePreference.officialOnly => List.unmodifiable([
        sources.first,
      ]),
      DownloadSourcePreference.mirrorFirst => List.unmodifiable([
        ...sources.skip(1),
        sources.first,
      ]),
    };
  }

  Future<void> refreshCacheUsage() async {
    final layout = _layout;
    if (layout == null || !await layout.cache.exists()) {
      cacheBytes = 0;
      notifyListeners();
      return;
    }
    cacheBytes = await _cacheUsageReader(layout.cache);
    notifyListeners();
  }

  Future<void> clearCache() async {
    final layout = _layout;
    if (layout == null || storageBusy) return;
    final operation = _operations?.tryAcquire('clear-cache');
    if (_operations != null && operation == null) {
      errorMessage = '另一项环境操作正在进行，请稍后重试';
      notifyListeners();
      return;
    }
    storageBusy = true;
    errorMessage = null;
    notifyListeners();
    try {
      if (await layout.cache.exists()) {
        await layout.cache.delete(recursive: true);
      }
      await layout.cache.create(recursive: true);
      cacheBytes = 0;
    } on Object {
      errorMessage = '缓存清理失败';
    } finally {
      storageBusy = false;
      operation?.release();
      notifyListeners();
    }
  }

  Future<int> removeInactiveRuntimeVersions() async {
    final layout = _layout;
    if (layout == null || storageBusy) return 0;
    final operation = _operations?.tryAcquire('remove-old-runtimes');
    if (_operations != null && operation == null) {
      errorMessage = '另一项环境操作正在进行，请稍后重试';
      notifyListeners();
      return 0;
    }
    storageBusy = true;
    errorMessage = null;
    notifyListeners();
    var removed = 0;
    try {
      final activeVersions = await layout.readActiveVersions();
      for (final active in activeVersions.entries) {
        final componentDirectory = layout.componentVersions(active.key);
        if (!await componentDirectory.exists()) continue;
        final activeDirectory = layout.componentVersion(
          active.key,
          active.value,
        );
        if (!await activeDirectory.exists()) continue;
        await for (final entity in componentDirectory.list(
          followLinks: false,
        )) {
          if (entity is! Directory) continue;
          final name = entity.uri.pathSegments
              .where((segment) => segment.isNotEmpty)
              .last;
          if (name == active.value || _isRuntimeTransactionDirectory(name)) {
            continue;
          }
          await entity.delete(recursive: true);
          removed += 1;
        }
      }
    } on Object {
      errorMessage = '旧版本清理失败';
    } finally {
      storageBusy = false;
      operation?.release();
      notifyListeners();
    }
    return removed;
  }

  Future<void> repairEnvironment() async {
    final repair = _repairEnvironment;
    if (repair == null || repairingEnvironment) return;
    final operation = _operations?.tryAcquire('repair-environment');
    if (_operations != null && operation == null) {
      errorMessage = '另一项环境操作正在进行，请稍后重试';
      notifyListeners();
      return;
    }
    repairingEnvironment = true;
    errorMessage = null;
    notifyListeners();
    try {
      await repair();
    } on Object {
      errorMessage = '环境变量修复失败';
    } finally {
      repairingEnvironment = false;
      operation?.release();
      notifyListeners();
    }
  }

  Future<File> exportDiagnostics() async {
    final layout = _layout;
    if (layout == null) {
      throw StateError('Diagnostics storage is unavailable');
    }
    await layout.logs.create(recursive: true);
    final generatedAt = _clock().toUtc();
    final stamp = generatedAt
        .toIso8601String()
        .replaceAll(RegExp(r'[-:]'), '')
        .replaceAll(RegExp(r'\.\d{3}Z$'), 'Z');
    final report = File('${layout.logs.path}/diagnostics-$stamp.json');
    final document = <String, Object?>{
      'schemaVersion': 1,
      'generatedAt': generatedAt.toIso8601String(),
      'operatingSystem': Platform.operatingSystem,
      'root': layout.root.path,
      'cacheBytes': cacheBytes,
      'activeVersions': await layout.readActiveVersions(),
      'settings': settings.toJson(),
    };
    await report.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(document)}\n',
      flush: true,
    );
    return report;
  }

  Future<void> _save(AppSettings next) =>
      _serializeStoreOperation(() => _saveNow(next));

  Future<void> _saveNow(AppSettings next) async {
    final previous = settings;
    settings = next;
    saving = true;
    errorMessage = null;
    notifyListeners();
    try {
      await _store.save(next);
    } on Object {
      settings = previous;
      errorMessage = '设置保存失败';
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> _serializeStoreOperation(Future<void> Function() operation) {
    final next = _storeOperations.then((_) => operation());
    _storeOperations = next.catchError((Object _, StackTrace _) {});
    return next;
  }
}

Future<int> _measureDirectoryBytes(Directory directory) async {
  var total = 0;
  await for (final entity in directory.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) total += await entity.length();
  }
  return total;
}

bool _isRuntimeTransactionDirectory(String name) {
  return name.endsWith('.staging') ||
      name.endsWith('.staging.assembled') ||
      name.endsWith('.backup') ||
      name.endsWith('.previous');
}

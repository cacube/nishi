import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:dev_environment_manager/src/settings/settings.dart';
import 'package:dev_environment_manager/src/operation/runtime_operation_coordinator.dart';
import 'package:dev_environment_manager/src/storage/runtime_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'settings_controller_test_',
    );
    settingsFile = File('${temporaryDirectory.path}/settings.json');
  });

  tearDown(() => temporaryDirectory.delete(recursive: true));

  test('loads safe defaults and persists user preferences', () async {
    final store = JsonSettingsStore(settingsFile);
    final controller = SettingsController(store: store);

    await controller.load();

    expect(controller.settings.autoCheckUpdates, isTrue);
    expect(controller.settings.autoDownloadUpdates, isFalse);
    expect(
      controller.settings.downloadSourcePreference,
      DownloadSourcePreference.automatic,
    );

    await controller.setAutoDownloadUpdates(true);
    await controller.setDownloadSourcePreference(
      DownloadSourcePreference.mirrorFirst,
    );

    final reloaded = SettingsController(store: store);
    await reloaded.load();
    expect(reloaded.settings.autoDownloadUpdates, isTrue);
    expect(
      reloaded.settings.downloadSourcePreference,
      DownloadSourcePreference.mirrorFirst,
    );
  });

  test('restores settings from the last known good backup', () async {
    final backup = File('${settingsFile.path}.backup');
    await backup.writeAsString(
      '${jsonEncode(const AppSettings(autoDownloadUpdates: true, downloadSourcePreference: DownloadSourcePreference.mirrorFirst).toJson())}\n',
    );
    final store = JsonSettingsStore(settingsFile);

    final loaded = await store.load();

    expect(loaded.autoDownloadUpdates, isTrue);
    expect(
      loaded.downloadSourcePreference,
      DownloadSourcePreference.mirrorFirst,
    );
    expect(await settingsFile.exists(), isTrue);
    expect(await backup.exists(), isFalse);
  });

  test('cache measurement failure does not reset loaded settings', () async {
    final store = JsonSettingsStore(settingsFile);
    await store.save(
      const AppSettings(
        autoDownloadUpdates: true,
        downloadSourcePreference: DownloadSourcePreference.officialOnly,
      ),
    );
    final layout = RuntimeLayout.forCurrentUser(
      environment: {'HOME': temporaryDirectory.path},
      operatingSystem: HostOperatingSystem.macos,
    );
    await layout.ensureCreated();
    final controller = SettingsController(
      store: store,
      layout: layout,
      cacheUsageReader: (_) async =>
          throw const FileSystemException('cache is temporarily unavailable'),
    );

    await controller.load();

    expect(controller.settings.autoDownloadUpdates, isTrue);
    expect(
      controller.settings.downloadSourcePreference,
      DownloadSourcePreference.officialOnly,
    );
    expect(controller.errorMessage, '缓存使用量统计失败');
  });

  test('serializes refresh behind an in-flight settings save', () async {
    final store = _BlockingSettingsStore();
    final controller = SettingsController(store: store);

    final save = controller.setAutoDownloadUpdates(true);
    await store.saveStarted.future;
    final load = controller.load();
    await Future<void>.delayed(Duration.zero);

    expect(store.events, ['save-start']);

    store.allowSave.complete();
    await Future.wait([save, load]);

    expect(store.events, ['save-start', 'save-end', 'load']);
    expect(controller.settings.autoDownloadUpdates, isTrue);
  });

  test('orders signed sources according to the selected policy', () async {
    final controller = SettingsController(
      store: MemorySettingsStore(
        const AppSettings(
          downloadSourcePreference: DownloadSourcePreference.mirrorFirst,
        ),
      ),
    );
    await controller.load();
    final official = Uri.parse('https://official.example/runtime.zip');
    final mirror = Uri.parse('https://mirror.example/runtime.zip');

    expect(controller.orderDownloadSources([official, mirror]), [
      mirror,
      official,
    ]);

    await controller.setDownloadSourcePreference(
      DownloadSourcePreference.officialOnly,
    );
    expect(controller.orderDownloadSources([official, mirror]), [official]);
  });

  test(
    'keeps automatic download and update checks in a valid combination',
    () async {
      final controller = SettingsController(store: MemorySettingsStore());

      await controller.setAutoCheckUpdates(false);
      await controller.setAutoDownloadUpdates(true);

      expect(controller.settings.autoCheckUpdates, isTrue);
      expect(controller.settings.autoDownloadUpdates, isTrue);

      await controller.setAutoCheckUpdates(false);

      expect(controller.settings.autoCheckUpdates, isFalse);
      expect(controller.settings.autoDownloadUpdates, isFalse);
    },
  );

  test('measures and clears cache without touching managed runtimes', () async {
    final layout = RuntimeLayout.forCurrentUser(
      environment: {'HOME': temporaryDirectory.path},
      operatingSystem: HostOperatingSystem.macos,
    );
    await layout.ensureCreated();
    await File('${layout.cache.path}/artifact.zip').writeAsString('hello');
    final runtime = File(
      '${layout.componentVersion('go', '1.0.0').path}/bin/go',
    );
    await runtime.parent.create(recursive: true);
    await runtime.writeAsString('runtime');
    final controller = SettingsController(
      store: MemorySettingsStore(),
      layout: layout,
    );

    await controller.load();
    expect(controller.cacheBytes, 5);

    await controller.clearCache();

    expect(controller.cacheBytes, 0);
    expect(await layout.cache.exists(), isTrue);
    expect(await runtime.exists(), isTrue);
  });

  test(
    'does not clear cache while another runtime operation owns the lock',
    () async {
      final layout = RuntimeLayout.forCurrentUser(
        environment: {'HOME': temporaryDirectory.path},
        operatingSystem: HostOperatingSystem.macos,
      );
      await layout.ensureCreated();
      final artifact = File('${layout.cache.path}/artifact.zip');
      await artifact.writeAsString('verified');
      final operations = RuntimeOperationCoordinator();
      final lease = operations.tryAcquire('configure-environment')!;
      final controller = SettingsController(
        store: MemorySettingsStore(),
        layout: layout,
        operations: operations,
      );
      addTearDown(controller.dispose);
      addTearDown(operations.dispose);

      await controller.clearCache();

      expect(await artifact.exists(), isTrue);
      expect(controller.errorMessage, contains('另一项环境操作'));
      lease.release();
    },
  );

  test('removes only inactive managed runtime versions', () async {
    final layout = RuntimeLayout.forCurrentUser(
      environment: {'HOME': temporaryDirectory.path},
      operatingSystem: HostOperatingSystem.macos,
    );
    await layout.ensureCreated();
    final oldVersion = layout.componentVersion('go', '1.0.0');
    final activeVersion = layout.componentVersion('go', '1.1.0');
    await oldVersion.create(recursive: true);
    await activeVersion.create(recursive: true);
    await layout.recordActiveVersion('go', '1.1.0');
    final controller = SettingsController(
      store: MemorySettingsStore(),
      layout: layout,
    );

    final removed = await controller.removeInactiveRuntimeVersions();

    expect(removed, 1);
    expect(await oldVersion.exists(), isFalse);
    expect(await activeVersion.exists(), isTrue);
  });

  test(
    'does not remove versions when the recorded active version is missing',
    () async {
      final layout = RuntimeLayout.forCurrentUser(
        environment: {'HOME': temporaryDirectory.path},
        operatingSystem: HostOperatingSystem.macos,
      );
      await layout.ensureCreated();
      final lastUsableVersion = layout.componentVersion('go', '1.0.0');
      await lastUsableVersion.create(recursive: true);
      await layout.recordActiveVersion('go', '1.1.0');
      final controller = SettingsController(
        store: MemorySettingsStore(),
        layout: layout,
      );

      final removed = await controller.removeInactiveRuntimeVersions();

      expect(removed, 0);
      expect(await lastUsableVersion.exists(), isTrue);
    },
  );

  test(
    'keeps installer transaction directories during old-version cleanup',
    () async {
      final layout = RuntimeLayout.forCurrentUser(
        environment: {'HOME': temporaryDirectory.path},
        operatingSystem: HostOperatingSystem.macos,
      );
      await layout.ensureCreated();
      final activeVersion = layout.componentVersion('go', '1.1.0');
      final inactiveVersion = layout.componentVersion('go', '1.0.0');
      final staging = layout.componentStaging('go', '1.2.0');
      final assembled = Directory('${staging.path}.assembled');
      final backup = Directory(
        '${layout.componentVersion('go', '1.2.0').path}.backup',
      );
      final previous = Directory(
        '${layout.componentVersion('go', '1.2.0').path}.previous',
      );
      for (final directory in [
        activeVersion,
        inactiveVersion,
        staging,
        assembled,
        backup,
        previous,
      ]) {
        await directory.create(recursive: true);
      }
      await layout.recordActiveVersion('go', '1.1.0');
      final controller = SettingsController(
        store: MemorySettingsStore(),
        layout: layout,
      );

      final removed = await controller.removeInactiveRuntimeVersions();

      expect(removed, 1);
      expect(await inactiveVersion.exists(), isFalse);
      expect(await staging.exists(), isTrue);
      expect(await assembled.exists(), isTrue);
      expect(await backup.exists(), isTrue);
      expect(await previous.exists(), isTrue);
    },
  );

  test(
    'exports a diagnostics report without modifying the environment',
    () async {
      final layout = RuntimeLayout.forCurrentUser(
        environment: {'HOME': temporaryDirectory.path},
        operatingSystem: HostOperatingSystem.macos,
      );
      await layout.ensureCreated();
      await layout.recordActiveVersion('flutter', '3.44.6');
      final controller = SettingsController(
        store: MemorySettingsStore(),
        layout: layout,
        clock: () => DateTime.utc(2026, 7, 21, 9),
      );
      await controller.load();

      final report = await controller.exportDiagnostics();
      final document = jsonDecode(await report.readAsString()) as Map;

      expect(document['generatedAt'], '2026-07-21T09:00:00.000Z');
      expect((document['activeVersions'] as Map)['flutter'], '3.44.6');
      expect(report.parent.path, layout.logs.path);
    },
  );
}

final class _BlockingSettingsStore implements SettingsStore {
  final saveStarted = Completer<void>();
  final allowSave = Completer<void>();
  final events = <String>[];
  AppSettings settings = const AppSettings();

  @override
  Future<AppSettings> load() async {
    events.add('load');
    return settings;
  }

  @override
  Future<void> save(AppSettings settings) async {
    events.add('save-start');
    saveStarted.complete();
    await allowSave.future;
    this.settings = settings;
    events.add('save-end');
  }
}

import 'dart:convert';
import 'dart:io';

import 'settings_models.dart';

abstract interface class SettingsStore {
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}

final class JsonSettingsStore implements SettingsStore {
  const JsonSettingsStore(this.file);

  final File file;

  @override
  Future<AppSettings> load() async {
    final backup = File('${file.path}.backup');
    if (!await file.exists()) {
      if (!await backup.exists()) return const AppSettings();
      final recovered = await _readSettings(backup);
      await file.parent.create(recursive: true);
      await backup.rename(file.path);
      return recovered;
    }
    try {
      return await _readSettings(file);
    } on FormatException {
      if (!await backup.exists()) rethrow;
      final recovered = await _readSettings(backup);
      await file.delete();
      await backup.rename(file.path);
      return recovered;
    }
  }

  Future<AppSettings> _readSettings(File source) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(await source.readAsString());
    } on FormatException catch (error) {
      throw FormatException('Settings JSON is invalid: ${error.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Settings must be a JSON object');
    }
    return AppSettings.fromJson(decoded);
  }

  @override
  Future<void> save(AppSettings settings) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.backup');
    if (await temporary.exists()) await temporary.delete();
    await temporary.writeAsString(
      '${jsonEncode(settings.toJson())}\n',
      flush: true,
    );
    final hadExisting = await file.exists();
    if (hadExisting) {
      if (await backup.exists()) await backup.delete();
      await file.rename(backup.path);
    }
    try {
      await temporary.rename(file.path);
    } on Object {
      if (await temporary.exists()) await temporary.delete();
      if (hadExisting && await backup.exists() && !await file.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
    try {
      if (await backup.exists()) await backup.delete();
    } on FileSystemException {
      // The new primary is committed. A stale backup is safe to remove later.
    }
  }
}

final class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this.settings = const AppSettings()]);

  AppSettings settings;

  @override
  Future<AppSettings> load() async => settings;

  @override
  Future<void> save(AppSettings settings) async {
    this.settings = settings;
  }
}

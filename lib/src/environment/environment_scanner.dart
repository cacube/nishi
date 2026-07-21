import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../compatibility/compatibility_requirement.dart';
import '../compatibility/gin_vue_admin_compatibility.dart';
import '../compatibility/service_probe.dart';
import '../compatibility/software_version.dart';
import '../compatibility/version_output_parser.dart';
import '../storage/runtime_layout.dart';
import 'environment_component.dart';

class EnvironmentScanner {
  const EnvironmentScanner({this.layout, this.baseEnvironment});

  final RuntimeLayout? layout;
  final Map<String, String>? baseEnvironment;

  Future<List<EnvironmentComponent>> scan() async {
    final definitions = _definitions();
    return Future.wait(definitions.map(_scanComponent));
  }

  List<EnvironmentComponent> _definitions() {
    return [
      _component(
        'flutter',
        'Flutter SDK',
        ComponentGroup.flutter,
        Icons.flutter_dash,
      ),
      _component('java', 'JDK', ComponentGroup.flutter, Icons.coffee),
      _component(
        'android',
        'Android SDK',
        ComponentGroup.flutter,
        Icons.android,
      ),
      _component('browser', 'Web 浏览器', ComponentGroup.flutter, Icons.language),
      if (Platform.isMacOS)
        _component(
          'xcode',
          'Xcode',
          ComponentGroup.flutter,
          Icons.developer_mode,
          required: false,
        ),
      if (Platform.isWindows)
        _component(
          'windows-build-tools',
          'Windows 构建工具',
          ComponentGroup.flutter,
          Icons.desktop_windows,
        ),
      _component('go', 'Go', ComponentGroup.server, Icons.code),
      _component('node', 'Node.js', ComponentGroup.server, Icons.javascript),
      _component(
        'npm',
        'npm',
        ComponentGroup.server,
        Icons.inventory_2_outlined,
      ),
      _component('mysql', 'MySQL', ComponentGroup.services, Icons.storage),
      _component(
        'redis',
        'Redis',
        ComponentGroup.services,
        Icons.memory,
        required: false,
      ),
      _component(
        'git',
        'Git',
        ComponentGroup.tools,
        Icons.account_tree_outlined,
      ),
      _component(
        'codex',
        'Codex',
        ComponentGroup.tools,
        Icons.auto_awesome_outlined,
      ),
    ];
  }

  EnvironmentComponent _component(
    String id,
    String name,
    ComponentGroup group,
    IconData icon, {
    bool required = true,
  }) {
    return EnvironmentComponent(
      id: id,
      name: name,
      group: group,
      icon: icon,
      required: required,
      status: ComponentStatus.checking,
    );
  }

  Future<EnvironmentComponent> _scanComponent(
    EnvironmentComponent component,
  ) async {
    try {
      return await switch (component.id) {
        'flutter' => _versionedCommand(component, 'flutter', [
          '--version',
        ], SoftwareComponent.flutter),
        'java' => _java(component),
        'android' => _android(component),
        'browser' => _browser(component),
        'xcode' => _versionedCommand(component, 'xcodebuild', [
          '-version',
        ], SoftwareComponent.xcode),
        'windows-build-tools' => _windowsBuildTools(component),
        'go' => _versionedCommand(
          component,
          'go',
          ['version'],
          SoftwareComponent.go,
          minimum: ginVueAdminMinimumGoVersion,
        ),
        'node' => _node(component),
        'npm' => _versionedCommand(
          component,
          'npm',
          ['--version'],
          SoftwareComponent.npm,
          minimum: '9.0.0',
        ),
        'mysql' => _mysql(component),
        'redis' => _redis(component),
        'git' => _versionedCommand(component, 'git', [
          '--version',
        ], SoftwareComponent.git),
        'codex' => _codex(component),
        _ => Future.value(_missing(component)),
      };
    } on Object catch (error) {
      return _missing(component, detail: error.toString());
    }
  }

  Future<EnvironmentComponent> _command(
    EnvironmentComponent component,
    String executable,
    List<String> arguments,
  ) async {
    final result = await Process.run(
      executable,
      arguments,
      environment: commandEnvironment(),
      runInShell: Platform.isWindows,
    ).timeout(const Duration(seconds: 8));
    if (result.exitCode != 0) return _missing(component);
    final output = '${result.stdout}\n${result.stderr}'.trim();
    return component.copyWith(
      status: ComponentStatus.ready,
      version: _firstUsefulLine(output),
    );
  }

  Future<EnvironmentComponent> _versionedCommand(
    EnvironmentComponent component,
    String executable,
    List<String> arguments,
    SoftwareComponent software, {
    String? minimum,
  }) async {
    final result = await _command(component, executable, arguments);
    if (result.status != ComponentStatus.ready) return result;
    final installed = const VersionOutputParser().extract(
      software,
      result.version ?? '',
    );
    if (installed == null) {
      return result.copyWith(
        status: minimum == null
            ? ComponentStatus.ready
            : ComponentStatus.attention,
        detail: minimum == null ? null : '无法确认版本兼容性',
      );
    }
    if (minimum == null) return result.copyWith(version: installed.toString());

    final requirement = CompatibilityRequirement(
      minimumVersion: SoftwareVersion.parse(minimum),
    );
    return switch (requirement.evaluate(installed)) {
      CompatibilityStatus.compatible => result.copyWith(
        version: installed.toString(),
      ),
      CompatibilityStatus.outdated => result.copyWith(
        status: ComponentStatus.attention,
        version: installed.toString(),
        detail: '版本过低，需要 $minimum 或更高版本',
      ),
      CompatibilityStatus.unknown => result.copyWith(
        status: ComponentStatus.attention,
        detail: '无法确认版本兼容性',
      ),
    };
  }

  Future<EnvironmentComponent> _android(EnvironmentComponent component) async {
    final sdkRoot =
        Platform.environment['ANDROID_SDK_ROOT'] ??
        Platform.environment['ANDROID_HOME'];
    final adb = await _command(component, 'adb', ['version']);
    if (adb.status == ComponentStatus.ready) return adb;
    if (sdkRoot != null && Directory(sdkRoot).existsSync()) {
      return component.copyWith(
        status: ComponentStatus.attention,
        version: sdkRoot,
        detail: 'SDK 已找到，platform-tools 不可用',
      );
    }
    return _missing(component);
  }

  Future<EnvironmentComponent> _node(EnvironmentComponent component) async {
    final result = await _versionedCommand(component, 'node', [
      '--version',
    ], SoftwareComponent.node);
    if (result.status != ComponentStatus.ready) return result;
    final installed = const VersionOutputParser().extract(
      SoftwareComponent.node,
      result.version ?? '',
    );
    if (installed != null && ginVueAdminNodeIsCompatible(installed)) {
      return result;
    }
    return result.copyWith(
      status: ComponentStatus.attention,
      detail: '版本不兼容，需要 20.19.x 或 22.12.0 以上版本',
    );
  }

  Future<EnvironmentComponent> _java(EnvironmentComponent component) async {
    final fromPath = await _versionedCommand(
      component,
      'java',
      ['-version'],
      SoftwareComponent.java,
      minimum: '17.0.0',
    );
    if (fromPath.status == ComponentStatus.ready) return fromPath;

    final candidates = Platform.isMacOS
        ? const [
            '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java',
          ]
        : <String>[
            if (Platform.environment['PROGRAMFILES'] case final root?)
              '$root\\Android\\Android Studio\\jbr\\bin\\java.exe',
          ];
    for (final executable in candidates) {
      if (File(executable).existsSync()) {
        return _versionedCommand(
          component,
          executable,
          ['-version'],
          SoftwareComponent.java,
          minimum: '17.0.0',
        );
      }
    }
    return fromPath;
  }

  Future<EnvironmentComponent> _browser(EnvironmentComponent component) async {
    if (Platform.isMacOS) {
      const chrome = '/Applications/Google Chrome.app';
      if (Directory(chrome).existsSync()) {
        return component.copyWith(
          status: ComponentStatus.ready,
          version: 'Google Chrome',
        );
      }
    }
    if (Platform.isWindows) {
      final programFiles = Platform.environment['PROGRAMFILES'];
      if (programFiles != null) {
        final edge = File(
          '$programFiles\\Microsoft\\Edge\\Application\\msedge.exe',
        );
        if (edge.existsSync()) {
          return component.copyWith(
            status: ComponentStatus.ready,
            version: 'Microsoft Edge',
          );
        }
      }
    }
    return _missing(component);
  }

  Future<EnvironmentComponent> _mysql(EnvironmentComponent component) async {
    final runtime = await _versionedCommand(
      component,
      'mysql',
      ['--version'],
      SoftwareComponent.mysql,
      minimum: '5.7.0',
    );
    if (runtime.status != ComponentStatus.ready) return runtime;
    final probe = await TcpServiceProbe().probe(const MySqlHandshakeProtocol());
    return runtime.copyWith(
      status: probe.identified
          ? ComponentStatus.ready
          : ComponentStatus.attention,
      detail: probe.identified ? '服务运行中' : '已安装，${probe.message}',
    );
  }

  Future<EnvironmentComponent> _redis(EnvironmentComponent component) async {
    var runtime = await _versionedCommand(
      component,
      'redis-server',
      ['--version'],
      SoftwareComponent.redis,
      minimum: '6.0.6',
    );
    if (runtime.status != ComponentStatus.ready && Platform.isWindows) {
      runtime = await _command(component, 'memurai', ['--version']);
    }
    if (runtime.status != ComponentStatus.ready) return runtime;
    final probe = await TcpServiceProbe().probe(const RedisPingProtocol());
    return runtime.copyWith(
      status: probe.identified
          ? ComponentStatus.ready
          : ComponentStatus.attention,
      detail: probe.identified ? '服务运行中' : '已安装，${probe.message}',
    );
  }

  Future<EnvironmentComponent> _codex(EnvironmentComponent component) async {
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '';
      final apps = [
        '/Applications/Codex.app',
        '/Applications/ChatGPT.app',
        '$home/Applications/Codex.app',
        '$home/Applications/ChatGPT.app',
      ];
      for (final app in apps) {
        if (Directory(app).existsSync()) {
          return component.copyWith(
            status: ComponentStatus.ready,
            version: app.endsWith('ChatGPT.app')
                ? 'Codex (ChatGPT)'
                : 'Codex.app',
          );
        }
      }
    }
    return _command(component, 'codex', ['--version']);
  }

  Future<EnvironmentComponent> _windowsBuildTools(
    EnvironmentComponent component,
  ) async {
    final programFiles = Platform.environment['PROGRAMFILES(X86)'];
    if (programFiles == null) return _missing(component);
    final vswhere = File(
      '$programFiles\\Microsoft Visual Studio\\Installer\\vswhere.exe',
    );
    if (!vswhere.existsSync()) return _missing(component);
    return _command(component, vswhere.path, [
      '-latest',
      '-requires',
      'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
      '-property',
      'catalog_productDisplayVersion',
    ]);
  }

  EnvironmentComponent _missing(
    EnvironmentComponent component, {
    String? detail,
  }) {
    return component.copyWith(
      status: ComponentStatus.missing,
      detail: detail ?? '未安装',
    );
  }

  String _firstUsefulLine(String output) {
    return output
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '已安装');
  }

  Map<String, String> commandEnvironment() {
    final inherited = baseEnvironment ?? Platform.environment;
    final home = inherited['HOME'] ?? '';
    final existing = inherited['PATH'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    final fallbackExtras = Platform.isWindows
        ? <String>[]
        : [
            '$home/sdk/flutter/bin',
            '$home/sdk/android/platform-tools',
            '/opt/homebrew/bin',
            '/usr/local/bin',
            '/usr/bin',
            '/bin',
          ];
    final variables = <String, String>{};
    final managedExtras = <String>[];
    final runtimeLayout = layout;
    if (runtimeLayout != null) {
      final versions = runtimeLayout.readActiveVersionsSync();
      String? rootFor(String id) {
        final version = versions[id];
        return version == null
            ? null
            : runtimeLayout.componentVersion(id, version).path;
      }

      final flutterRoot = rootFor('flutter');
      final jdkRoot = rootFor('jdk');
      final androidRoot = rootFor('android-sdk');
      final goRoot = rootFor('go');
      final nodeRoot = rootFor('node');
      final mysqlRoot = rootFor('mysql');
      if (flutterRoot != null) {
        variables['FLUTTER_ROOT'] = flutterRoot;
        managedExtras.add(_joinPath(flutterRoot, 'bin'));
      }
      if (jdkRoot != null) {
        variables['JAVA_HOME'] = jdkRoot;
        managedExtras.add(_joinPath(jdkRoot, 'bin'));
      }
      if (androidRoot != null) {
        variables['ANDROID_SDK_ROOT'] = androidRoot;
        variables['ANDROID_HOME'] = androidRoot;
        managedExtras.addAll([
          _joinPath(androidRoot, 'platform-tools'),
          _joinPath(androidRoot, 'cmdline-tools', 'latest', 'bin'),
        ]);
      }
      if (goRoot != null) {
        variables['GOROOT'] = goRoot;
        managedExtras.add(_joinPath(goRoot, 'bin'));
      }
      if (nodeRoot != null) {
        variables['NODE_HOME'] = nodeRoot;
        managedExtras.add(
          Platform.isWindows ? nodeRoot : _joinPath(nodeRoot, 'bin'),
        );
      }
      if (mysqlRoot != null) {
        variables['MYSQL_HOME'] = mysqlRoot;
        managedExtras.add(_joinPath(mysqlRoot, 'bin'));
      }
    }
    return {
      ...inherited,
      ...variables,
      'PATH': [
        ...managedExtras,
        ...fallbackExtras,
        existing,
      ].where((path) => path.isNotEmpty).join(separator),
    };
  }
}

String _joinPath(String root, String first, [String? second, String? third]) {
  final parts = [root, first, ?second, ?third];
  return parts.join(Platform.pathSeparator);
}

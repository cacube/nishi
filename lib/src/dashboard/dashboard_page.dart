import 'dart:io';

import 'package:flutter/material.dart';

import '../app_brand.dart';
import '../environment/environment_component.dart';
import '../environment/environment_controller.dart';
import '../install/artifact_installer.dart';
import '../settings/settings.dart';
import '../setup/setup_task.dart';
import '../setup_ui/setup_composition.dart';
import '../setup_ui/setup_ui_controller.dart';
import '../update/update.dart';

enum _DashboardSection { environment, updates, settings }

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, this.composition});

  final SetupComposition? composition;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final SetupComposition _composition;
  late final bool _ownsComposition;
  _DashboardSection _section = _DashboardSection.environment;

  @override
  void initState() {
    super.initState();
    _ownsComposition = widget.composition == null;
    _composition = widget.composition ?? SetupComposition.forCurrentUser();
    _composition.environment.addListener(_onChanged);
    _composition.setup.addListener(_onChanged);
    _composition.settings.addListener(_onChanged);
    _composition.updates.addListener(_onChanged);
    _composition.operations.addListener(_onChanged);
    _initialize();
  }

  Future<void> _initialize() async {
    await _composition.settings.load();
    await _composition.environment.scan();
    if (_composition.settings.settings.autoCheckUpdates) {
      await _checkUpdates();
    }
  }

  Future<void> _checkUpdates() async {
    await _composition.updates.check();
    if (_composition.settings.settings.autoDownloadUpdates) {
      await _composition.updates.downloadAvailableUpdates(
        includeNotInstalled: false,
      );
    }
  }

  @override
  void dispose() {
    _composition.environment.removeListener(_onChanged);
    _composition.setup.removeListener(_onChanged);
    _composition.settings.removeListener(_onChanged);
    _composition.updates.removeListener(_onChanged);
    _composition.operations.removeListener(_onChanged);
    if (_ownsComposition) _composition.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _selectSection(_DashboardSection section) {
    if (_section == section) return;
    setState(() => _section = section);
    if (section == _DashboardSection.updates &&
        _composition.updates.state.entries.isEmpty &&
        !_composition.updates.state.checking) {
      _checkUpdates();
    }
  }

  Future<void> _refresh() => switch (_section) {
    _DashboardSection.environment => _composition.environment.scan(),
    _DashboardSection.updates => _checkUpdates(),
    _DashboardSection.settings => _composition.settings.load(),
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            _NavigationRail(
              scanning:
                  _composition.environment.scanning ||
                  _composition.updates.state.checking ||
                  _composition.settings.loading ||
                  _composition.operations.busy,
              selected: _section,
              onSelected: _selectSection,
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  _TopBar(
                    title: switch (_section) {
                      _DashboardSection.environment => '开发环境',
                      _DashboardSection.updates => '更新中心',
                      _DashboardSection.settings => '设置',
                    },
                    scanning: switch (_section) {
                      _DashboardSection.environment =>
                        _composition.environment.scanning,
                      _DashboardSection.updates =>
                        _composition.updates.state.checking,
                      _DashboardSection.settings =>
                        _composition.settings.loading,
                    },
                    onRefresh: _refresh,
                  ),
                  const Divider(),
                  Expanded(
                    child: switch (_section) {
                      _DashboardSection.environment => _DashboardBody(
                        controller: _composition.environment,
                        setup: _composition.setup,
                        onOpenUpdates: () =>
                            _selectSection(_DashboardSection.updates),
                        runtimeBusy: _composition.operations.busy,
                      ),
                      _DashboardSection.updates => _UpdateBody(
                        controller: _composition.updates,
                        setup: _composition.setup,
                        onCheck: _checkUpdates,
                        runtimeBusy: _composition.operations.busy,
                      ),
                      _DashboardSection.settings => _SettingsBody(
                        controller: _composition.settings,
                        environment: _composition.environment,
                        runtimeBusy: _composition.operations.busy,
                      ),
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavigationRail extends StatelessWidget {
  const _NavigationRail({
    required this.scanning,
    required this.selected,
    required this.onSelected,
  });

  final bool scanning;
  final _DashboardSection selected;
  final ValueChanged<_DashboardSection> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 84,
      child: Column(
        children: [
          const SizedBox(height: 18),
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.terminal, color: Colors.white),
          ),
          const SizedBox(height: 28),
          _NavItem(
            icon: Icons.dashboard_outlined,
            label: '环境',
            selected: selected == _DashboardSection.environment,
            onTap: () => onSelected(_DashboardSection.environment),
          ),
          _NavItem(
            icon: Icons.system_update_alt,
            label: '更新',
            selected: selected == _DashboardSection.updates,
            onTap: () => onSelected(_DashboardSection.updates),
          ),
          const Spacer(),
          if (scanning)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          const SizedBox(height: 20),
          _NavItem(
            icon: Icons.settings_outlined,
            label: '设置',
            selected: selected == _DashboardSection.settings,
            onTap: () => onSelected(_DashboardSection.settings),
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    this.selected = false,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? Theme.of(context).colorScheme.primary
        : const Color(0xFF687069);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 84,
          height: 58,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 21, color: color),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontSize: 11, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.scanning,
    required this.onRefresh,
  });

  final String title;
  final bool scanning;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Row(
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            IconButton(
              tooltip: '重新检测',
              onPressed: scanning ? null : onRefresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpdateBody extends StatelessWidget {
  const _UpdateBody({
    required this.controller,
    required this.setup,
    required this.onCheck,
    required this.runtimeBusy,
  });

  final UpdateController controller;
  final SetupUiController setup;
  final Future<void> Function() onCheck;
  final bool runtimeBusy;

  bool get _setupBusy =>
      runtimeBusy ||
      controller.state.downloading ||
      switch (setup.state.phase) {
        SetupUiPhase.preparing ||
        SetupUiPhase.running ||
        SetupUiPhase.cancelling ||
        SetupUiPhase.awaitingPreflight ||
        SetupUiPhase.awaitingUser => true,
        _ => false,
      };

  Future<void> _update(Set<String> componentIds) async {
    await setup.startSelected(componentIds);
    if (setup.state.phase == SetupUiPhase.completed) {
      await controller.check();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final available = state.availableUpdates;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: const Color(0xFFE1E4DF)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: available.isEmpty
                            ? const Color(0xFF19734B)
                            : const Color(0xFF176B5B),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        available.isEmpty ? Icons.check : Icons.system_update,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '组件更新',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            state.downloading
                                ? '正在下载更新包'
                                : state.checking
                                ? '正在检查签名清单'
                                : available.isEmpty
                                ? '所有托管组件均为目标版本'
                                : '${available.length} 个组件可安装或更新',
                            style: const TextStyle(color: Color(0xFF687069)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    OutlinedButton.icon(
                      onPressed: state.checking ? null : onCheck,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重新检查'),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: available.isEmpty || _setupBusy
                          ? null
                          : controller.downloadAvailableUpdates,
                      icon: const Icon(Icons.cloud_download_outlined),
                      label: const Text('下载更新包'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: available.isEmpty || _setupBusy
                          ? null
                          : () => _update(
                              available
                                  .map((entry) => entry.componentId)
                                  .toSet(),
                            ),
                      icon: const Icon(Icons.download),
                      label: const Text('更新全部'),
                    ),
                  ],
                ),
              ),
              if (state.errorMessage case final error?) ...[
                const SizedBox(height: 12),
                Text(error, style: const TextStyle(color: Color(0xFFB43B32))),
              ],
              if (state.downloadErrorMessage case final error?) ...[
                const SizedBox(height: 12),
                Text(error, style: const TextStyle(color: Color(0xFFB43B32))),
              ],
              if (state.downloadCancelled) ...[
                const SizedBox(height: 12),
                const Text(
                  '更新包下载已取消，可随时重新下载',
                  style: TextStyle(color: Color(0xFF687069)),
                ),
              ],
              if (state.downloading) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: state.downloadProgress.clamp(0, 1),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton(
                      tooltip: '取消下载',
                      onPressed: controller.cancelDownload,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ],
              if (setup.state.phase != SetupUiPhase.idle) ...[
                const SizedBox(height: 16),
                _SetupProgressPanel(setup: setup),
              ],
              const SizedBox(height: 20),
              if (state.checking && state.entries.isEmpty)
                const SizedBox(
                  height: 220,
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Card(
                  child: Column(
                    children: [
                      for (
                        var index = 0;
                        index < state.entries.length;
                        index++
                      ) ...[
                        _UpdateRow(
                          entry: state.entries[index],
                          busy: _setupBusy,
                          onUpdate: () =>
                              _update({state.entries[index].componentId}),
                        ),
                        if (index != state.entries.length - 1)
                          const Divider(indent: 18, endIndent: 18),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: 20),
              _SettingsSection(
                title: '$applicationName 软件',
                icon: Icons.apps,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('私用构建'),
                    subtitle: const Text('软件安装包更新通过 GitHub Releases 获取'),
                    trailing: OutlinedButton.icon(
                      onPressed: () => _openExternal(
                        context,
                        'https://github.com/cacube/nishi/releases/latest',
                      ),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('查看新版'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UpdateRow extends StatelessWidget {
  const _UpdateRow({
    required this.entry,
    required this.busy,
    required this.onUpdate,
  });

  final RuntimeUpdateEntry entry;
  final bool busy;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (entry.status) {
      RuntimeUpdateStatus.current => ('最新', const Color(0xFF19734B)),
      RuntimeUpdateStatus.updateAvailable => ('可更新', const Color(0xFF9A5B00)),
      RuntimeUpdateStatus.notInstalled => ('未安装', const Color(0xFF687069)),
      RuntimeUpdateStatus.newerThanTarget => ('版本较新', const Color(0xFF176B5B)),
    };
    return SizedBox(
      height: 72,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: [
            SizedBox(
              width: 210,
              child: Text(
                entry.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(
              child: Text(
                '${entry.currentVersion ?? '未安装'}  →  ${entry.targetVersion}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF687069)),
              ),
            ),
            Container(
              width: 68,
              alignment: Alignment.center,
              child: Text(label, style: TextStyle(fontSize: 12, color: color)),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 88,
              child:
                  entry.status == RuntimeUpdateStatus.current ||
                      entry.status == RuntimeUpdateStatus.newerThanTarget
                  ? const SizedBox.shrink()
                  : OutlinedButton(
                      onPressed: busy ? null : onUpdate,
                      child: Text(
                        entry.status == RuntimeUpdateStatus.notInstalled
                            ? '安装'
                            : '更新',
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsBody extends StatelessWidget {
  const _SettingsBody({
    required this.controller,
    required this.environment,
    required this.runtimeBusy,
  });

  final SettingsController controller;
  final EnvironmentController environment;
  final bool runtimeBusy;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (controller.errorMessage case final error?) ...[
                Text(error, style: const TextStyle(color: Color(0xFFB43B32))),
                const SizedBox(height: 12),
              ],
              _SettingsSection(
                title: '更新设置',
                icon: Icons.update,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启动时检查组件更新'),
                    value: settings.autoCheckUpdates,
                    onChanged: controller.saving
                        ? null
                        : controller.setAutoCheckUpdates,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动下载更新包'),
                    subtitle: const Text('仅预下载已安装组件的新版本，不会自动安装'),
                    value: settings.autoDownloadUpdates,
                    onChanged: controller.saving
                        ? null
                        : controller.setAutoDownloadUpdates,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SettingsSection(
                title: '下载源',
                icon: Icons.cloud_download_outlined,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SegmentedButton<DownloadSourcePreference>(
                      segments: const [
                        ButtonSegment(
                          value: DownloadSourcePreference.automatic,
                          icon: Icon(Icons.auto_awesome),
                          label: Text('自动'),
                        ),
                        ButtonSegment(
                          value: DownloadSourcePreference.officialOnly,
                          icon: Icon(Icons.public),
                          label: Text('仅官网'),
                        ),
                        ButtonSegment(
                          value: DownloadSourcePreference.mirrorFirst,
                          icon: Icon(Icons.speed),
                          label: Text('国内优先'),
                        ),
                      ],
                      selected: {settings.downloadSourcePreference},
                      onSelectionChanged: controller.saving
                          ? null
                          : (selected) => controller
                                .setDownloadSourcePreference(selected.single),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SettingsSection(
                title: '缓存与存储',
                icon: Icons.folder_outlined,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('下载缓存'),
                    subtitle: Text(_formatBytes(controller.cacheBytes)),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        IconButton(
                          tooltip: '打开缓存目录',
                          onPressed: controller.cachePath == null
                              ? null
                              : () => _openDirectory(
                                  context,
                                  controller.cachePath!,
                                ),
                          icon: const Icon(Icons.folder_open),
                        ),
                        OutlinedButton.icon(
                          onPressed: controller.storageBusy || runtimeBusy
                              ? null
                              : controller.clearCache,
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('清理缓存'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('托管运行时'),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        IconButton(
                          tooltip: '打开运行时目录',
                          onPressed: controller.runtimesPath == null
                              ? null
                              : () => _openDirectory(
                                  context,
                                  controller.runtimesPath!,
                                ),
                          icon: const Icon(Icons.folder_open),
                        ),
                        OutlinedButton.icon(
                          onPressed: controller.storageBusy || runtimeBusy
                              ? null
                              : () async {
                                  final removed = await controller
                                      .removeInactiveRuntimeVersions();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('已清理 $removed 个旧版本'),
                                      ),
                                    );
                                  }
                                },
                          icon: const Icon(Icons.cleaning_services_outlined),
                          label: const Text('清理旧版本'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SettingsSection(
                title: '环境与诊断',
                icon: Icons.build_outlined,
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed:
                            controller.repairingEnvironment || runtimeBusy
                            ? null
                            : controller.repairEnvironment,
                        icon: const Icon(Icons.handyman_outlined),
                        label: Text(
                          controller.repairingEnvironment ? '正在修复' : '修复环境变量',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: environment.scanning
                            ? null
                            : environment.scan,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重新检测'),
                      ),
                      OutlinedButton.icon(
                        onPressed: controller.logsPath == null
                            ? null
                            : () =>
                                  _openDirectory(context, controller.logsPath!),
                        icon: const Icon(Icons.article_outlined),
                        label: const Text('打开日志'),
                      ),
                      OutlinedButton.icon(
                        onPressed: controller.logsPath == null
                            ? null
                            : () async {
                                final report = await controller
                                    .exportDiagnostics();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('诊断报告已生成：${report.path}'),
                                    ),
                                  );
                                }
                              },
                        icon: const Icon(Icons.ios_share_outlined),
                        label: const Text('导出诊断'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SettingsSection(
                title: '安全',
                icon: Icons.verified_user_outlined,
                children: const [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('运行时清单签名'),
                    subtitle: Text('Ed25519 · nishi-release-2026-01'),
                    trailing: Icon(Icons.verified, color: Color(0xFF19734B)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Color(0xFFE1E4DF)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 19, color: const Color(0xFF176B5B)),
                const SizedBox(width: 9),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody({
    required this.controller,
    required this.setup,
    required this.onOpenUpdates,
    required this.runtimeBusy,
  });

  final EnvironmentController controller;
  final SetupUiController setup;
  final VoidCallback onOpenUpdates;
  final bool runtimeBusy;

  @override
  Widget build(BuildContext context) {
    if (controller.components.isEmpty && controller.scanning) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = constraints.maxWidth >= 980;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ReadinessBand(
                    controller: controller,
                    setup: setup,
                    onOpenUpdates: onOpenUpdates,
                    runtimeBusy: runtimeBusy,
                  ),
                  if (setup.state.phase != SetupUiPhase.idle) ...[
                    const SizedBox(height: 16),
                    _SetupProgressPanel(setup: setup),
                  ],
                  const SizedBox(height: 24),
                  if (horizontal)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _GroupColumn(
                            controller: controller,
                            groups: const [
                              ComponentGroup.flutter,
                              ComponentGroup.tools,
                            ],
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: _GroupColumn(
                            controller: controller,
                            groups: const [
                              ComponentGroup.server,
                              ComponentGroup.services,
                            ],
                          ),
                        ),
                      ],
                    )
                  else
                    _GroupColumn(
                      controller: controller,
                      groups: ComponentGroup.values,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ReadinessBand extends StatelessWidget {
  const _ReadinessBand({
    required this.controller,
    required this.setup,
    required this.onOpenUpdates,
    required this.runtimeBusy,
  });

  final EnvironmentController controller;
  final SetupUiController setup;
  final VoidCallback onOpenUpdates;
  final bool runtimeBusy;

  @override
  Widget build(BuildContext context) {
    final ready = controller.ready;
    final color = ready ? const Color(0xFF19734B) : const Color(0xFF9A5B00);
    final total = controller.components.length;
    final progress = total == 0 ? 0.0 : controller.readyCount / total;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: ready ? const Color(0xFFEDF7F1) : const Color(0xFFFFF6E8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: ready ? const Color(0xFFC8E3D2) : const Color(0xFFF0D5A7),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              ready ? Icons.check : Icons.build_outlined,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ready ? '环境已准备' : '环境需要配置',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  ready
                      ? '$total 个组件均可用'
                      : '${controller.requiredActionCount} 个必需组件需要处理',
                  style: const TextStyle(color: Color(0xFF5D655F)),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    value: progress,
                    color: color,
                    backgroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          _SetupCommand(
            setup: setup,
            ready: ready,
            onOpenUpdates: onOpenUpdates,
            runtimeBusy: runtimeBusy,
          ),
        ],
      ),
    );
  }
}

class _SetupCommand extends StatelessWidget {
  const _SetupCommand({
    required this.setup,
    required this.ready,
    required this.onOpenUpdates,
    required this.runtimeBusy,
  });

  final SetupUiController setup;
  final bool ready;
  final VoidCallback onOpenUpdates;
  final bool runtimeBusy;

  @override
  Widget build(BuildContext context) {
    final phase = setup.state.phase;
    return switch (phase) {
      SetupUiPhase.preparing ||
      SetupUiPhase.running ||
      SetupUiPhase.cancelling => OutlinedButton.icon(
        onPressed: phase == SetupUiPhase.cancelling ? null : setup.cancel,
        icon: const Icon(Icons.close),
        label: Text(phase == SetupUiPhase.cancelling ? '正在取消' : '取消'),
      ),
      SetupUiPhase.failed => FilledButton.icon(
        onPressed: setup.retry,
        icon: const Icon(Icons.refresh),
        label: const Text('重试失败项'),
      ),
      SetupUiPhase.awaitingPreflight ||
      SetupUiPhase.awaitingUser => OutlinedButton.icon(
        onPressed: setup.cancel,
        icon: const Icon(Icons.close),
        label: const Text('取消'),
      ),
      _ => FilledButton.icon(
        onPressed: runtimeBusy ? null : (ready ? onOpenUpdates : setup.start),
        icon: Icon(ready ? Icons.system_update_alt : Icons.download),
        label: Text(ready ? '检查更新' : '一键配置'),
      ),
    };
  }
}

class _SetupProgressPanel extends StatelessWidget {
  const _SetupProgressPanel({required this.setup});

  final SetupUiController setup;

  @override
  Widget build(BuildContext context) {
    final state = setup.state;
    final title = switch (state.phase) {
      SetupUiPhase.preparing => '正在获取安装清单',
      SetupUiPhase.awaitingPreflight => '需要许可确认',
      SetupUiPhase.running => '正在配置开发环境',
      SetupUiPhase.cancelling => '正在取消',
      SetupUiPhase.awaitingUser => '等待系统安装确认',
      SetupUiPhase.failed => '部分组件配置失败',
      SetupUiPhase.cancelled => '配置已取消',
      SetupUiPhase.completed => '配置已完成',
      SetupUiPhase.idle => '开发环境配置',
    };

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE1E4DF)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${(state.progress * 100).round()}%',
                style: const TextStyle(fontSize: 13, color: Color(0xFF5D655F)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: state.progress.clamp(0, 1)),
          if (state.errorMessage case final error?) ...[
            const SizedBox(height: 12),
            Text(error, style: const TextStyle(color: Color(0xFFB43B32))),
          ],
          if (state.phase == SetupUiPhase.awaitingPreflight) ...[
            const SizedBox(height: 14),
            _PreflightPanel(setup: setup),
          ],
          if (state.phase == SetupUiPhase.awaitingUser) ...[
            const SizedBox(height: 14),
            _UserActionPanel(setup: setup),
          ],
          if (state.tasks.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Divider(),
            for (final task in state.tasks) _SetupTaskRow(task: task),
          ],
        ],
      ),
    );
  }
}

class _PreflightPanel extends StatefulWidget {
  const _PreflightPanel({required this.setup});

  final SetupUiController setup;

  @override
  State<_PreflightPanel> createState() => _PreflightPanelState();
}

class _PreflightPanelState extends State<_PreflightPanel> {
  final Set<String> _accepted = {};

  @override
  Widget build(BuildContext context) {
    final confirmations = widget.setup.state.pendingPreflight;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final confirmation in confirmations)
          Material(
            color: Colors.transparent,
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _accepted.contains(confirmation.id),
              onChanged: (selected) {
                setState(() {
                  if (selected ?? false) {
                    _accepted.add(confirmation.id);
                  } else {
                    _accepted.remove(confirmation.id);
                  }
                });
              },
              title: Text(confirmation.title),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(confirmation.description),
                  if (confirmation.termsUrl case final url?)
                    TextButton.icon(
                      onPressed: () => _openExternal(context, url),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('查看条款'),
                    ),
                ],
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _accepted.length == confirmations.length
                ? () => widget.setup.confirmPreflight(_accepted)
                : null,
            icon: const Icon(Icons.check),
            label: const Text('同意并继续'),
          ),
        ),
      ],
    );
  }
}

class _UserActionPanel extends StatelessWidget {
  const _UserActionPanel({required this.setup});

  final SetupUiController setup;

  @override
  Widget build(BuildContext context) {
    final tasks = setup.state.tasks.where(
      (task) => task.status == SetupTaskStatus.awaitingUser,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final task in tasks)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(task.label),
                if (task.userActionRequest case final InstallerCommand command)
                  OutlinedButton.icon(
                    onPressed: () => _launchInstaller(context, command),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('打开安装程序'),
                  ),
                FilledButton.icon(
                  onPressed: () => setup.continueAfterUserAction(task.id),
                  icon: const Icon(Icons.check),
                  label: const Text('已完成，继续'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SetupTaskRow extends StatelessWidget {
  const _SetupTaskRow({required this.task});

  final SetupUiTaskState task;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (task.status) {
      SetupTaskStatus.succeeded => (
        Icons.check_circle,
        const Color(0xFF19734B),
      ),
      SetupTaskStatus.failed => (Icons.error, const Color(0xFFB43B32)),
      SetupTaskStatus.cancelled => (Icons.cancel, const Color(0xFF687069)),
      SetupTaskStatus.awaitingUser => (
        Icons.lock_open,
        const Color(0xFF9A5B00),
      ),
      SetupTaskStatus.running => (Icons.downloading, const Color(0xFF176B5B)),
      SetupTaskStatus.blocked => (Icons.pause_circle, const Color(0xFF9A5B00)),
      SetupTaskStatus.pending => (Icons.schedule, const Color(0xFF687069)),
    };
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          SizedBox(
            width: 180,
            child: Text(task.label, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: task.status == SetupTaskStatus.running
                ? LinearProgressIndicator(value: task.progress.clamp(0, 1))
                : Text(
                    task.message ?? _taskStatusLabel(task.status),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF687069),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

String _taskStatusLabel(SetupTaskStatus status) => switch (status) {
  SetupTaskStatus.pending => '等待中',
  SetupTaskStatus.running => '进行中',
  SetupTaskStatus.awaitingUser => '等待确认',
  SetupTaskStatus.succeeded => '已完成',
  SetupTaskStatus.failed => '失败',
  SetupTaskStatus.blocked => '依赖未完成',
  SetupTaskStatus.cancelled => '已取消',
};

Future<void> _openExternal(BuildContext context, String url) async {
  try {
    if (Platform.isMacOS) {
      await Process.start('open', [url]);
    } else if (Platform.isWindows) {
      await Process.start('rundll32.exe', [
        'url.dll,FileProtocolHandler',
        url,
      ], runInShell: true);
    }
  } on Object {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开链接')));
    }
  }
}

Future<void> _openDirectory(BuildContext context, String path) async {
  try {
    if (Platform.isMacOS) {
      await Process.start('open', [path]);
    } else if (Platform.isWindows) {
      await Process.start('explorer.exe', [path], runInShell: true);
    }
  } on Object {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开目录')));
    }
  }
}

Future<void> _launchInstaller(
  BuildContext context,
  InstallerCommand command,
) async {
  try {
    await Process.start(
      command.executable,
      command.arguments,
      runInShell: Platform.isWindows,
    );
  } on Object {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开安装程序')));
    }
  }
}

class _GroupColumn extends StatelessWidget {
  const _GroupColumn({required this.controller, required this.groups});

  final EnvironmentController controller;
  final Iterable<ComponentGroup> groups;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final group in groups) ...[
          _ComponentGroup(
            group: group,
            components: controller.components
                .where((component) => component.group == group)
                .toList(),
          ),
          const SizedBox(height: 18),
        ],
      ],
    );
  }
}

class _ComponentGroup extends StatelessWidget {
  const _ComponentGroup({required this.group, required this.components});

  final ComponentGroup group;
  final List<EnvironmentComponent> components;

  String get title => switch (group) {
    ComponentGroup.flutter => 'Flutter 与平台',
    ComponentGroup.server => 'Gin-Vue-Admin',
    ComponentGroup.services => '基础服务',
    ComponentGroup.tools => '开发工具',
  };

  @override
  Widget build(BuildContext context) {
    if (components.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
            child: Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          const Divider(),
          for (var index = 0; index < components.length; index++) ...[
            _ComponentRow(component: components[index]),
            if (index != components.length - 1) const Divider(indent: 58),
          ],
        ],
      ),
    );
  }
}

class _ComponentRow extends StatelessWidget {
  const _ComponentRow({required this.component});

  final EnvironmentComponent component;

  @override
  Widget build(BuildContext context) {
    final (statusIcon, statusColor, statusText) = switch (component.status) {
      ComponentStatus.checking => (
        Icons.more_horiz,
        const Color(0xFF687069),
        '检测中',
      ),
      ComponentStatus.ready => (
        Icons.check_circle,
        const Color(0xFF19734B),
        '可用',
      ),
      ComponentStatus.missing => (Icons.cancel, const Color(0xFFB43B32), '未安装'),
      ComponentStatus.attention => (
        Icons.warning_amber_rounded,
        const Color(0xFF9A5B00),
        '需处理',
      ),
    };

    return SizedBox(
      height: 68,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Icon(
                component.icon,
                size: 20,
                color: const Color(0xFF343A36),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    component.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    component.detail ?? component.version ?? '等待检测',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF717872),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(statusIcon, size: 17, color: statusColor),
            const SizedBox(width: 5),
            SizedBox(
              width: 44,
              child: Text(
                statusText,
                style: TextStyle(fontSize: 12, color: statusColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

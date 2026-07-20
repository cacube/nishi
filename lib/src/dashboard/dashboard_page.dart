import 'dart:io';

import 'package:flutter/material.dart';

import '../environment/environment_component.dart';
import '../environment/environment_controller.dart';
import '../install/artifact_installer.dart';
import '../setup/setup_task.dart';
import '../setup_ui/setup_composition.dart';
import '../setup_ui/setup_ui_controller.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, this.composition});

  final SetupComposition? composition;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final SetupComposition _composition;
  late final bool _ownsComposition;

  @override
  void initState() {
    super.initState();
    _ownsComposition = widget.composition == null;
    _composition = widget.composition ?? SetupComposition.forCurrentUser();
    _composition.environment.addListener(_onChanged);
    _composition.setup.addListener(_onChanged);
    _composition.environment.scan();
  }

  @override
  void dispose() {
    _composition.environment.removeListener(_onChanged);
    _composition.setup.removeListener(_onChanged);
    if (_ownsComposition) _composition.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            _NavigationRail(scanning: _composition.environment.scanning),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  _TopBar(
                    scanning: _composition.environment.scanning,
                    onRefresh: _composition.environment.scan,
                  ),
                  const Divider(),
                  Expanded(
                    child: _DashboardBody(
                      controller: _composition.environment,
                      setup: _composition.setup,
                    ),
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
  const _NavigationRail({required this.scanning});

  final bool scanning;

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
          const _NavItem(
            icon: Icons.dashboard_outlined,
            label: '环境',
            selected: true,
          ),
          const _NavItem(icon: Icons.system_update_alt, label: '更新'),
          const Spacer(),
          if (scanning)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          const SizedBox(height: 20),
          const _NavItem(icon: Icons.settings_outlined, label: '设置'),
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
  });

  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? Theme.of(context).colorScheme.primary
        : const Color(0xFF687069);
    return SizedBox(
      height: 58,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 21, color: color),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.scanning, required this.onRefresh});

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
            const Text(
              '开发环境',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
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

class _DashboardBody extends StatelessWidget {
  const _DashboardBody({required this.controller, required this.setup});

  final EnvironmentController controller;
  final SetupUiController setup;

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
                  _ReadinessBand(controller: controller, setup: setup),
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
  const _ReadinessBand({required this.controller, required this.setup});

  final EnvironmentController controller;
  final SetupUiController setup;

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
          _SetupCommand(setup: setup, ready: ready),
        ],
      ),
    );
  }
}

class _SetupCommand extends StatelessWidget {
  const _SetupCommand({required this.setup, required this.ready});

  final SetupUiController setup;
  final bool ready;

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
      SetupUiPhase.awaitingUser => const SizedBox(width: 120),
      _ => FilledButton.icon(
        onPressed: setup.start,
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

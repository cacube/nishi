import 'package:flutter/material.dart';

import '../environment/environment_component.dart';
import '../environment/environment_controller.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final EnvironmentController _controller;

  @override
  void initState() {
    super.initState();
    _controller = EnvironmentController()..addListener(_onChanged);
    _controller.scan();
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onChanged)
      ..dispose();
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
            _NavigationRail(scanning: _controller.scanning),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  _TopBar(
                    scanning: _controller.scanning,
                    onRefresh: _controller.scan,
                  ),
                  const Divider(),
                  Expanded(child: _DashboardBody(controller: _controller)),
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
  const _DashboardBody({required this.controller});

  final EnvironmentController controller;

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
                  _ReadinessBand(controller: controller),
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
  const _ReadinessBand({required this.controller});

  final EnvironmentController controller;

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
        ],
      ),
    );
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

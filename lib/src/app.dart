import 'package:flutter/material.dart';

import 'dashboard/dashboard_page.dart';

class DevEnvironmentApp extends StatelessWidget {
  const DevEnvironmentApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF176B5B);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      surface: const Color(0xFFF7F8F6),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '开发环境',
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
        useMaterial3: true,
        fontFamilyFallback: const ['PingFang SC', 'Microsoft YaHei'],
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: BorderSide(color: Color(0xFFE1E4DF)),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFE1E4DF),
          space: 1,
        ),
      ),
      home: const DashboardPage(),
    );
  }
}

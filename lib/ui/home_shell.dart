import 'package:flutter/material.dart';

import '../tracker/controller.dart';
import 'dashboard_page.dart';
import 'log_page.dart';
import 'settings_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller, this.initialTab = 0});
  final TrackerController controller;
  final int initialTab;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _tab = widget.initialTab;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final m = widget.controller.takeMessage();
    if (m != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        title: Row(children: [
          Image.asset(dark ? 'assets/images/logo_dark.png' : 'assets/images/logo.png', height: 26),
          const SizedBox(width: 12),
          Container(width: 1, height: 22, color: Theme.of(context).dividerColor),
          const SizedBox(width: 12),
          Text('J16 Simulator',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        ]),
      ),
      body: IndexedStack(index: _tab, children: [
        DashboardPage(controller: c),
        SettingsPage(controller: c),
        LogPage(controller: c),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.speed_outlined), selectedIcon: Icon(Icons.speed), label: 'Painel'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Configurações'),
          NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Log'),
        ],
      ),
    );
  }
}

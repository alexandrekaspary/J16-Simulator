import 'package:flutter/material.dart';

import 'tracker/controller.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = TrackerController();
  runApp(J16App(controller: controller));
  controller.init();
}

class J16App extends StatelessWidget {
  const J16App({super.key, required this.controller});
  final TrackerController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'J16 Simulator',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: HomeShell(controller: controller),
      );
}

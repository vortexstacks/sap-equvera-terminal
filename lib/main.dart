import 'package:flutter/material.dart';

import 'connect_screen.dart';

void main() {
  runApp(const SapTerminalApp());
}

class SapTerminalApp extends StatelessWidget {
  const SapTerminalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SAP Terminal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF33FF33), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
      ),
      home: const ConnectScreen(),
    );
  }
}

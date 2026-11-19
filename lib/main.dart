import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'services/device_store.dart';
import 'services/discovery_service.dart';
import 'services/health_service.dart';

const jezailRed = Color(0xFFE53935);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = DeviceStore();
  await store.load();
  // Fold duplicates persisted by older builds (scan vs broadcast entries
  // for the same box) before first paint, and persist the cleaned state.
  store.reconcile();
  await store.save();
  final discovery = DiscoveryService();
  final pollSeconds = await store.loadPollSeconds(30);
  final health = HealthService(store: store, discovery: discovery, pollSeconds: pollSeconds);
  runApp(JezailConsoleApp(store: store, discovery: discovery, health: health));
}

class JezailConsoleApp extends StatelessWidget {
  final DeviceStore store;
  final DiscoveryService discovery;
  final HealthService health;

  const JezailConsoleApp({
    super.key,
    required this.store,
    required this.discovery,
    required this.health,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jezail Console',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: jezailRed, brightness: Brightness.light),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: jezailRed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.dark,
      home: HomePage(store: store, discovery: discovery, health: health),
    );
  }
}

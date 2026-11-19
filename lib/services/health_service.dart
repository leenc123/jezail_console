import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/device.dart';
import 'device_store.dart';
import 'discovery_service.dart';

/// Periodically probes every known device and keeps the UI fresh.
/// Designed for small fleets (<100): one parallel sweep per interval,
/// guarded against overlapping runs.
class HealthService extends ChangeNotifier {
  final DeviceStore store;
  final DiscoveryService discovery;

  int pollSeconds;
  Timer? _timer;
  bool _busy = false;

  HealthService({
    required this.store,
    required this.discovery,
    this.pollSeconds = 30,
  });

  bool get running => _timer != null;

  void start() {
    stop();
    _timer = Timer.periodic(Duration(seconds: pollSeconds), (_) => refreshAll());
    refreshAll();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void restart({int? pollSeconds}) {
    if (pollSeconds != null) this.pollSeconds = pollSeconds;
    if (running) start();
  }

  Future<void> refreshAll() async {
    if (_busy) return;
    _busy = true;
    try {
      await Future.wait(store.devices.map(check));
      await store.save();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> check(JezailDevice dev) async {
    dev.lastCheck = DateTime.now();
    try {
      final found = await discovery.probeHost(
        dev.host,
        dev.port,
        // Known id: skip the extra UDP round-trip per cycle.
        resolveId: dev.id.isEmpty,
      );
      if (found == null) {
        dev.online = false;
        dev.lastError = 'unreachable';
        return;
      }
      dev.updateFromDiscovery(found);
      // The box may now share its stable id with a second entry (IP change,
      // multi-home, legacy dupes): fold id-twins back into one.
      // Synchronous, so no interleaving hazard with parallel checks.
      store.reconcile();
    } catch (e) {
      dev.online = false;
      dev.lastError = e.toString();
    }
  }
}

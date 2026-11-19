import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';

/// Known-device inventory persisted locally as JSON.
class DeviceStore {
  static const String _kDevices = 'jezail.devices.v1';
  static const String _kSubnets = 'jezail.subnets.v1';
  static const String _kPorts = 'jezail.ports.v1';
  static const String _kPollSeconds = 'jezail.poll_seconds.v1';

  final Map<String, JezailDevice> _devices = {};

  List<JezailDevice> get devices => _devices.values.toList()
    ..sort((a, b) {
      // Online first, then by display name.
      if (a.online != b.online) return a.online ? -1 : 1;
      return a.displayName.compareTo(b.displayName);
    });

  JezailDevice? byKey(String key) => _devices[key];

  /// Lookup by network endpoint, regardless of stable-id state.
  /// Scan/manual probes start with an empty id (keyed host:port) while
  /// broadcasts carry the stable ANDROID_ID — same box, different keys.
  JezailDevice? byEndpoint(String host, int port) {
    for (final d in _devices.values) {
      if (d.host == host && d.port == port) return d;
    }
    return null;
  }

  /// Insert or merge a discovered device. Known entries keep user edits.
  /// Falls back to endpoint matching so a broadcast reply merges into the
  /// earlier scan/manual entry for the same box instead of duplicating it.
  void upsert(JezailDevice dev, {bool preserveUserFields = true}) {
    final existing = _devices[dev.key] ??
        (dev.host.isNotEmpty ? byEndpoint(dev.host, dev.port) : null);
    if (existing == null) {
      _devices[dev.key] = dev;
      return;
    }
    final alias = preserveUserFields ? existing.alias : dev.alias;
    final oldKey = existing.key;
    existing.updateFromDiscovery(dev);
    if (preserveUserFields) existing.alias = alias;
    // The key may have changed (empty id -> stable id): re-index.
    final newKey = existing.key;
    if (oldKey != newKey) _devices.remove(oldKey);
    _devices[newKey] = existing;
  }

  /// Fold entries that describe the same box into one.
  ///
  /// Same non-empty id always merges (covers IP change, multi-homed boxes,
  /// and ids adopted later via [JezailDevice.updateFromDiscovery]). Same
  /// endpoint merges when at least one side still lacks a stable id — those
  /// are legacy duplicates persisted before endpoint-aware upsert existed,
  /// or boxes whose UDP reply never arrives (firewalled) so the id stays
  /// unknown. Entries for genuinely different boxes are never merged:
  /// different endpoints with different known ids stay separate.
  /// Fully synchronous, safe to call from health checks between awaits.
  void reconcile() {
    final all = _devices.values.toList();
    _devices.clear();
    for (final d in all) {
      JezailDevice? match;
      if (d.id.isNotEmpty) match = _devices[d.key];
      match ??= d.host.isNotEmpty ? byEndpoint(d.host, d.port) : null;
      if (match == null) {
        _devices[d.key] = d;
        continue;
      }
      final oldKey =
          _devices.entries.firstWhere((e) => identical(e.value, match)).key;
      _absorb(match, d);
      _devices.remove(oldKey);
      _devices[match.key] = match;
    }
  }

  /// Fold [other] into [base]. User edits (alias) and liveness survive;
  /// fresher network facts win.
  void _absorb(JezailDevice base, JezailDevice other) {
    if (base.id.isEmpty && other.id.isNotEmpty) base.id = other.id;
    final otherNewer = other.lastSeen != null &&
        (base.lastSeen == null || !other.lastSeen!.isBefore(base.lastSeen!));
    if (other.host.isNotEmpty && (base.host.isEmpty || otherNewer)) {
      base.host = other.host;
      base.port = other.port;
    }
    if (other.name.isNotEmpty && (base.name.isEmpty || otherNewer)) {
      base.name = other.name;
    }
    if (other.manufacturer.isNotEmpty && (base.manufacturer.isEmpty || otherNewer)) {
      base.manufacturer = other.manufacturer;
    }
    if (other.model.isNotEmpty && (base.model.isEmpty || otherNewer)) {
      base.model = other.model;
    }
    if (other.androidVersion.isNotEmpty && (base.androidVersion.isEmpty || otherNewer)) {
      base.androidVersion = other.androidVersion;
    }
    if (other.sdk != 0) base.sdk = other.sdk;
    base.auth = base.auth || other.auth;
    base.root = base.root || other.root;
    if (other.appVersion.isNotEmpty && (base.appVersion.isEmpty || otherNewer)) {
      base.appVersion = other.appVersion;
    }
    if (base.alias?.isNotEmpty != true) base.alias = other.alias;
    base.online = base.online || other.online;
    if (base.lastSeen == null ||
        (other.lastSeen != null && other.lastSeen!.isAfter(base.lastSeen!))) {
      base.lastSeen = other.lastSeen;
    }
    base.lastError ??= other.lastError;
    if (other.lastCheck != null &&
        (base.lastCheck == null || other.lastCheck!.isAfter(base.lastCheck!))) {
      base.lastCheck = other.lastCheck;
    }
  }

  bool remove(String key) => _devices.remove(key) != null;

  void setAlias(String key, String alias) {
    final d = _devices[key];
    if (d != null) d.alias = alias;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _devices.clear();
    final raw = prefs.getString(_kDevices);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = json.decode(raw);
      if (list is List) {
        for (final item in list) {
          if (item is Map) {
            final dev = JezailDevice.fromJson(Map<String, dynamic>.from(item));
            if (dev.host.isNotEmpty) _devices[dev.key] = dev;
          }
        }
      }
    } catch (_) {
      // Corrupt cache must never break startup.
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _devices.values.map((d) => d.toJson()).toList();
    await prefs.setString(_kDevices, json.encode(list));
  }

  // ---- settings ----

  Future<List<String>> loadSubnets(List<String> fallback) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSubnets);
    if (raw == null || raw.isEmpty) return fallback;
    try {
      final list = json.decode(raw);
      if (list is List) {
        final out = list.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
        if (out.isNotEmpty) return out;
      }
    } catch (_) {}
    return fallback;
  }

  Future<void> saveSubnets(List<String> subnets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSubnets, json.encode(subnets));
  }

  Future<List<int>> loadPorts(List<int> fallback) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPorts);
    if (raw == null || raw.isEmpty) return fallback;
    try {
      final list = json.decode(raw);
      if (list is List) {
        final out = <int>[];
        for (final e in list) {
          final p = e is int ? e : int.tryParse(e.toString());
          if (p != null && p > 0 && p < 65536) out.add(p);
        }
        if (out.isNotEmpty) return out;
      }
    } catch (_) {}
    return fallback;
  }

  Future<void> savePorts(List<int> ports) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPorts, json.encode(ports));
  }

  Future<int> loadPollSeconds(int fallback) async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_kPollSeconds);
    if (v == null || v < 5 || v > 3600) return fallback;
    return v;
  }

  Future<void> savePollSeconds(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPollSeconds, seconds);
  }
}

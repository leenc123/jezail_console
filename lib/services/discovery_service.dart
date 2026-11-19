import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/device.dart';

/// LAN discovery for jezail devices.
///
/// Three ways in (broadcast / subnet scan / manual) share one verification
/// primitive: a candidate (host, port) box is accepted only when
/// `GET /api/status` answers with a jezail-shaped payload.
class DiscoveryService {
  /// Magic probe every jezail device with the discovery responder answers.
  static const String kMagic = 'JEZAIL_DISCOVER_V1';

  /// UDP port the jezail app listens on for discovery probes.
  static const int kDiscoveryPort = 8090;

  /// Broadcast [kMagic] on every IPv4 interface and collect replies.
  ///
  /// Each reply must be the JSON `jezail-hello` object; entries are
  /// de-duplicated by stable device id.
  Future<List<JezailDevice>> broadcastDiscover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final found = <String, JezailDevice>{};
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;

    final targets = await _broadcastAddresses();
    final payload = utf8.encode(kMagic);
    for (final target in targets) {
      try {
        socket.send(payload, target, kDiscoveryPort);
      } catch (_) {
        // One bad interface must not kill the whole sweep.
      }
    }

    final deadline = DateTime.now().add(timeout);
    await for (final event in socket.timeout(
      timeout,
      onTimeout: (sink) => sink.close(),
    )) {
      if (DateTime.now().isAfter(deadline)) break;
      if (event == RawSocketEvent.read) {
        final dg = socket.receive();
        if (dg == null) continue;
        final dev = _parseReply(dg);
        if (dev != null) found[dev.key] = dev;
      }
    }
    socket.close();
    return found.values.toList();
  }

  /// Ask one host directly for its stable id via a unicast discovery probe.
  ///
  /// HTTP-only probes can never learn the id (`GET /api/device` carries no
  /// androidId), so scan/manual entries start id-less and would duplicate
  /// the broadcast entry for the same box. One cheap UDP round-trip fixes
  /// that. Returns null when the box stays silent over UDP (firewalled etc.)
  /// — callers must keep working with endpoint-only identity then.
  Future<String?> resolveStableId(
    String host, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(utf8.encode(kMagic), InternetAddress(host), kDiscoveryPort);
      final completer = Completer<String?>();
      Timer(timeout, () {
        if (!completer.isCompleted) completer.complete(null);
      });
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read || completer.isCompleted) return;
        Datagram? dg;
        while ((dg = socket?.receive()) != null) {
          final got = dg;
          // Unicast target: only accept the answer from that host.
          if (got == null || got.address.address != host) continue;
          final dev = _parseReply(got);
          if (dev != null && dev.id.isNotEmpty && !completer.isCompleted) {
            completer.complete(dev.id);
          }
        }
      });
      final id = await completer.future;
      await sub.cancel();
      return id;
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }

  /// Probe a single host:port, used by manual add and (later) subnet scan.
  ///
  /// Returns a [JezailDevice] when the box answers like jezail, else null.
  /// When [probeApi] is true (default), enrich with /api/device fields.
  /// When [resolveId] is true (default), follow up with a unicast discovery
  /// ping so the result carries the stable id and merges with broadcast
  /// entries instead of duplicating them. Pass false when the caller
  /// already knows the id (health re-checks) to skip the extra round-trip.
  Future<JezailDevice?> probeHost(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 2),
    bool probeApi = true,
    bool resolveId = true,
  }) async {
    // Fast path first: is anything even listening?
    try {
      final sock = await Socket.connect(host, port, timeout: timeout);
      sock.destroy();
    } catch (_) {
      return null;
    }

    try {
      final statusUri = Uri(scheme: 'http', host: host, port: port, path: '/api/status');
      final statusRes = await http.get(statusUri).timeout(timeout);
      if (statusRes.statusCode != 200) return null;
      final statusBody = json.decode(statusRes.body);
      if (statusBody is! Map || statusBody['data'] is! Map) return null;
      if ((statusBody['data'] as Map)['status']?.toString() != 'ok') return null;

      final dev = JezailDevice(id: '', host: host, port: port, source: 'scan', online: true);
      if (probeApi) {
        await _enrichFromApi(dev, timeout);
        if (resolveId) {
          final stableId = await resolveStableId(host);
          if (stableId != null && stableId.isNotEmpty) dev.id = stableId;
        }
      } else {
        dev.lastSeen = DateTime.now();
      }
      return dev;
    } catch (_) {
      return null;
    }
  }

  /// Fill model/manufacturer/root/etc. from GET /api/device.
  Future<void> enrich(JezailDevice dev, {Duration timeout = const Duration(seconds: 5)}) =>
      _enrichFromApi(dev, timeout);

  Future<void> _enrichFromApi(JezailDevice dev, Duration timeout) async {
    try {
      final uri = Uri(scheme: 'http', host: dev.host, port: dev.port, path: '/api/device');
      final res = await http.get(uri).timeout(timeout);
      // /api/device sits behind the PIN gate when auth is on (/api/status
      // stays open): a 401 still proves "this is a jezail box, gated".
      if (res.statusCode == 401) {
        dev.auth = true;
        dev.online = true;
        dev.lastSeen = DateTime.now();
        dev.lastError = null;
        return;
      }
      if (res.statusCode != 200) return;
      final body = json.decode(res.body);
      if (body is! Map || body['data'] is! Map) return;
      final data = body['data'] as Map;
      String s(Object? v) => v?.toString() ?? '';
      final name = s(data['deviceName']);
      if (name.isNotEmpty) dev.name = name;
      final manu = s(data['manufacturer']);
      if (manu.isNotEmpty) dev.manufacturer = manu;
      final model = s(data['model']);
      if (model.isNotEmpty) dev.model = model;
      final ver = s(data['androidVersion']);
      if (ver.isNotEmpty) dev.androidVersion = ver;
      final sdk = data['sdkInt'];
      if (sdk is int) dev.sdk = sdk;
      if (data['isRooted'] is bool) dev.root = data['isRooted'] as bool;
      dev.online = true;
      dev.lastSeen = DateTime.now();
      dev.lastError = null;
    } catch (e) {
      dev.lastError = e.toString();
    }
  }

  JezailDevice? _parseReply(Datagram dg) {
    try {
      final body = json.decode(utf8.decode(dg.data));
      if (body is! Map) return null;
      if (body['type'] != 'jezail-hello') return null;
      return JezailDevice.fromDiscovery(Map<String, dynamic>.from(body), dg.address.address, 8080);
    } catch (_) {
      return null;
    }
  }

  /// Local /24 CIDRs derived from this machine's own IPv4 addresses.
  /// Used as the default scan range when the user configured none.
  Future<List<String>> localSubnets() async {
    final out = <String>{};
    try {
      final ifs = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      for (final nic in ifs) {
        for (final addr in nic.addresses) {
          if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) continue;
          final raw = addr.rawAddress;
          if (raw.length != 4) continue;
          out.add('${raw[0]}.${raw[1]}.${raw[2]}.0/24');
        }
      }
    } catch (_) {}
    return out.toList();
  }

  /// Cancellation flag for a running subnet scan.
  bool _scanCancelled = false;
  void cancelScan() => _scanCancelled = true;

  /// Result events streamed during a subnet scan.
  Stream<ScanProgress> scanSubnets({
    required List<String> subnets,
    required List<int> ports,
    Duration timeout = const Duration(milliseconds: 800),
    int concurrency = 64,
  }) async* {
    _scanCancelled = false;
    final targets = <_Target>[];
    for (final cidr in subnets) {
      targets.addAll(_expandCidr(cidr.trim(), ports));
      if (targets.length > 4096) break;
    }
    final total = targets.length;
    var scanned = 0;
    if (total == 0) {
      yield const ScanProgress(done: true, scanned: 0, total: 0);
      return;
    }
    for (var i = 0; i < targets.length; i += concurrency) {
      if (_scanCancelled) {
        yield ScanProgress(done: true, scanned: scanned, total: total, cancelled: true);
        return;
      }
      final batch = targets.skip(i).take(concurrency);
      final results = await Future.wait(batch.map((t) => _probeTarget(t, timeout)));
      for (final dev in results) {
        scanned++;
        if (dev != null) {
          yield ScanProgress(done: false, scanned: scanned, total: total, found: dev);
        }
      }
      yield ScanProgress(done: false, scanned: scanned, total: total);
    }
    yield ScanProgress(done: true, scanned: scanned, total: total);
  }

  Future<JezailDevice?> _probeTarget(_Target t, Duration timeout) async {
    try {
      final sock = await Socket.connect(t.host, t.port, timeout: timeout);
      sock.destroy();
    } catch (_) {
      return null;
    }
    return probeHost(t.host, t.port, timeout: const Duration(seconds: 3));
  }

  /// Expands "192.168.1.0/24" (or a bare "192.168.1.1") into host targets.
  /// Caps at 1024 hosts per entry to avoid runaway scans.
  List<_Target> _expandCidr(String cidr, List<int> ports) {
    final out = <_Target>[];
    final parts = cidr.split('/');
    final base = InternetAddress.tryParse(parts[0].trim());
    if (base == null || base.type != InternetAddressType.IPv4) return out;
    var prefix = 24;
    if (parts.length > 1) {
      final p = int.tryParse(parts[1].trim());
      if (p == null || p < 8 || p > 32) return out;
      prefix = p;
    }
    final raw = base.rawAddress;
    if (raw.length != 4) return out;
    int ip = 0;
    for (final b in raw) {
      ip = ((ip << 8) | b) & 0xFFFFFFFF;
    }
    final hostBits = 32 - prefix;
    final network = (prefix >= 31)
        ? ip
        : (ip & (~((1 << hostBits) - 1) & 0xFFFFFFFF));
    // Usable host offsets: skip network (.0) and broadcast addresses.
    // /32 = the single address; /31 = both addresses (no broadcast).
    final List<int> offsets;
    if (prefix >= 31) {
      offsets = [for (var i = 0; i < (prefix == 32 ? 1 : 2); i++) i];
    } else {
      final usable = (1 << hostBits) - 2;
      final capped = usable > 1024 ? 1024 : usable;
      offsets = [for (var i = 1; i <= capped; i++) i];
    }
    for (final i in offsets) {
      final host = (network + i) & 0xFFFFFFFF;
      final text =
          '${(host >> 24) & 0xFF}.${(host >> 16) & 0xFF}.${(host >> 8) & 0xFF}.${host & 0xFF}';
      for (final port in ports) {
        out.add(_Target(text, port));
      }
      if (out.length >= 1024 * ports.length) break;
    }
    return out;
  }

  /// Broadcast targets worth probing: the limited broadcast plus each
  /// local IPv4's /24 directed broadcast.
  ///
  /// (dart:io exposes no subnet mask, so /24 is assumed; the limited
  /// broadcast covers larger subnets on the same segment. Subnet scan
  /// in M3 covers anything this misses.)
  Future<List<InternetAddress>> _broadcastAddresses() async {
    final out = <InternetAddress>{InternetAddress('255.255.255.255')};
    try {
      final ifs = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final nic in ifs) {
        for (final addr in nic.addresses) {
          if (addr.type != InternetAddressType.IPv4 || addr.isLoopback) continue;
          final raw = addr.rawAddress;
          if (raw.length != 4) continue;
          final bytes = [raw[0], raw[1], raw[2], 255];
          try {
            out.add(InternetAddress.fromRawAddress(Uint8List.fromList(bytes)));
          } catch (_) {}
        }
      }
    } catch (_) {}
    return out.toList();
  }
}

/// One (host, port) probe candidate for subnet sweeps.
class _Target {
  final String host;
  final int port;
  const _Target(this.host, this.port);
}

/// Progress events streamed by [DiscoveryService.scanSubnets].
class ScanProgress {
  final bool done;
  final int scanned;
  final int total;
  final JezailDevice? found;
  final bool cancelled;

  const ScanProgress({
    required this.done,
    required this.scanned,
    required this.total,
    this.found,
    this.cancelled = false,
  });
}

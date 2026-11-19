import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jezail_console/models/device.dart';
import 'package:jezail_console/services/discovery_service.dart';

/// A fake jezail device answering discovery probes on UDP 8090.
Future<RawDatagramSocket> startFakeResponder({Map<String, dynamic>? reply}) async {
  final server = await RawDatagramSocket.bind(InternetAddress.anyIPv4, DiscoveryService.kDiscoveryPort);
  server.listen((RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final dg = server.receive();
    if (dg == null) return;
    String msg;
    try {
      msg = utf8.decode(dg.data).trim();
    } catch (_) {
      return;
    }
    if (msg != DiscoveryService.kMagic) return;
    final payload = reply ??
        {
          'type': 'jezail-hello',
          'v': 1,
          'id': 'test-device-1',
          'name': 'TestBox',
          'manufacturer': 'Allwinner',
          'model': 'R107INCH',
          'android': '10',
          'sdk': 29,
          'http': 8080,
          'auth': false,
          'root': true,
          'app': '2.0.0',
          'api': 1,
        };
    server.send(utf8.encode(json.encode(payload)), dg.address, dg.port);
  });
  return server;
}

void main() {
  test('broadcast discovery finds a responder and parses jezail-hello', () async {
    final server = await startFakeResponder();
    try {
      final svc = DiscoveryService();
      final found = await svc.broadcastDiscover(timeout: const Duration(seconds: 2));
      expect(found, isNotEmpty, reason: 'fake responder on localhost:8090 should be found');
      final dev = found.firstWhere((d) => d.id == 'test-device-1', orElse: () => found.first);
      expect(dev.host, isNotEmpty);
      expect(dev.port, 8080);
      expect(dev.name, 'TestBox');
      expect(dev.root, isTrue);
    } finally {
      server.close();
    }
  });

  test('malformed replies are ignored, not crashing discovery', () async {
    final server = await RawDatagramSocket.bind(InternetAddress.anyIPv4, DiscoveryService.kDiscoveryPort);
    server.listen((RawSocketEvent e) {
      if (e != RawSocketEvent.read) return;
      final dg = server.receive();
      if (dg == null) return;
      server.send(utf8.encode('this is not json{{{'), dg.address, dg.port);
    });
    try {
      final svc = DiscoveryService();
      final found = await svc.broadcastDiscover(timeout: const Duration(seconds: 2));
      // Must not throw; garbage replies are simply skipped.
      expect(found, isA<List<JezailDevice>>());
    } finally {
      server.close();
    }
  });

  test('scanSubnets finds a fake jezail HTTP server on loopback', () async {
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    httpServer.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/api/status') {
        req.response.write('{"data":{"status":"ok"}}');
      } else if (req.uri.path == '/api/device') {
        req.response.write('{"data":{"deviceName":"LoopBox","manufacturer":"Test",'
            '"model":"T1","androidVersion":"10","sdkInt":29,"isRooted":true}}');
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    try {
      final svc = DiscoveryService();
      final hits = <JezailDevice>[];
      await for (final prog in svc.scanSubnets(
        subnets: const ['127.0.0.0/30'],
        ports: [httpServer.port],
        timeout: const Duration(milliseconds: 500),
        concurrency: 8,
      )) {
        if (prog.found != null) hits.add(prog.found!);
        if (prog.done) {
          expect(prog.scanned, greaterThan(0));
        }
      }
      expect(hits, isNotEmpty, reason: 'loopback fake device should be scanned');
      expect(hits.first.host, '127.0.0.1');
      expect(hits.first.name, 'LoopBox');
    } finally {
      await httpServer.close(force: true);
    }
  });

  test('resolveStableId answers a unicast probe with the device id', () async {
    final server = await startFakeResponder(
      reply: {
        'type': 'jezail-hello',
        'v': 1,
        'id': 'unicast-box-1',
        'name': 'UBox',
        'http': 8080,
        'auth': false,
        'root': false,
      },
    );
    try {
      final id = await DiscoveryService().resolveStableId('127.0.0.1');
      expect(id, 'unicast-box-1');
    } finally {
      server.close();
    }
  });

  test('probeHost carries the stable id so scan merges with broadcast', () async {
    final udp = await startFakeResponder(
      reply: {
        'type': 'jezail-hello',
        'v': 1,
        'id': 'http-box-1',
        'name': 'HBox',
        'http': 8080,
        'auth': false,
        'root': true,
      },
    );
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    httpServer.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/api/status') {
        req.response.write('{"data":{"status":"ok"}}');
      } else if (req.uri.path == '/api/device') {
        req.response.write('{"data":{"deviceName":"HBox","manufacturer":"T",'
            '"model":"T1","androidVersion":"10","sdkInt":29,"isRooted":true}}');
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    try {
      final svc = DiscoveryService();
      final dev = await svc.probeHost('127.0.0.1', httpServer.port);
      expect(dev, isNotNull);
      expect(dev!.id, 'http-box-1',
          reason: 'scan hit must learn the stable id for key-merge');
    } finally {
      await httpServer.close(force: true);
      udp.close();
    }
  });

  test('probeHost rejects plain TCP endpoints without jezail API', () async {
    final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(tcp.listen((_) {}).asFuture());
    try {
      final svc = DiscoveryService();
      final dev = await svc.probeHost('127.0.0.1', tcp.port, probeApi: false);
      expect(dev, isNull);
    } finally {
      await tcp.close();
    }
  });
}

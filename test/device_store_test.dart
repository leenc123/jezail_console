import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jezail_console/models/device.dart';
import 'package:jezail_console/services/device_store.dart';
import 'package:jezail_console/services/discovery_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('DeviceStore.upsert endpoint merge', () {
    test('scan entry adopts stable id from later broadcast, no duplicate', () {
      final store = DeviceStore();
      // Scan path: empty id, keyed host:port.
      store.upsert(JezailDevice(id: '', host: '192.168.1.10', port: 8080, source: 'scan'));
      expect(store.devices.length, 1);

      // Broadcast path for the same box, with stable id.
      store.upsert(JezailDevice.fromDiscovery(
        {
          'id': 'stable-android-id',
          'name': 'Box',
          'manufacturer': 'Allwinner',
          'model': 'R107INCH',
          'android': '10',
          'sdk': 29,
          'http': 8080,
          'auth': false,
          'root': true,
          'app': '2.0.0',
        },
        '192.168.1.10',
        8080,
      ));

      expect(store.devices.length, 1, reason: 'same endpoint must merge, not duplicate');
      final dev = store.devices.single;
      expect(dev.id, 'stable-android-id');
      expect(dev.name, 'Box');
      expect(dev.root, isTrue);
    });

    test('broadcast first, scan later still merges and keeps alias', () {
      final store = DeviceStore();
      store.upsert(JezailDevice(id: 'abc', host: '192.168.1.11', port: 8080, name: 'Hall'));
      store.setAlias('abc', 'Front door');

      store.upsert(JezailDevice(id: '', host: '192.168.1.11', port: 8080, source: 'scan', online: true));

      expect(store.devices.length, 1);
      expect(store.devices.single.alias, 'Front door');
      expect(store.devices.single.id, 'abc', reason: 'empty id must not clobber stable id');
    });
  });

  group('DeviceStore.reconcile legacy duplicates', () {
    Future<DeviceStore> loadRaw(List<Map<String, dynamic>> rows) async {
      SharedPreferences.setMockInitialValues({
        'jezail.devices.v1': json.encode(rows),
      });
      final store = DeviceStore();
      await store.load();
      return store;
    }

    Map<String, dynamic> row(String id, String host, {String name = ''}) => {
          'id': id,
          'host': host,
          'port': 8080,
          'name': name,
          'manufacturer': '',
          'model': '',
          'androidVersion': '',
          'sdk': 0,
          'auth': false,
          'root': false,
          'appVersion': '',
          'source': 'scan',
          'alias': null,
          'lastSeen': null,
        };

    test('same endpoint with/without id folds into one entry', () async {
      final store = await loadRaw([
        row('abc', '192.168.1.10', name: 'Box'),
        row('', '192.168.1.10'),
      ]);
      expect(store.devices.length, 2);
      store.reconcile();
      expect(store.devices.length, 1);
      expect(store.devices.single.id, 'abc');
      expect(store.devices.single.name, 'Box');
    });

    test('same stable id under different hosts folds (IP change)', () async {
      final store = await loadRaw([
        row('abc', '192.168.1.10', name: 'Box'),
        row('abc', '192.168.1.20', name: 'Box'),
      ]);
      store.reconcile();
      expect(store.devices.length, 1);
      expect(store.devices.single.id, 'abc');
    });

    test('genuinely different boxes are never merged', () async {
      final store = await loadRaw([
        row('abc', '192.168.1.10', name: 'Box1'),
        row('def', '192.168.1.11', name: 'Box2'),
      ]);
      store.reconcile();
      expect(store.devices.length, 2);
    });
  });

  group('device deep links', () {
    test('refrida path has no trailing slash (server route is /refrida)', () {
      final d = JezailDevice(id: 'x', host: '192.168.1.2', port: 8080);
      expect(d.refridaUri.path, '/refrida');
      expect(d.webUiUri.path, '/');
      expect(d.terminalUri.path, '/terminal');
      expect(d.mirrorUri.path, '/mirror');
      expect(d.swaggerUri.path, '/api/swagger');
    });
  });

  group('DiscoveryService auth marking', () {
    test('401 from /api/device marks auth but stays online', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path == '/api/status') {
          req.response.write('{"data":{"status":"ok"}}');
        } else if (req.uri.path == '/api/device') {
          req.response.statusCode = 401;
          req.response.write('{"error":"Unauthorized"}');
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
      try {
        final dev = await DiscoveryService().probeHost('127.0.0.1', server.port);
        expect(dev, isNotNull);
        expect(dev!.online, isTrue);
        expect(dev.auth, isTrue, reason: '401 on gated /api/device means auth is on');
      } finally {
        await server.close(force: true);
      }
    });
  });
}

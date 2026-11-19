import 'package:flutter_test/flutter_test.dart';
import 'package:jezail_console/services/discovery_service.dart';

void main() {
  test('probeHost timing on unroutable TEST-NET', () async {
    final svc = DiscoveryService();
    final sw = Stopwatch()..start();
    final r = await svc.probeHost('192.0.2.99', 8080);
    sw.stop();
    // ignore: avoid_print
    print('PROBE result=$r elapsed=${sw.elapsed}');
    expect(r, isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));
}

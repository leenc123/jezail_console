import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jezail_console/models/device.dart';
import 'package:jezail_console/pages/home_page.dart';
import 'package:jezail_console/services/device_store.dart';
import 'package:jezail_console/services/discovery_service.dart';
import 'package:jezail_console/services/health_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// NOTE: network-touching widget tests run inside [runAsync] (real timers),
/// because socket connect timeouts are real timers that FakeAsync would
/// otherwise flag as pending at teardown. 192.0.2.x is TEST-NET-1 and
/// never routes anywhere, so probes fail fast without touching the LAN.
Widget _wrap(HomePage page) => MaterialApp(home: page);

HomePage _page(DeviceStore store) {
  final disc = DiscoveryService();
  final health = HealthService(store: store, discovery: disc, pollSeconds: 3600);
  return HomePage(store: store, discovery: disc, health: health);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('lists known devices and filters by search text', (tester) async {
    await tester.runAsync(() async {
      final store = DeviceStore();
      store.upsert(JezailDevice(id: 'a', host: '192.0.2.10', port: 8080, name: 'Hall', model: 'R107'));
      store.upsert(JezailDevice(id: 'b', host: '192.0.2.11', port: 8080, name: 'Gate', model: 'X1'));

      await tester.pumpWidget(_wrap(_page(store)));
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('Hall'), findsOneWidget);
      expect(find.text('Gate'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'hall');
      await tester.pump();
      expect(find.text('Hall'), findsOneWidget);
      expect(find.text('Gate'), findsNothing);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
    });
  });

  testWidgets('manual add dialog opens and rejects unreachable hosts', (tester) async {
    await tester.runAsync(() async {
      final store = DeviceStore();

      await tester.pumpWidget(_wrap(_page(store)));
      await tester.pump();

      await tester.tap(find.text('Add'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Add device manually'), findsOneWidget);

      // Nothing listens on TEST-NET: probe fails after the real 2s
      // TCP timeout, so wait real time (runAsync) instead of fake pumps.
      // NOTE: must target the dialog's field, not the home search box.
      await tester.enterText(find.widgetWithText(TextField, 'IP address'), '192.0.2.99');
      await tester.tap(find.text('Add').last);
      await tester.pump();
      expect(find.text('Add device manually'), findsNothing);
      await Future.delayed(const Duration(seconds: 4));
      await tester.pump();
      expect(find.textContaining('not reachable'), findsOneWidget);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
    });
  });
}

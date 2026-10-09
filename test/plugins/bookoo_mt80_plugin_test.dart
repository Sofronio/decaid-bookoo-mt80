import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_grinder.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import '../helpers/bookoo_mt80_plugin_fixture.dart';
import 'plugin_test_helpers.dart';

BleAdvertisementEvidence mt80Evidence() =>
    BleAdvertisementEvidence(name: 'BOOKOO MT80 12345678');

Future<PluginGrinder> createMt80Grinder(
  PluginManager manager,
  BookooMt80PluginTransport transport, {
  BleAdvertisementEvidence? evidence,
}) async {
  final resolved = evidence ?? mt80Evidence();
  return await manager.bleService.createCandidate(
        driver: manager.bleService.registry.decide(resolved).drivers.single,
        physicalId: 'AA:BB',
        evidence: resolved,
        admit: () => true,
        createTransport: () => transport,
      )
      as PluginGrinder;
}

/// Connect reaches readiness only once a valid snapshot is published, so the
/// broadcast has to land while `onConnect` is still pending.
Future<PluginGrinder> connectMt80(
  PluginManager manager,
  BookooMt80PluginTransport transport, {
  Map<String, dynamic>? periodInfo,
}) async {
  final grinder = await createMt80Grinder(manager, transport);
  final connect = grinder.onConnect();
  await transport.subscribed.future;
  transport.emitBroadcast(periodInfo ?? mt80PeriodInfo());
  await connect;
  return grinder;
}

List<List<int>> writtenFrames(BookooMt80PluginTransport transport) =>
    transport.writes.map((write) => write.data.toList()).toList();

/// Drives the plugin's HTTP handler through the same seam the web server uses.
Future<Map<String, dynamic>> pluginHttp(
  PluginManager manager, {
  String method = 'GET',
  Map<String, String> query = const {},
  Object? body,
}) async {
  final requestId = 'req-${DateTime.now().microsecondsSinceEpoch}';
  final response = manager.registerPendingHttp(
    bookooMt80Manifest().id,
    requestId,
  );
  manager.dispatchEvent(bookooMt80Manifest().id, 'httpRequest', {
    'requestId': requestId,
    'endpoint': 'ui',
    'method': method,
    'headers': <String, String>{},
    'body': body,
    'query': query,
  });
  return response;
}

void main() {
  test('MT80 manifest declares a grinder driver with its controls', () {
    final driver = bookooMt80Manifest().drivers.single;
    expect(driver.id, 'mt80');
    expect(driver.type, PluginDriverType.grinder);
    // Bookoo lists grinding start/stop as under safety evaluation, so the
    // driver declares the two controls the published protocol documents.
    expect(driver.grinderCapabilities, {
      PluginGrinderCapability.grindSetting,
      PluginGrinderCapability.rpmControl,
    });
    expect(driver.controls['grindSetting']!.kind, 'numeric');
    expect(driver.controls['grindSetting']!.max, 999);
    expect(driver.controls['rpmControl']!.min, 500);
    expect(driver.controls['rpmControl']!.max, 1500);
    // The advertised name is the only discriminator available.
    expect(driver.ble!.serviceUuids, isNull);
    expect(driver.ble!.nameValue, 'mt80');
  });

  test('MT80 exposes its control page as the settings surface', () {
    final driver = bookooMt80Manifest().drivers.single;
    expect(driver.surfaces.single.id, 'settings');
    expect(driver.surfaces.single.role, 'settings');
    expect(driver.surfaces.single.endpoint, 'ui');
  });

  test(
    'MT80 connect publishes an initial snapshot before it is ready',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadBookooMt80Plugin(manager);
      final transport = BookooMt80PluginTransport('AA:BB');
      final grinder = await createMt80Grinder(manager, transport);
      final snapshots = <GrinderSnapshot>[];
      final subscription = grinder.currentSnapshot.listen(snapshots.add);
      addTearDown(subscription.cancel);
      final connect = grinder.onConnect();
      await transport.subscribed.future;
      transport.emitBroadcast(mt80PeriodInfo());
      await connect;
      expect(snapshots, isNotEmpty);
      expect(snapshots.last.state, GrinderState.idle);
      await grinder.disconnect();
    },
  );

  test(
    'MT80 maps the device state, grind size and RPM into the snapshot',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadBookooMt80Plugin(manager);
      final transport = BookooMt80PluginTransport('AA:BB');
      final grinder = await createMt80Grinder(manager, transport);
      final snapshots = <GrinderSnapshot>[];
      final subscription = grinder.currentSnapshot.listen(snapshots.add);
      addTearDown(subscription.cancel);
      final connect = grinder.onConnect();
      await transport.subscribed.future;
      transport.emitBroadcast(
        mt80PeriodInfo(devState: 'GRINDING', bladeGap: 321, grindRpm: 812),
      );
      await connect;
      expect(snapshots.last.state, GrinderState.grinding);
      expect(snapshots.last.setting, '321');
      expect(snapshots.last.rpm, 812);
      await grinder.disconnect();
    },
  );

  test(
    'MT80 reports a warning state as an error and anything else as unknown',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadBookooMt80Plugin(manager);
      final transport = BookooMt80PluginTransport('AA:BB');
      final grinder = await connectMt80(
        manager,
        transport,
        periodInfo: mt80PeriodInfo(devState: 'WARNING'),
      );
      expect((await grinder.currentSnapshot.first).state, GrinderState.error);
      transport.emitBroadcast(
        mt80PeriodInfo(devState: 'BootGuide'),
        sequence: 2,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect((await grinder.currentSnapshot.first).state, GrinderState.unknown);
      await grinder.disconnect();
    },
  );

  test('MT80 setRpm writes the documented geneSetting frame', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final transport = BookooMt80PluginTransport('AA:BB');
    final grinder = await connectMt80(manager, transport);
    transport.writes.clear();
    final pending = grinder.setRpm(1000);
    expect(await transport.awaitRequests(), [
      '{"request":{"geneSetting":{"op":"set","data":{"grindRpm":1000}}}}',
    ]);
    transport.emitJson(
      jsonEncode({
        'response': {
          'geneSetting': {
            'result': 'success',
            'data': {'grindRpm': 1000},
          },
        },
      }),
      sequence: 2,
    );
    await pending;
    await grinder.disconnect();
  });

  test(
    'MT80 setGrindSetting writes the documented geneSetting frame',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadBookooMt80Plugin(manager);
      final transport = BookooMt80PluginTransport('AA:BB');
      final grinder = await connectMt80(manager, transport);
      transport.writes.clear();
      final pending = grinder.setGrindSetting('420');
      expect(await transport.awaitRequests(), [
        '{"request":{"geneSetting":{"op":"set","data":{"bladeGap":420}}}}',
      ]);
      transport.emitJson(
        jsonEncode({
          'response': {
            'geneSetting': {
              'result': 'success',
              'data': {'bladeGap': 420},
            },
          },
        }),
        sequence: 2,
      );
      await pending;
      await grinder.disconnect();
    },
  );

  test('MT80 connect fails when the custom service is absent', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final transport = BookooMt80PluginTransport('AA:BB', servicePresent: false);
    final grinder = await createMt80Grinder(manager, transport);
    await expectLater(grinder.onConnect(), throwsA(anything));
    expect(transport.subscribed.isCompleted, isFalse);
  });

  test('MT80 HTTP handler serves the control page', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final response = await pluginHttp(manager);
    expect(response['status'], 200);
    expect(response['headers']['Content-Type'], contains('text/html'));
    final page = response['body'] as String;
    expect(page, contains('id="bladeGap"'));
    expect(page, contains('id="sliders"'));
  });

  test(
    'MT80 HTTP state reads the cached snapshot without a device request',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadBookooMt80Plugin(manager);
      final transport = BookooMt80PluginTransport('AA:BB');
      final grinder = await connectMt80(manager, transport);
      transport.writes.clear();
      final response = await pluginHttp(manager, query: const {'state': '1'});
      final state =
          jsonDecode(response['body'] as String) as Map<String, dynamic>;
      expect(state['connected'], isTrue);
      expect(
        (state['snapshot'] as Map<String, dynamic>)['grindRpm'],
        mt80PeriodInfo()['grindRpm'],
      );
      expect(transport.writes, isEmpty);
      await grinder.disconnect();
    },
  );

  test('MT80 HTTP POST routes through the same command surface', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final transport = BookooMt80PluginTransport('AA:BB');
    final grinder = await connectMt80(manager, transport);
    transport.writes.clear();
    final pending = pluginHttp(
      manager,
      method: 'POST',
      body: const {'commandId': 'getSettings', 'params': <String, dynamic>{}},
    );
    expect(await transport.awaitRequests(), [
      '{"request":{"geneSetting":{"op":"get","selector":{"type":"all"}}}}',
    ]);
    transport.emitJson(
      jsonEncode({
        'response': {
          'geneSetting': {
            'result': 'success',
            'data': {'feedingRpm': 65},
          },
        },
      }),
      sequence: 2,
    );
    final response = await pending;
    final payload =
        jsonDecode(response['body'] as String) as Map<String, dynamic>;
    expect(payload['ok'], isTrue);
    expect((payload['result'] as Map)['feedingRpm'], 65);
    await grinder.disconnect();
  });

  test('MT80 HTTP handler rejects an unsupported method', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final response = await pluginHttp(manager, method: 'DELETE');
    expect(response['status'], 405);
  });

  test('MT80 advertisement without mt80 in the name is not claimed', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final decision = manager.bleService.registry.decide(
      BleAdvertisementEvidence(name: 'BOOKOO Mini'),
    );
    expect(decision.drivers, isEmpty);
  });
}

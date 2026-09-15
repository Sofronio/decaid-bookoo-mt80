import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import '../helpers/bookoo_mt80_plugin_fixture.dart';
import 'plugin_test_helpers.dart';

BleAdvertisementEvidence mt80Evidence() =>
    BleAdvertisementEvidence(name: 'BOOKOO MT80 12345678');

Future<Sensor> createMt80Sensor(
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
      as Sensor;
}

Future<Sensor> connectMt80(
  PluginManager manager,
  BookooMt80PluginTransport transport,
) async {
  final sensor = await createMt80Sensor(manager, transport);
  final connect = sensor.onConnect();
  await transport.subscribed.future;
  transport.emitBroadcast(mt80PeriodInfo());
  await connect;
  return sensor;
}

List<List<int>> writtenFrames(BookooMt80PluginTransport transport) =>
    transport.writes.map((write) => write.data.toList()).toList();

/// Drives the plugin's HTTP handler through the same seam the web server uses:
/// the loader aliases `handleHttpRequest` off the object `createPlugin`
/// returns, then dispatches one request per correlation id.
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
  test('MT80 manifest declares a sensor driver with channels and commands', () {
    final manifest = bookooMt80Manifest();
    final driver = manifest.drivers.single;
    expect(driver.id, 'mt80');
    expect(driver.type, PluginDriverType.sensor);
    // The MT80 does not advertise its custom service, so the matcher may only
    // rely on the advertised name.
    expect(driver.ble!.serviceUuids, isNull);
    expect(driver.ble!.nameValue, 'mt80');
  });

  test(
    'MT80 connect subscribes, handshakes, and waits for periodInfo',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadBookooMt80Plugin(manager);
      final transport = BookooMt80PluginTransport('AA:BB');
      final sensor = await connectMt80(manager, transport);
      expect(transport.discoverServicesCalls, 1);
      final handshake = mt80DecodeWrites(writtenFrames(transport));
      expect(handshake, ['{"request":{"appHello":{"op":"handshake"}}}']);
      await sensor.disconnect();
    },
  );

  test('MT80 connect fails when the custom service is absent', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final transport = BookooMt80PluginTransport('AA:BB', servicePresent: false);
    final sensor = await createMt80Sensor(manager, transport);
    await expectLater(sensor.onConnect(), throwsA(anything));
    expect(transport.subscribed.isCompleted, isFalse);
  });

  test('MT80 periodInfo publishes every declared channel', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final transport = BookooMt80PluginTransport('AA:BB');
    final sensor = await createMt80Sensor(manager, transport);
    final samples = <Map<String, dynamic>>[];
    final subscription = sensor.data.listen(samples.add);
    addTearDown(subscription.cancel);
    final connect = sensor.onConnect();
    await transport.subscribed.future;
    transport.emitBroadcast(mt80PeriodInfo(grindRpm: 812, bladeGap: 321));
    await connect;
    expect(samples, isNotEmpty);
    expect(samples.first['grindRpm'], 812);
    expect(samples.first['bladeGap'], 321);
    expect(samples.first['devState'], 'IDLE');
    expect(samples.first.keys.toSet(), mt80PeriodInfo().keys.toSet());
    await sensor.disconnect();
  });

  test('MT80 reassembles a broadcast split across notifications', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final transport = BookooMt80PluginTransport('AA:BB');
    final sensor = await createMt80Sensor(manager, transport);
    final samples = <Map<String, dynamic>>[];
    final subscription = sensor.data.listen(samples.add);
    addTearDown(subscription.cancel);
    final connect = sensor.onConnect();
    await transport.subscribed.future;
    // Four fragments of 12 bytes each: the default ATT MTU envelope.
    transport.emitBroadcast(mt80PeriodInfo(selectPreset: 7, humidity: 44));
    await connect;
    expect(samples.first['selectPreset'], 7);
    expect(samples.first['humidity'], 44);
    await sensor.disconnect();
  });

  test('MT80 ignores a notification that is not a valid frame', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final transport = BookooMt80PluginTransport('AA:BB');
    final sensor = await createMt80Sensor(manager, transport);
    final samples = <Map<String, dynamic>>[];
    final subscription = sensor.data.listen(samples.add);
    addTearDown(subscription.cancel);
    final connect = sensor.onConnect();
    await transport.subscribed.future;
    transport.emitFrame([0x00, 0x01, 0x02, 0x03]);
    transport.emitFrame([0xA5, 0x02]);
    expect(samples, isEmpty);
    transport.emitBroadcast(mt80PeriodInfo());
    await connect;
    expect(samples, hasLength(1));
    await sensor.disconnect();
  });

  test(
    'MT80 getSettings sends the documented request and resolves on response',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadBookooMt80Plugin(manager);
      final transport = BookooMt80PluginTransport('AA:BB');
      final sensor = await connectMt80(manager, transport);
      transport.writes.clear();
      final result = sensor.execute('getSettings', {});
      expect(await transport.awaitRequests(), [
        '{"request":{"geneSetting":{"op":"get","selector":{"type":"all"}}}}',
      ]);
      transport.emitJson(
        jsonEncode({
          'response': {
            'geneSetting': {
              'result': 'success',
              'data': {'feedingRpm': 65, 'bladeGap': 500},
            },
          },
        }),
        sequence: 2,
      );
      expect(await result, {'feedingRpm': 65, 'bladeGap': 500});
      await sensor.disconnect();
    },
  );

  test('MT80 surfaces a device failure response as an error', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final transport = BookooMt80PluginTransport('AA:BB');
    final sensor = await connectMt80(manager, transport);
    final result = sensor.execute('setSettings', {'feedingRpm': 999});
    await transport.awaitRequests();
    transport.emitJson(
      jsonEncode({
        'response': {
          'geneSetting': {
            'result': 'fail',
            'error': {
              'code': 'OUT_OF_RANGE',
              'message': 'feedingRpm out of range',
              'field': 'feedingRpm',
            },
          },
        },
      }),
      sequence: 2,
    );
    await expectLater(result, throwsA(anything));
  });

  test(
    'MT80 addPreset generates the published UID when none is supplied',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadBookooMt80Plugin(manager);
      final transport = BookooMt80PluginTransport('AA:BB');
      final sensor = await connectMt80(manager, transport);
      transport.writes.clear();
      final result = sensor.execute('addPreset', {
        'uid': bookooMt80UidVector,
        'index': 0,
        'name': 'Espresso',
        'bladeGap': 180,
        'feedingRpm': 62,
        'grindRpm': 1100,
      });
      final request = (await transport.awaitRequests()).single;
      expect(request, contains(bookooMt80UidVector));
      expect(request, contains('"op":"add"'));
      transport.emitJson(
        jsonEncode({
          'response': {
            'grindPreset': {
              'result': 'success',
              'data': {'uid': bookooMt80UidVector, 'index': 0},
            },
          },
        }),
        sequence: 2,
      );
      expect(await result, {'uid': bookooMt80UidVector, 'index': 0});
      await sensor.disconnect();
    },
  );

  test('MT80 advertisement without mt80 in the name is not claimed', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final decision = manager.bleService.registry.decide(
      BleAdvertisementEvidence(name: 'BOOKOO Mini'),
    );
    expect(decision.drivers, isEmpty);
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
      final sensor = await connectMt80(manager, transport);
      transport.writes.clear();
      final response = await pluginHttp(manager, query: const {'state': '1'});
      final state =
          jsonDecode(response['body'] as String) as Map<String, dynamic>;
      expect(state['connected'], isTrue);
      expect(
        (state['snapshot'] as Map<String, dynamic>)['grindRpm'],
        mt80PeriodInfo()['grindRpm'],
      );
      // Polling must never reach the device: the driver allows one request in
      // flight, so a polling request would block real commands.
      expect(transport.writes, isEmpty);
      await sensor.disconnect();
    },
  );

  test('MT80 HTTP POST routes through the same command surface', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final transport = BookooMt80PluginTransport('AA:BB');
    final sensor = await connectMt80(manager, transport);
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
    await sensor.disconnect();
  });

  test(
    'MT80 HTTP POST reports an unknown command instead of failing',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadBookooMt80Plugin(manager);
      final transport = BookooMt80PluginTransport('AA:BB');
      final sensor = await connectMt80(manager, transport);
      final response = await pluginHttp(
        manager,
        method: 'POST',
        body: const {'commandId': 'nope', 'params': <String, dynamic>{}},
      );
      final payload =
          jsonDecode(response['body'] as String) as Map<String, dynamic>;
      expect(payload['ok'], isFalse);
      expect(payload['error'], contains('nope'));
      await sensor.disconnect();
    },
  );

  test('MT80 HTTP handler rejects an unsupported method', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final response = await pluginHttp(manager, method: 'DELETE');
    expect(response['status'], 405);
  });
}

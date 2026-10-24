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
  String endpoint = 'ui',
  String method = 'GET',
  Map<String, String> query = const {},
  Map<String, String> headers = const {},
  Object? body,
}) async {
  final requestId = 'req-${DateTime.now().microsecondsSinceEpoch}';
  final response = manager.registerPendingHttp(
    bookooMt80Manifest().id,
    requestId,
  );
  manager.dispatchEvent(bookooMt80Manifest().id, 'httpRequest', {
    'requestId': requestId,
    'endpoint': endpoint,
    'method': method,
    'headers': headers,
    'body': body,
    'query': query,
  });
  return response;
}

/// The surfaces the skin would draw for this plugin, read the way it reads
/// them: one GET on the skin endpoint, parsed and unwrapped.
Future<List<Map<String, dynamic>>> skinSurfaces(PluginManager manager) async {
  final response = await pluginHttp(manager, endpoint: 'skin');
  expect(response['status'], 200);
  expect(response['headers']['Content-Type'], 'application/json');
  final answer = jsonDecode(response['body'] as String) as Map<String, dynamic>;
  expect(answer['version'], 1);
  expect(answer['live'], {'endpoint': 'changed'});
  return (answer['surfaces'] as List).cast<Map<String, dynamic>>();
}

Map<String, dynamic> surfaceOf(
  List<Map<String, dynamic>> surfaces,
  String kind,
) => surfaces.singleWhere((surface) => surface['kind'] == kind);

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

  test('MT80 declares every endpoint it answers on', () {
    final endpoints = {
      for (final endpoint in bookooMt80Manifest().api!.endpoints)
        endpoint.id: endpoint.type,
    };
    // A surface can only name an endpoint the manifest declares, and the
    // skin's live socket has to be a websocket the answer can point at.
    expect(endpoints['ui'], ApiEndpointType.http);
    expect(endpoints['skin'], ApiEndpointType.http);
    expect(endpoints['rpm'], ApiEndpointType.http);
    expect(endpoints['stream'], ApiEndpointType.websocket);
    expect(endpoints['changed'], ApiEndpointType.websocket);
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
      transport.emitBroadcast(
        mt80PeriodInfo(devState: 'BOOTGUIDE'),
        sequence: 3,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect((await grinder.currentSnapshot.first).state, GrinderState.unknown);
      await grinder.disconnect();
    },
  );

  test(
    'MT80 accepts both clean-state spellings and the new purge state',
    () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      await loadBookooMt80Plugin(manager);
      final transport = BookooMt80PluginTransport('AA:BB');
      final grinder = await connectMt80(
        manager,
        transport,
        periodInfo: mt80PeriodInfo(devState: 'HighSpeedClean'),
      );
      expect((await grinder.currentSnapshot.first).state, GrinderState.grinding);
      transport.emitBroadcast(
        mt80PeriodInfo(devState: 'HIGHSPEEDCLEAN'),
        sequence: 2,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect((await grinder.currentSnapshot.first).state, GrinderState.grinding);
      transport.emitBroadcast(
        mt80PeriodInfo(devState: 'ADJUSTMENTPURGE'),
        sequence: 3,
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect((await grinder.currentSnapshot.first).state, GrinderState.grinding);
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
    expect(
      response['headers']['Content-Security-Policy'],
      "frame-ancestors 'self'",
    );
    final page = response['body'] as String;
    expect(page, contains('id="bladeGap"'));
    expect(page, contains('id="sliders"'));
    expect(page, contains('id="back"'));
    expect(page, contains('streamline:ready'));
    expect(page, contains('streamline:close'));
    expect(page, contains('returnTo'));
  });

  test('MT80 control page lets the skin on its own port frame it', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final fromReferer = await pluginHttp(
      manager,
      headers: {'referer': 'http://localhost:25123/settings'},
    );
    expect(
      fromReferer['headers']['Content-Security-Policy'],
      "frame-ancestors 'self' http://localhost:25123",
    );
    final fromOrigin = await pluginHttp(
      manager,
      headers: {'origin': 'http://192.168.1.225:25123'},
    );
    expect(
      fromOrigin['headers']['Content-Security-Policy'],
      "frame-ancestors 'self' http://192.168.1.225:25123",
    );
    // Anything that is not an http(s) origin is not echoed into the header.
    final bogus = await pluginHttp(
      manager,
      headers: {'origin': 'javascript:alert(1)'},
    );
    expect(
      bogus['headers']['Content-Security-Policy'],
      "frame-ancestors 'self'",
    );
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

  test('MT80 skin answer draws only the page buttons without a device', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final surfaces = await skinSurfaces(manager);
    // The page reports "not connected" itself, so its buttons stay up; the
    // grind surfaces have nothing to say and are not drawn.
    expect(surfaces.map((surface) => surface['kind']), [
      'header-button',
      'screensaver-button',
    ]);
    for (final surface in surfaces) {
      expect(surface['action'], {
        'type': 'open',
        'view': 'main',
        'presentation': 'overlay',
        'size': 'full',
      });
    }
  });

  test('MT80 skin draws the grind surfaces from the live snapshot', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final transport = BookooMt80PluginTransport('AA:BB');
    final grinder = await connectMt80(manager, transport);
    transport.writes.clear();
    final surfaces = await skinSurfaces(manager);
    expect(transport.writes, isEmpty);

    final line = surfaceOf(surfaces, 'tile-line');
    expect(line['tile'], 'grind');
    expect(line['text'], 'MT80 · ${mt80PeriodInfo()['grindRpm']} rpm');
    expect(line['active'], isFalse);
    // The line, not a tile-mode, carries the RPM control: a mode would take
    // the tile's label slot and the skin would stop drawing the line for good.
    expect(line['action'], {
      'type': 'call',
      'endpoint': 'rpm',
      'field': 'rpm',
      'input': {
        'title': 'RPM',
        'unit': 'rpm',
        'min': 500,
        'max': 1500,
        'decimals': 0,
        'value': mt80PeriodInfo()['grindRpm'],
      },
    });
    expect(
      surfaces.where((surface) => surface['kind'] == 'tile-mode'),
      isEmpty,
      reason: 'a mode on grind would stop the skin drawing the status line',
    );

    final pill = surfaceOf(surfaces, 'tile-hint');
    expect(pill['tile'], 'grind');
    // The pill carries no text on purpose: the skin writes its own label from
    // the size the user picked, and a `text` would take precedence over it.
    expect(pill.containsKey('text'), isFalse);
    expect(pill['action'], {
      'type': 'stepsize',
      'field': 'grinderSetting',
      'sizes': [10, 1],
    });

    // The tile's own number is the workflow's, which is the profile's memory
    // of a setting. This is the grinder's reading of where the burr actually
    // is, for the skin to write back when it moves.
    final sync = surfaceOf(surfaces, 'tile-sync');
    expect(sync['tile'], 'grind');
    expect(sync['value'], mt80PeriodInfo()['bladeGap']);
    expect(sync['label'], 'MT80');
    await grinder.disconnect();
  });

  test('MT80 skin follows the burr from turning to warning', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final transport = BookooMt80PluginTransport('AA:BB');
    final grinder = await connectMt80(
      manager,
      transport,
      periodInfo: mt80PeriodInfo(devState: 'GRINDING', grindRpm: 812),
    );
    var line = surfaceOf(await skinSurfaces(manager), 'tile-line');
    expect(line['text'], 'MT80 · 812 rpm');
    expect(line['active'], isTrue);

    transport.emitBroadcast(
      mt80PeriodInfo(devState: 'WARNING', grindRpm: 812),
      sequence: 2,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    line = surfaceOf(await skinSurfaces(manager), 'tile-line');
    expect(line['text'], 'MT80 · warning');
    expect(line['active'], isFalse);
    await grinder.disconnect();
  });

  test('MT80 rpm endpoint writes the documented geneSetting frame', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final transport = BookooMt80PluginTransport('AA:BB');
    final grinder = await connectMt80(manager, transport);
    transport.writes.clear();
    final pending = pluginHttp(
      manager,
      endpoint: 'rpm',
      method: 'POST',
      body: const {'rpm': 1000},
    );
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
    final response = await pending;
    expect(response['status'], 200);
    final payload =
        jsonDecode(response['body'] as String) as Map<String, dynamic>;
    expect(payload['ok'], isTrue);
    expect(payload['rpm'], 1000);
    await grinder.disconnect();
  });

  test('MT80 rpm endpoint refuses what the control does not allow', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final transport = BookooMt80PluginTransport('AA:BB');
    final grinder = await connectMt80(manager, transport);
    transport.writes.clear();
    for (final rpm in const <Object?>[4000, 499, 'fast', null]) {
      final response = await pluginHttp(
        manager,
        endpoint: 'rpm',
        method: 'POST',
        body: {'rpm': rpm},
      );
      expect(response['status'], 400, reason: 'rpm $rpm');
    }
    // Anyone can POST here, so a refused number must not reach the device.
    expect(transport.writes, isEmpty);
    await grinder.disconnect();
  });

  test('MT80 rpm endpoint reports a device that is not bound', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final response = await pluginHttp(
      manager,
      endpoint: 'rpm',
      method: 'POST',
      body: const {'rpm': 1000},
    );
    expect(response['status'], 409);
  });

  test('MT80 skin and rpm endpoints take one method each', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final writes = await pluginHttp(
      manager,
      endpoint: 'skin',
      method: 'POST',
      body: const <String, dynamic>{},
    );
    expect(writes['status'], 405);
    final reads = await pluginHttp(manager, endpoint: 'rpm');
    expect(reads['status'], 405);
  });

  test('MT80 pushes one skin change per change, not per broadcast', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    // The plugin also emits the raw periodInfo on `stream` for clients that
    // want the firehose; only the skin's own socket is under test here.
    final pushes = <Map<String, dynamic>>[];
    final subscription = manager.emitStream
        .where((event) => event['event'] == 'changed')
        .listen(pushes.add);
    addTearDown(subscription.cancel);
    final transport = BookooMt80PluginTransport('AA:BB');
    final grinder = await createMt80Grinder(manager, transport);
    final connect = grinder.onConnect();
    await transport.subscribed.future;
    transport.emitBroadcast(mt80PeriodInfo());
    await connect;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(pushes, hasLength(1));
    expect(pushes.single['payload'], {'what': 'skin'});

    // periodInfo arrives at 5 Hz. An unchanged reading draws nothing new, and
    // a push per broadcast would have the skin re-read three times a second.
    transport.emitBroadcast(mt80PeriodInfo(), sequence: 2);
    transport.emitBroadcast(mt80PeriodInfo(), sequence: 3);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(pushes, hasLength(1));

    // A real change inside the window the first push opened waits for the
    // trailing edge rather than being dropped or sent out of turn.
    transport.emitBroadcast(mt80PeriodInfo(devState: 'GRINDING'), sequence: 4);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(pushes, hasLength(1));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(pushes, hasLength(2));
    await grinder.disconnect();
  });

  test('MT80 offers the simulated device as an off-by-default setting', () {
    final setting =
        bookooMt80Manifest().settings['mockDevice'] as Map<String, dynamic>;
    expect(setting['type'], 'boolean');
    expect(setting['default'], isFalse);
  });

  test('MT80 registers no simulated device unless the setting asks', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    // Give a registration the chance to land if one were coming.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await manager.deviceService.devices.first, isEmpty);
  });

  test('the simulated MT80 connects, publishes and serves the page', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager, settings: const {'mockDevice': true});
    final devices = await manager.deviceService.devices.firstWhere(
      (list) => list.isNotEmpty,
    );
    final device = devices.single as PluginGrinder;
    expect(device.deviceId, bookooMt80SimulatedDeviceId);
    // It carries the controls the manifest declares, so the host validates a
    // write before it ever reaches the simulator.
    expect(device.controls['grindSetting']!.max, 999);

    final snapshots = <GrinderSnapshot>[];
    final subscription = device.currentSnapshot.listen(snapshots.add);
    addTearDown(subscription.cancel);
    await device.onConnect();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(snapshots, isNotEmpty);
    expect(snapshots.last.state, GrinderState.idle);
    expect(snapshots.last.setting, '350');
    expect(snapshots.last.rpm, 1000);

    // The page and the dashboard surfaces read it through the same handler the
    // driver publishes, so neither can tell it is not hardware.
    final state =
        jsonDecode(
              (await pluginHttp(manager, query: const {'state': '1'}))['body']
                  as String,
            )
            as Map<String, dynamic>;
    expect(state['connected'], isTrue);
    expect((state['snapshot'] as Map)['bladeGap'], 350);
    expect(await skinSurfaces(manager), hasLength(greaterThan(2)));
    await device.disconnect();
  });

  test('the simulated MT80 rejects what the device rejects', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager, settings: const {'mockDevice': true});
    final devices = await manager.deviceService.devices.firstWhere(
      (list) => list.isNotEmpty,
    );
    final device = devices.single as PluginGrinder;
    await device.onConnect();

    Future<Map<String, dynamic>> command(
      String commandId, [
      Map<String, dynamic> params = const {},
    ]) async {
      final response = await pluginHttp(
        manager,
        method: 'POST',
        body: {'commandId': commandId, 'params': params},
      );
      return jsonDecode(response['body'] as String) as Map<String, dynamic>;
    }

    expect((await command('setSettings', {'bladeGap': 5000}))['ok'], isFalse);
    expect((await command('setSettings', {'cupDetect': 'yes'}))['ok'], isFalse);
    expect((await command('setSettings', {'nonsense': 1}))['ok'], isFalse);
    expect((await command('addPreset', {}))['ok'], isFalse);
    expect((await command('getPresets'))['result']['presets'], hasLength(2));
    expect((await command('getSections'))['result']['sections'], hasLength(2));
    expect((await command('setSettings', {'bladeGap': 420}))['ok'], isTrue);

    final state =
        jsonDecode(
              (await pluginHttp(manager, query: const {'state': '1'}))['body']
                  as String,
            )
            as Map<String, dynamic>;
    expect((state['snapshot'] as Map)['bladeGap'], 420);
    await device.disconnect();
  });

  test('MT80 pushes when the burr moves, with nothing else changing', () async {
    final manager = PluginManager(kvStore: FakeKeyValueStoreService());
    addTearDown(manager.dispose);
    await loadBookooMt80Plugin(manager);
    final pushes = <Map<String, dynamic>>[];
    final subscription = manager.emitStream
        .where((event) => event['event'] == 'changed')
        .listen(pushes.add);
    addTearDown(subscription.cancel);
    final transport = BookooMt80PluginTransport('AA:BB');
    final grinder = await connectMt80(
      manager,
      transport,
      periodInfo: mt80PeriodInfo(bladeGap: 200),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(pushes, hasLength(1));

    // Someone turned the dial on the grinder. The state and the RPM are
    // untouched, and this is exactly what a tile-sync surface exists to hear.
    transport.emitBroadcast(mt80PeriodInfo(bladeGap: 210), sequence: 2);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(pushes, hasLength(2));

    transport.emitBroadcast(mt80PeriodInfo(bladeGap: 210), sequence: 3);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      pushes,
      hasLength(2),
      reason: 'a burr that did not move pushes nothing',
    );
    await grinder.disconnect();
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

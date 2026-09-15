import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';

import 'plugin_ble_fixture.dart';

const bookooMt80PluginPath = 'examples/plugins/bookoo-mt80.reaplugin';
const bookooMt80ServiceUuid = '4d543830-0001-4b80-8f00-424f4f4b4f4f';
const bookooMt80RxUuid = '4d543830-0002-4b80-8f00-424f4f4b4f4f';
const bookooMt80TxUuid = '4d543830-0003-4b80-8f00-424f4f4b4f4f';

PluginManifest bookooMt80Manifest() => PluginManifest.fromJson(
  jsonDecode(File('$bookooMt80PluginPath/manifest.json').readAsStringSync()),
);

Future<void> loadBookooMt80Plugin(PluginManager manager) => manager.loadPlugin(
  id: bookooMt80Manifest().id,
  manifest: bookooMt80Manifest(),
  settings: {},
  jsCode: File('$bookooMt80PluginPath/plugin.js').readAsStringSync(),
);

/// The published UID test vector, so a regression in the 64-bit FNV path fails
/// here rather than only against the device.
const bookooMt80UidVector = 'ae8f0ec693f96e37140fc424ab5df303';

/// A `periodInfo` broadcast with the documented field set.
Map<String, dynamic> mt80PeriodInfo({
  int feedingRpm = 65,
  int bladeGap = 500,
  int grindRpm = 700,
  int humidity = 25,
  String devState = 'IDLE',
  String netState = 'CONNECTED',
  int totalGrinds = 120,
  bool cupDetect = true,
  bool autoStop = true,
  bool fastClean = true,
  int brightness = 5,
  int standbySec = 60,
  int selectPreset = -1,
}) => {
  'feedingRpm': feedingRpm,
  'bladeGap': bladeGap,
  'grindRpm': grindRpm,
  'humidity': humidity,
  'devState': devState,
  'netState': netState,
  'totalGrinds': totalGrinds,
  'cupDetect': cupDetect,
  'autoStop': autoStop,
  'fastClean': fastClean,
  'brightness': brightness,
  'standbySec': standbySec,
  'selectPreset': selectPreset,
};

/// Splits a logical message into the documented `A5 01` fragments. Fragments
/// default to the reference client's 12-byte payload.
List<List<int>> mt80Fragments(
  String json, {
  int sequence = 1,
  int payloadSize = 12,
}) {
  final bytes = utf8.encode(json);
  final frames = <List<int>>[];
  for (var offset = 0; offset < bytes.length; offset += payloadSize) {
    final end = (offset + payloadSize).clamp(0, bytes.length);
    frames.add([
      0xA5,
      0x01,
      sequence & 0xFF,
      (sequence >> 8) & 0xFF,
      bytes.length & 0xFF,
      (bytes.length >> 8) & 0xFF,
      offset & 0xFF,
      (offset >> 8) & 0xFF,
      ...bytes.sublist(offset, end),
    ]);
  }
  return frames;
}

/// Rebuilds the JSON a plugin wrote to RX, so a test can assert request frames.
List<String> mt80DecodeWrites(List<List<int>> frames) {
  final messages = <String>[];
  final buffer = <int>[];
  var total = 0;
  for (final frame in frames) {
    if (frame.length < 8 || frame[0] != 0xA5 || frame[1] != 0x01) continue;
    if (frame[6] == 0 && frame[7] == 0) {
      buffer.clear();
      total = frame[4] | (frame[5] << 8);
    }
    buffer.addAll(frame.sublist(8));
    if (buffer.length >= total && total > 0) {
      messages.add(utf8.decode(buffer.sublist(0, total)));
      buffer.clear();
      total = 0;
    }
  }
  return messages;
}

class BookooMt80PluginTransport extends PluginBleFixtureTransport {
  BookooMt80PluginTransport(
    super.physicalId, {
    this.servicePresent = true,
    this.writeFailure,
  });

  final bool servicePresent;
  final Object? writeFailure;

  final subscribed = Completer<void>();
  int discoverServicesCalls = 0;

  @override
  Future<List<String>> discoverServices() async {
    discoverServicesCalls++;
    return servicePresent ? [bookooMt80ServiceUuid] : [];
  }

  @override
  Future<void> subscribe(
    String service,
    String characteristic,
    void Function(Uint8List) callback,
  ) async {
    if (service != bookooMt80ServiceUuid ||
        characteristic != bookooMt80TxUuid) {
      throw StateError('Unexpected MT80 subscription $service/$characteristic');
    }
    subscribers[characteristic] = callback;
    if (!subscribed.isCompleted) subscribed.complete();
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (serviceUUID != bookooMt80ServiceUuid ||
        characteristicUUID != bookooMt80RxUuid) {
      throw StateError(
        'Unexpected MT80 write $serviceUUID/$characteristicUUID',
      );
    }
    if (writeFailure != null) throw writeFailure!;
    await super.write(
      serviceUUID,
      characteristicUUID,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }

  void emitFrame(List<int> frame) =>
      subscribers[bookooMt80TxUuid]!(Uint8List.fromList(frame));

  /// The plugin writes from inside promise continuations, so a test cannot
  /// assume the bytes have landed on the next microtask.
  Future<List<String>> awaitRequests({int count = 1}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      final messages = mt80DecodeWrites(
        writes.map((write) => write.data.toList()).toList(),
      );
      if (messages.length >= count) return messages;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return mt80DecodeWrites(
      writes.map((write) => write.data.toList()).toList(),
    );
  }

  void emitJson(String json, {int sequence = 1, int payloadSize = 12}) {
    for (final frame in mt80Fragments(
      json,
      sequence: sequence,
      payloadSize: payloadSize,
    )) {
      emitFrame(frame);
    }
  }

  void emitBroadcast(Map<String, dynamic> periodInfo, {int sequence = 1}) {
    emitJson(
      jsonEncode({
        'broadcast': {'periodInfo': periodInfo},
      }),
      sequence: sequence,
    );
  }
}

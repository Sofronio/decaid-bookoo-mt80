# Tests

These tests live here because the driver owns its protocol coverage, but they
**cannot run standalone**: they exercise the plugin through Decaid's shared
plugin harness, not a copy of it.

The imports resolve against a Decaid checkout, not this repository:

- `../helpers/plugin_ble_fixture.dart` — the fake BLE transport and platform
- `plugin_test_helpers.dart` — `FakeKeyValueStoreService` and manifest helpers

Both belong to Decaid's test tree because other plugin tests use them too, and
duplicating them here would drift.

## Running

From a Decaid checkout, overlay this directory onto its `test/` tree and run
the suite there:

```bash
cp -r test/helpers/bookoo_mt80_plugin_fixture.dart <decaid>/test/helpers/
cp -r test/plugins/bookoo_mt80_plugin_test.dart    <decaid>/test/plugins/
cd <decaid> && flutter test test/plugins/bookoo_mt80_plugin_test.dart
```

The plugin source is read from `examples/plugins/bookoo-mt80.reaplugin/` by
relative path, so the copy must sit beside that directory. Keep the two in sync
when either changes — `scripts/package.sh` in this repository builds the
released archive from `bookoo-mt80.reaplugin/`, and the Decaid copy is what the
tests load.

## What the fixture covers

`bookoo_mt80_plugin_fixture.dart` builds `A5 01` fragments with the documented
little-endian header and reassembles the JSON a plugin writes to RX, so a test
can assert request frames the way the device sees them. It also pins the
published UID test vector, so a regression in the 32-bit-limb FNV-1a 64 path
fails here rather than only against hardware.

`bookoo_mt80_plugin_test.dart` covers both surfaces: the protocol over BLE, and
the control page's HTTP handler through `registerPendingHttp` plus
`dispatchEvent`, which is the same seam the web server uses.

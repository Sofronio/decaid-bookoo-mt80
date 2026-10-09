# Bookoo MT80 (MOTTO80) for Decaid

A [Decaid](https://github.com/decentespresso/decaid) plugin that adds the Bookoo
MT80 grinder (sold as MOTTO80). The plugin owns the device protocol; Decaid
owns discovery, the BLE connection lifecycle, and the device surface.

No Decaid release is needed to use this, and none is needed to add support for
another device.

## Driver type

The MT80 declares the `grinder` driver type. It exposes the two controls
Bookoo's published protocol actually documents — `grindSetting` and
`rpmControl` — and publishes `state`, `setting` and `rpm` as its snapshot.
Grinding start and stop is deliberately not declared; see Out of scope.

Earlier versions declared a Sensor because Decaid had no grinder type. That is
no longer needed.

## Install

From the Decaid REST API, which installs the repository's latest release:

```bash
curl -X POST http://localhost:8080/api/v1/plugins/install/github-release \
  -H 'content-type: application/json' \
  -d '{"repo": "Sofronio/decaid-bookoo-mt80"}'
```

Or open the Plugins settings screen in Decaid and install from the repository.

The public device ID is
`plugin:bookoo-mt80.reaplugin:mt80:<physical id>`. When the plugin is loaded it
takes ownership of the advertisement and any native candidate for the same
device is suppressed.

## Matching

An advertisement whose name contains `mt80` (case-insensitive). The matcher
deliberately declares **no** service UUIDs: Bookoo's integration guide states
the Custom Service is not in the advertising data, and a scan of a physical unit
confirms it advertises `FFFF` with the name `BOOKOO MT80 xxxxxxxx`. A
`serviceUuids` constraint would never match.

## Protocol

Service `4d543830-0001-4b80-8f00-424f4f4b4f4f`; RX (write) `...-0002`, TX
(notify) `...-0003`.

Messages are UTF-8 JSON carried in `A5 01` fragments with an eight-byte header,
all multibyte fields little-endian:

| Offset | Length | Field |
| --- | --- | --- |
| 0 | 1 | `magic` = `0xA5` |
| 1 | 1 | `version` = `0x01` |
| 2 | 2 | `sequence`, identical across one message's fragments |
| 4 | 2 | `totalLength` of the complete JSON |
| 6 | 2 | `offset` of this fragment within that JSON |
| 8 | N | payload |

Fragments are written with response and reassembled by `offset`; a fragment at
offset `0` starts a new message, and an incomplete message expires after two
seconds. This driver sends 12 payload bytes per fragment, matching the
reference client's 20-byte packets and the default ATT MTU of 23.

After subscribing, the client sends `{"request":{"appHello":{"op":"handshake"}}}`.
The device answers with `baseInfo` once and then `periodInfo` at 5 Hz; the first
`periodInfo` is readiness. Every disconnection invalidates the subscription and
handshake, so a reconnect re-subscribes and re-handshakes.

Requests carry exactly one business object and responses arrive under the same
object, so this driver keeps one request in flight and correlates by that key
rather than by `sequence` — the specification explicitly forbids using
`sequence` for correlation.

## Snapshot

The driver publishes `{state, setting, rpm}`:

| Field | Source in `periodInfo` | Mapping |
| --- | --- | --- |
| `state` | `devState` | `IDLE` → `idle`, `GRINDING` and `HighSpeedClean` → `grinding`, `WARNING` → `error`, anything else → `unknown` |
| `setting` | `bladeGap` | string, requires `grindSetting` |
| `rpm` | `grindRpm` | integer, requires `rpmControl` |

The device vocabulary is its own; only these four states reach the host, and
anything unrecognised is reported as `unknown` rather than guessed.

**Readiness is the publication, not the arrival.** The host requires a valid
initial snapshot before the grinder is usable, so `connect` resolves only after
the host accepts the first publication — a rejected snapshot fails the connect
rather than leaving a half-ready device.

The other documented `periodInfo` fields — feed RPM, humidity, network state,
lifetime grind count, cup detect, auto stop, fast clean, brightness, standby and
the selected preset — have no place in the grinder snapshot. They remain visible
on the control page, which reads the driver's own cache.

## Controls

| Capability | Handler | Declared control |
| --- | --- | --- |
| `grindSetting` | `setGrindSetting(setting)` | numeric 0–999, step 1 (`bladeGap`) |
| `rpmControl` | `setRpm(rpm)` | numeric 500–1500, step 10 (`grindRpm`) |

Each writes one `geneSetting` field and waits for the device's response. The
host validates the value against the declared control before invoking the
handler, so the driver only normalises and rounds.

The page also drives a wider command surface over the plugin's own HTTP
endpoint — settings, grinding sections and preset CRUD. Those are the page's
commands, not part of the grinder contract.

## Control page

The plugin serves a live control page at
`/api/v1/plugins/bookoo-mt80.reaplugin/ui`, reachable through an `api` entry of
type `http`:

```
GET  /api/v1/plugins/bookoo-mt80.reaplugin/ui            -> the page
GET  /api/v1/plugins/bookoo-mt80.reaplugin/ui?state=1    -> cached JSON state
POST /api/v1/plugins/bookoo-mt80.reaplugin/ui            -> {commandId, params}
```

The page mirrors the in-app grinder debug view: a large grind-size readout with
feed and grind RPM, a live status table, draggable sliders that send on a 250 ms
debounce, boolean toggles, preset and section chips, and a per-kind send,
response, and broadcast log. It toggles between English and Chinese.

Its `POST` body is `{commandId, params}`:

| Command | Purpose |
| --- | --- |
| `getSettings` | Read every `geneSetting` field |
| `setSettings` | Write `geneSetting` fields; the body is the field set |
| `getSections` | Read all grinding sections |
| `setSections` | Write all grinding sections from `sections` |
| `getPresets` | Read every visible preset |
| `addPreset` | Add a preset; generates the UID when none is supplied |
| `updatePreset` | Edit `name`, `note`, `bladeGap`, `feedingRpm`, `grindRpm` |
| `deletePreset` | Move a preset to the recycle bin |
| `restorePreset` | Restore a deleted preset, optionally at `index` |
| `reorderPreset` | Move a preset to a new `index` |
| `importPresets` | Replace the preset list from `presets` |
| `getRecycleBin` | List deleted presets |

`addPreset` generates the 32-character UID with the specification's FNV-1a
64-bit algorithm when the caller does not supply one, and reproduces the
published test vector `ae8f0ec693f96e37140fc424ab5df303`. The implementation
runs on 32-bit limbs because the plugin runtime cannot be assumed to have
`BigInt`.

The sliders post `setSettings`, the preset chips post
`setSettings {selectPreset}`, and the section chips post
`setSettings {bladeGap}`. The HTTP layer is transport only, not a second
vocabulary: every command lands on the same `geneSetting` request path the
grinder controls use.

Polling reads the cached `periodInfo` and never touches the device, because the
driver keeps one request in flight and a polling request would block real
commands. The sliders use the **published** `geneSetting` ranges rather than the
reference GUI's wider ones, since the device rejects anything outside them.

`handleHttpRequest` must be defined on the object `createPlugin` returns, not on
the device the driver factory returns; the loader aliases it from there. The
page itself is device-independent, so it renders before any MT80 binds and just
reports "not connected".

A section chip writes only the grind-size value for that range. It does not move
the physical burr: Bookoo's guide states the MT80 adjusts manually, and that
writing `bladeGap` does not change the physical gap.

## Surfaces

The manifest declares one surface, `settings`, pointing at the control page's
own endpoint. Device management consumes it through
`PluginDeviceSurfaceAuthority` and opens the page against `localhost` for that
device, without requiring a connection first. The plugin owns identity
validation; ownership is never inferred from the device ID.

## Out of scope

Grinding start and stop is **not declared**. Bookoo's integration guide lists
BLE grinding start/stop control as under safety evaluation and outside the
published SDK, so no framing for it is documented. The driver therefore claims
`grindSetting` and `rpmControl` only, and start/stop fails with
`unsupported_operation` before any handler runs. Do not add a guessed frame
here.

## Releasing

`scripts/package.sh` builds `dist/bookoo-mt80.reaplugin-<version>.zip`. Pushing a
`vX.Y.Z` tag runs the same script in CI and publishes the release.

Decaid enforces three things the script keeps in sync:

- the release tag is `X.Y.Z` or `vX.Y.Z` and equals `manifest.version` exactly
- the release carries exactly one `.zip` asset
- the archive holds a single top-level `bookoo-mt80.reaplugin/` directory
  containing `manifest.json` and `plugin.js`

So bump `manifest.version` and tag the same version. A release whose tag and
manifest disagree is rejected at install time.

## Verified

Exercised against a physical MT80. The plugin claims the advertisement and
suppresses the native candidate, connect finds the Custom Service, subscribes,
and reaches readiness once the first snapshot is accepted. `getSettings`,
`getSections`, and `getPresets` returned the grinder's real configuration,
including section and preset names in Chinese — which exercises the UTF-8 path
across fragment boundaries on the wire.

Writes were exercised against the same unit and restored afterwards. Writing
the current settings back is accepted and echoed, and changing `brightness`
propagated to both `getSettings` and the live `periodInfo` stream before being
restored; a final field-by-field comparison against a pre-test backup matched
exactly, the preset list was unchanged, and the recycle bin stayed empty.
Preset add and delete are left untested on purpose — deletion leaves a tombstone
the protocol offers no way to purge.

The protocol follows Bookoo's published
[open-scale-protocol](https://github.com/BooKooCode/OpenSource/tree/main/bookoo_motto80)
MT80 BLE GATT SDK (minimum firmware `v1.2.19.0820`).

## License

Not yet chosen. Until one is added, this repository is all rights reserved by
default.

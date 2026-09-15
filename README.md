# Bookoo MT80 (MOTTO80) for Decaid

A [Decaid](https://github.com/decentespresso/decaid) plugin that adds the Bookoo
MT80 grinder (sold as MOTTO80). The plugin owns the device protocol; Decaid
owns discovery, the BLE connection lifecycle, and the device surface.

No Decaid release is needed to use this, and none is needed to add support for
another device.

## Why this is a Sensor, not a Grinder

Decaid has no grinder driver type yet, so this driver declares
`"type": "sensor"`. That is a lossless mapping rather than a workaround: the
MT80 reports grinding parameters, not weight, and the Sensor surface carries
arbitrary named data channels with units. All thirteen documented `periodInfo`
fields survive.

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

## Data channels

`feedingRpm` (rpm), `bladeGap` (um), `grindRpm` (rpm), `humidity` (%RH),
`devState`, `netState`, `totalGrinds`, `cupDetect`, `autoStop`, `fastClean`,
`brightness`, `standbySec`, `selectPreset`.

## Commands

Available through `POST /api/v1/sensors/:id/execute`.

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
64-bit algorithm when the caller does not supply one. The implementation runs on
32-bit limbs because the plugin runtime cannot be assumed to have `BigInt`, and
it reproduces the published test vector
`ae8f0ec693f96e37140fc424ab5df303`.

## Out of scope

Grinding start and stop is **not implemented**. Bookoo's integration guide lists
BLE grinding start/stop control as under safety evaluation and outside the
published SDK, so no framing for it is documented. Do not add a guessed frame
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
and reaches readiness on the first `periodInfo`, and all thirteen data channels
stream at 5 Hz. `getSettings`, `getSections`, and `getPresets` returned the
grinder's real configuration, including section and preset names in Chinese —
which exercises the UTF-8 path across fragment boundaries on the wire.

The protocol follows Bookoo's published
[open-scale-protocol](https://github.com/BooKooCode/OpenSource/tree/main/bookoo_motto80)
MT80 BLE GATT SDK (minimum firmware `v1.2.19.0820`).

## License

Not yet chosen. Until one is added, this repository is all rights reserved by
default.

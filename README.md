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
| `state` | `devState` | `IDLE` → `idle`; `GRINDING`, `HIGHSPEEDCLEAN` and `ADJUSTMENTPURGE` → `grinding`; `WARNING` → `error`; anything else → `unknown` |
| `setting` | `bladeGap` | string, requires `grindSetting` |
| `rpm` | `grindRpm` | integer, requires `rpmControl` |

The device vocabulary is its own; only these four states reach the host, and
anything unrecognised is reported as `unknown` rather than guessed. The lookup
ignores case and covers both firmware eras: `HighSpeedClean` became
`HIGHSPEEDCLEAN` in firmware `v1.3.11.1020`, which also added
`ADJUSTMENTPURGE` (grind adjustment and grounds purge). Both purging states
reach the host as `grinding`.

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

## Simulated device

For building against this grinder without one, turn on the `mockDevice` plugin
setting:

```bash
curl -X POST http://localhost:8080/api/v1/plugins/bookoo-mt80.reaplugin/settings \
  -H 'Content-Type: application/json' -d '{"mockDevice": true}'
```

Decaid reloads the plugin and registers an in-memory MT80 as
`plugin:bookoo-mt80.reaplugin:mt80:simulated`, named "Bookoo MT80
(simulated)", alongside any real one. Connect it like any other device.

It publishes the same `{state, setting, rpm}` snapshot once a second, carries
the same declared controls, and answers the control page's commands with the
device's own rejections — ranges, booleans, `selectPreset` and all, with preset
and section *editing* reporting that they are unsupported. Nothing it does
touches the radio, its state is in memory and resets on reload, and the setting
defaults to off.

A real MT80 wins while it is connected: the control page and the dashboard
surfaces serve whichever grinder is connected, and hardware is preferred.

## Dashboard surfaces

A skin on the Streamline plugin-surfaces protocol can draw a fixed set of UI
pieces for a plugin that answers its `skin` endpoint, and runs only the actions
it knows — no plugin code runs in the skin. The plugin answers
`GET /api/v1/plugins/bookoo-mt80.reaplugin/skin` with what this grinder has to
offer:

| Surface | Kind | Where | Shows |
| --- | --- | --- | --- |
| `mt80-state` | `tile-line` | under the Grind label | the burr speed, or `warning`; drawn switched on while grinding, and a tap opens the skin's numpad to set it |
| `mt80-step` | `tile-hint` | the Grind tile's pill | a coarse/fine `±10` / `±1` step for the grind setting |
| `mt80-sync` | `tile-sync` | the Grind tile's own value | the grinder's reading of the grind setting, written into the workflow when it moves |
| `mt80-page` | `header-button` | the dashboard header | the control page |
| `mt80-saver` | `screensaver-button` | over the screensaver | the control page |

The two buttons open the page as a full-screen `overlay`, not as a same-frame
`page`: the control page sits over the dashboard in the skin's dialog, and
closing it returns to the dashboard as it was, with no navigation and no skin
reload. The page posts `streamline:ready` when it loads and `streamline:close`
from its back button; the skin draws its own close button too. If a skin falls
back to a page open (no ready within three seconds), or the page is opened
outside the skin, the back button uses the `returnTo` the surface protocol adds,
so it still returns to where it came from.

The `ui` response sends `Content-Security-Policy: frame-ancestors 'self'
<Origin/Referer origin>` because a skin served from another port — the tablet's
is `:25123` — would otherwise be refused by Decaid's `X-Frame-Options:
SAMEORIGIN` on the overlay's iframe.

The line is where `rpmControl` lives, because the grinder snapshot carries one
number and the tile spends it on the setting. It is a `line` and not a `hint`
because a hint shares its slot with the pill, and the skin draws one of each per
tile. `stepsize` is the one action that reaches the tile's own `-`/`+` without
taking a slot the text needs.

**No `tile-mode` on grind, on purpose.** A mode takes the tile's label slot, and
the skin then stops drawing a `tile-line` on that tile *whatever option is
selected* — `modeTiles.has(tile)` is decided when the answer is parsed, not when
the user switches. Offering one would cost the status line permanently, and the
only thing it would add here is `±` stepping for a number that is set once per
bean. The line's `input` action reaches the same `rpm` endpoint.

The pill carries no `text` of its own. The skin labels it from the size the
user picked on that device, cycling `±10` and `±1`; a `text` in the answer takes
precedence over that label and would freeze it.

### The tile's number and the grinder's

The Grind tile's number is the workflow's `context.grinderSetting` — the active
profile's memory of a setting, which says nothing about where the burr actually
is. The two drift apart the moment someone turns the dial on the grinder, and
nothing reconciles them: no code in Decaid reads `GrinderSnapshot.setting`, and
the only route that writes a grinder is `PUT /api/v1/grinder/setting`, which
neither the app nor the skin calls.

`tile-sync` closes that gap. While the value is drawn, the skin writes a
*changed* value into the workflow as if the user had typed it, so the tile and
the profile's memory follow the burr; a value typed afterwards stands until the
burr moves again. The kind is newer than this plugin, and a skin that does not
know it yet ignores it and draws everything else, so the surface can ship
before the skin that acts on it.

The buttons are drawn even with no device bound — the page reports "not
connected" itself. The grind surfaces are not, because they would have nothing
to say.

### Keeping the skin in sync

`live` in the same answer names the `changed` websocket. The skin holds it open
and re-reads `skin` on every message, so the plugin pushes `{"what": "skin"}`
only when a value a surface actually shows has moved, and never twice inside a
second. The body says the workflow did not change, which is always true here:
this plugin never writes one, and a `set` or `step` the user makes goes through
Decaid's own setters.

The `stream` socket keeps its separate meaning — the full `periodInfo` on every
broadcast, for a client that would rather subscribe than poll. Pointing `live`
at that firehose instead would have the skin re-read itself three times a
second.

### Writes from the skin

`POST /api/v1/plugins/bookoo-mt80.reaplugin/rpm` with `{"rpm": 1000}` is what a
tap on the status line ends up calling, once the skin's numpad has a number. It
is not a second vocabulary: the number lands on the same `geneSetting` request
path the page's `setSettings` command uses. It is range-checked before that,
because anyone can POST there and the host's control validation is not in this
path.

## Device surface

Separate from the dashboard surfaces above: the manifest declares one driver
surface, `settings`, pointing at the control page's own endpoint. Device
management consumes it through `PluginDeviceSurfaceAuthority` and opens the page
against `localhost` for that device, without requiring a connection first. The
plugin owns identity validation; ownership is never inferred from the device
ID.

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

The dashboard surfaces are covered by the plugin's own tests, which read the
`skin` answer the way the skin reads it and drive the `rpm` endpoint through
the same seam the web server uses. They have not been exercised against a
running skin yet, and the surface limits — one hint and one line per tile, one
header button overall — belong to the skin, so the plugin can only be as good
as the slot it wins.

The simulated device is covered the same way: that the setting registers it
and nothing registers without it, that it connects and publishes, that the
control page and the surfaces read it, and that it rejects what the device
rejects. Like everything else here it has not been run inside a Decaid build
from this repository's tests alone — they need a Decaid checkout.

The protocol follows Bookoo's published
[open-scale-protocol](https://github.com/BooKooCode/OpenSource/tree/main/bookoo_motto80)
MT80 BLE GATT SDK (minimum firmware `v1.2.19.0820`; state names follow the
`devState` table updated for firmware `v1.3.11.1020`).

## License

Not yet chosen. Until one is added, this repository is all rights reserved by
default.

function createPlugin(host) {
  const service = "4d543830-0001-4b80-8f00-424f4f4b4f4f";
  const rx = "4d543830-0002-4b80-8f00-424f4f4b4f4f";
  const tx = "4d543830-0003-4b80-8f00-424f4f4b4f4f";
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

  const magic = 0xa5;
  const version = 0x01;
  const headerSize = 8;
  const maxTotalLength = 4096;
  // The reference client sends 20-byte packets, so a fragment carries at most
  // 12 JSON bytes and survives a default ATT MTU of 23.
  const fragmentPayload = 12;
  const fragmentExpiryMs = 2000;
  const requestTimeoutMs = 5000;
  const handshakeTimeoutMs = 5000;

  function decodeBase64(data) {
    if (typeof data !== "string" || data.length % 4 !== 0) return null;
    const bytes = [];
    for (let i = 0; i < data.length; i += 4) {
      const a = alphabet.indexOf(data[i]);
      const b = alphabet.indexOf(data[i + 1]);
      const c = data[i + 2] === "=" ? 0 : alphabet.indexOf(data[i + 2]);
      const d = data[i + 3] === "=" ? 0 : alphabet.indexOf(data[i + 3]);
      if (a < 0 || b < 0 || c < 0 || d < 0) return null;
      bytes.push((a << 2) | (b >> 4));
      if (data[i + 2] !== "=") bytes.push(((b & 15) << 4) | (c >> 2));
      if (data[i + 3] !== "=") bytes.push(((c & 3) << 6) | d);
    }
    return bytes;
  }

  function utf8Encode(text) {
    const bytes = [];
    for (let i = 0; i < text.length; i++) {
      let code = text.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
        const low = text.charCodeAt(i + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
          i++;
        }
      }
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      } else if (code < 0x10000) {
        bytes.push(
          0xe0 | (code >> 12),
          0x80 | ((code >> 6) & 0x3f),
          0x80 | (code & 0x3f)
        );
      } else {
        bytes.push(
          0xf0 | (code >> 18),
          0x80 | ((code >> 12) & 0x3f),
          0x80 | ((code >> 6) & 0x3f),
          0x80 | (code & 0x3f)
        );
      }
    }
    return bytes;
  }

  function utf8Decode(bytes) {
    let out = "";
    for (let i = 0; i < bytes.length; ) {
      const first = bytes[i];
      let code;
      let size;
      if (first < 0x80) {
        code = first;
        size = 1;
      } else if ((first & 0xe0) === 0xc0) {
        code = first & 0x1f;
        size = 2;
      } else if ((first & 0xf0) === 0xe0) {
        code = first & 0x0f;
        size = 3;
      } else if ((first & 0xf8) === 0xf0) {
        code = first & 0x07;
        size = 4;
      } else {
        out += "�";
        i++;
        continue;
      }
      if (i + size > bytes.length) {
        out += "�";
        break;
      }
      for (let k = 1; k < size; k++) code = (code << 6) | (bytes[i + k] & 0x3f);
      i += size;
      if (code > 0xffff) {
        code -= 0x10000;
        out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
      } else {
        out += String.fromCharCode(code);
      }
    }
    return out;
  }

  // The runtime cannot be assumed to have BigInt, so the documented 64-bit UID
  // arithmetic runs on 32-bit limbs. Products are kept in doubles: every
  // intermediate stays below 2^53, and only values that fit are coerced with
  // `>>> 0`.
  const FNV_OFFSET_HIGH = 0xcbf29ce4;
  const FNV_OFFSET_LOW = 0x84222325;
  const FNV_PRIME_HIGH = 0x100;
  const FNV_PRIME_LOW = 0x1b3;
  const UID_PERTURB_HIGH = 0x9e3779b9;
  const UID_PERTURB_LOW = 0x7f4a7c15;

  function umul32(a, b) {
    const aLow = a & 0xffff;
    const aHigh = a >>> 16;
    const bLow = b & 0xffff;
    const bHigh = b >>> 16;
    const lowLow = aLow * bLow;
    const middle = aHigh * bLow + aLow * bHigh;
    const lowSum = lowLow + (middle % 0x10000) * 0x10000;
    const high =
      aHigh * bHigh +
      Math.floor(middle / 0x10000) +
      Math.floor(lowSum / 0x100000000);
    return [high >>> 0, lowSum >>> 0];
  }

  // (high:low) * (primeHigh:primeLow) mod 2^64. The `high * primeHigh` term
  // lands entirely at bit 64 and above, so only the low halves of the cross
  // products survive.
  function multiply64(high, low, primeHigh, primeLow) {
    const lowLow = umul32(low, primeLow);
    const crossHigh = umul32(high, primeLow);
    const crossLow = umul32(low, primeHigh);
    const middle = (crossHigh[1] + crossLow[1]) >>> 0;
    return [(lowLow[0] + middle) >>> 0, lowLow[1]];
  }

  function fnv1a64(state, bytes) {
    let high = state[0];
    let low = state[1];
    for (const byte of bytes) {
      const product = multiply64(high, (low ^ byte) >>> 0, FNV_PRIME_HIGH, FNV_PRIME_LOW);
      high = product[0];
      low = product[1];
    }
    return [high, low];
  }

  function hex32(value) {
    return (value >>> 0).toString(16).padStart(8, "0");
  }

  function uidHash(salt, mac, stamp) {
    let state = [FNV_OFFSET_HIGH, FNV_OFFSET_LOW];
    state = fnv1a64(state, utf8Encode(salt));
    state = fnv1a64(state, mac);
    return fnv1a64(state, stamp);
  }

  function generateUid(deviceId, timestampMs, seed) {
    const digits = String(deviceId || "").replace(/[^0-9a-fA-F]/g, "");
    const mac =
      digits.length === 12
        ? [
            parseInt(digits.slice(0, 2), 16),
            parseInt(digits.slice(2, 4), 16),
            parseInt(digits.slice(4, 6), 16),
            parseInt(digits.slice(6, 8), 16),
            parseInt(digits.slice(8, 10), 16),
            parseInt(digits.slice(10, 12), 16),
          ]
        : [0, 0, 0, 0, 0, 0];
    const value = (timestampMs + (Number(seed) || 0)) % 0x10000000000000000;
    const stamp = [];
    for (let index = 0; index < 8; index++) {
      stamp.push(Math.floor(value / Math.pow(2, index * 8)) & 0xff);
    }
    const high = uidHash("BK-GRIND-DEFAULT-H-V1", mac, stamp);
    let low = uidHash("BK-GRIND-DEFAULT-L-V1", mac, stamp);
    if (
      (high[0] === 0 && high[1] === 0) ||
      (high[0] === 0xff && high[1] === 0xff)
    ) {
      low = [(low[0] ^ UID_PERTURB_HIGH) >>> 0, (low[1] ^ UID_PERTURB_LOW) >>> 0];
    }
    return hex32(high[0]) + hex32(high[1]) + hex32(low[0]) + hex32(low[1]);
  }

  return {
    id: "bookoo-mt80.reaplugin",
    onLoad() {
      return host.devices.bindDriver("mt80", {
        create(device) {
          let context = null;
          let sequence = 0;
          let pending = null;
          let rxState = null;
          let handshake = null;

          function send(json) {
            const bytes = utf8Encode(json);
            if (bytes.length === 0 || bytes.length > maxTotalLength) {
              return Promise.reject(new Error("MT80 message length out of range"));
            }
            const currentSequence = sequence;
            sequence = (sequence + 1) & 0xffff;
            const frames = [];
            for (let offset = 0; offset < bytes.length; offset += fragmentPayload) {
              frames.push([
                magic,
                version,
                currentSequence & 0xff,
                (currentSequence >> 8) & 0xff,
                bytes.length & 0xff,
                (bytes.length >> 8) & 0xff,
                offset & 0xff,
                (offset >> 8) & 0xff,
                ...bytes.slice(offset, offset + fragmentPayload),
              ]);
            }
            let chain = Promise.resolve();
            for (const frame of frames) {
              chain = chain.then(() =>
                context.gatt.writeWithResponse(
                  service,
                  rx,
                  btoa(String.fromCharCode(...frame))
                )
              );
            }
            return chain;
          }

          function settlePending(response) {
            if (!pending) return;
            const key = Object.keys(response)[0];
            if (!key || key !== pending.module) return;
            const body = response[key];
            const current = pending;
            pending = null;
            clearTimeout(current.timer);
            if (body && body.result === "success") {
              current.resolve(body.data === undefined ? {} : body.data);
              return;
            }
            const error = (body && body.error) || {};
            current.reject(
              new Error(
                `MT80 ${key} failed: ${error.code || "UNKNOWN"}` +
                  (error.message ? ` - ${error.message}` : "")
              )
            );
          }

          function request(module, body) {
            if (!context) {
              return Promise.reject(new Error("MT80 session is not connected"));
            }
            if (pending) {
              return Promise.reject(new Error("MT80 request already in flight"));
            }
            return new Promise((resolve, reject) => {
              pending = {
                module,
                resolve,
                reject,
                timer: setTimeout(() => {
                  pending = null;
                  reject(new Error(`MT80 ${module} request timed out`));
                }, requestTimeoutMs),
              };
              send(JSON.stringify({ request: { [module]: body } })).catch((error) => {
                if (pending && pending.module === module) {
                  clearTimeout(pending.timer);
                  pending = null;
                }
                reject(error);
              });
            });
          }

          function reassemble(data, now) {
            const bytes = decodeBase64(data);
            if (!bytes || bytes.length <= headerSize) return null;
            if (bytes[0] !== magic || bytes[1] !== version) return null;
            const total = bytes[4] | (bytes[5] << 8);
            const offset = bytes[6] | (bytes[7] << 8);
            const payload = bytes.slice(headerSize);
            if (total === 0 || total > maxTotalLength) return null;
            if (offset === 0) {
              rxState = { total, bytes: payload, expiresAt: now + fragmentExpiryMs };
            } else {
              if (!rxState) return null;
              if (now > rxState.expiresAt) {
                rxState = null;
                return null;
              }
              if (offset !== rxState.bytes.length) return null;
              rxState.bytes = rxState.bytes.concat(payload);
              rxState.expiresAt = now + fragmentExpiryMs;
            }
            if (rxState.bytes.length < rxState.total) return null;
            const complete = rxState.bytes.slice(0, rxState.total);
            rxState = null;
            return utf8Decode(complete);
          }

          function deliver(json) {
            let message;
            try {
              message = JSON.parse(json);
            } catch (error) {
              return;
            }
            if (message.broadcast) {
              const info = message.broadcast.periodInfo;
              if (!info) return;
              if (handshake) {
                const current = handshake;
                handshake = null;
                clearTimeout(current.timer);
                current.resolve();
              }
              context.publish({ ...info });
              return;
            }
            if (message.response) settlePending(message.response);
          }

          function abortPending(reason) {
            const current = pending;
            pending = null;
            if (current) {
              clearTimeout(current.timer);
              current.reject(reason);
            }
            const waiting = handshake;
            handshake = null;
            if (waiting) {
              clearTimeout(waiting.timer);
              waiting.reject(reason);
            }
            rxState = null;
          }

          const dataChannels = [
            { key: "feedingRpm", type: "integer", unit: "rpm" },
            { key: "bladeGap", type: "integer", unit: "um" },
            { key: "grindRpm", type: "integer", unit: "rpm" },
            { key: "humidity", type: "integer", unit: "%RH" },
            { key: "devState", type: "string" },
            { key: "netState", type: "string" },
            { key: "totalGrinds", type: "integer" },
            { key: "cupDetect", type: "boolean" },
            { key: "autoStop", type: "boolean" },
            { key: "fastClean", type: "boolean" },
            { key: "brightness", type: "integer" },
            { key: "standbySec", type: "integer" },
            { key: "selectPreset", type: "integer" },
          ];

          const commands = [
            {
              id: "getSettings",
              name: "Read general settings",
              paramsSchema: { type: "object" },
              resultsSchema: { type: "object" },
            },
            {
              id: "setSettings",
              name: "Write general settings",
              paramsSchema: { type: "object" },
              resultsSchema: { type: "object" },
            },
            {
              id: "getSections",
              name: "Read grinding sections",
              paramsSchema: { type: "object" },
              resultsSchema: { type: "array" },
            },
            {
              id: "setSections",
              name: "Write grinding sections",
              paramsSchema: {
                type: "object",
                properties: { sections: { type: "array" } },
              },
              resultsSchema: { type: "array" },
            },
            {
              id: "getPresets",
              name: "Read presets",
              paramsSchema: { type: "object" },
              resultsSchema: { type: "array" },
            },
            {
              id: "addPreset",
              name: "Add a preset",
              paramsSchema: { type: "object" },
              resultsSchema: { type: "object" },
            },
            {
              id: "updatePreset",
              name: "Edit a preset",
              paramsSchema: { type: "object" },
              resultsSchema: { type: "object" },
            },
            {
              id: "deletePreset",
              name: "Delete a preset",
              paramsSchema: { type: "object" },
              resultsSchema: { type: "object" },
            },
            {
              id: "restorePreset",
              name: "Restore a deleted preset",
              paramsSchema: { type: "object" },
              resultsSchema: { type: "object" },
            },
            {
              id: "reorderPreset",
              name: "Reorder a preset",
              paramsSchema: { type: "object" },
              resultsSchema: { type: "object" },
            },
            {
              id: "importPresets",
              name: "Import presets",
              paramsSchema: {
                type: "object",
                properties: { presets: { type: "array" } },
              },
              resultsSchema: { type: "array" },
            },
            {
              id: "getRecycleBin",
              name: "Read the preset recycle bin",
              paramsSchema: { type: "object" },
              resultsSchema: { type: "array" },
            },
          ];

          function presetSelector(uid) {
            return { type: "uid", value: uid };
          }

          async function execute({ commandId, params }) {
            const input = params || {};
            switch (commandId) {
              case "getSettings":
                return request("geneSetting", {
                  op: "get",
                  selector: { type: "all" },
                });
              case "setSettings":
                return request("geneSetting", { op: "set", data: input });
              case "getSections":
                return {
                  sections: await request("grindSection", {
                    op: "get",
                    selector: { type: "all" },
                  }),
                };
              case "setSections":
                return {
                  sections: await request("grindSection", {
                    op: "set",
                    data: input.sections,
                  }),
                };
              case "getPresets":
                return {
                  presets: await request("grindPreset", {
                    op: "get",
                    selector: { type: "all" },
                  }),
                };
              case "importPresets":
                return {
                  presets: await request("grindPreset", {
                    op: "set",
                    data: input.presets,
                  }),
                };
              case "addPreset":
                return request("grindPreset", {
                  op: "add",
                  data: {
                    uid:
                      typeof input.uid === "string" && input.uid.length === 32
                        ? input.uid
                        : generateUid(device.id, Date.now(), input.seed),
                    index: input.index,
                    name: input.name,
                    note: input.note === undefined ? "" : input.note,
                    bladeGap: input.bladeGap,
                    feedingRpm: input.feedingRpm,
                    grindRpm: input.grindRpm,
                  },
                });
              case "updatePreset": {
                const data = {};
                for (const key of [
                  "name",
                  "note",
                  "bladeGap",
                  "feedingRpm",
                  "grindRpm",
                ]) {
                  if (input[key] !== undefined) data[key] = input[key];
                }
                return request("grindPreset", {
                  op: "update",
                  selector: presetSelector(input.uid),
                  data,
                });
              }
              case "deletePreset":
                return request("grindPreset", {
                  op: "delete",
                  selector: presetSelector(input.uid),
                });
              case "restorePreset": {
                const body = {
                  op: "restore",
                  selector: presetSelector(input.uid),
                };
                if (input.index !== undefined) body.data = { index: input.index };
                return request("grindPreset", body);
              }
              case "reorderPreset":
                return request("grindPreset", {
                  op: "reorder",
                  data: { uid: input.uid, index: input.index },
                });
              case "getRecycleBin":
                return {
                  deleted: await request("grindPreset", {
                    op: "get",
                    selector: { type: "tombstones" },
                  }),
                };
              default:
                throw new Error(`Unknown MT80 command: ${commandId}`);
            }
          }

          return {
            vendor: "Bookoo",
            dataChannels,
            commands,
            async connect(session) {
              const services = await session.gatt.discoverServices();
              if (!services.includes(service)) {
                throw new Error("Bookoo MT80 service unavailable");
              }
              context = session;
              sequence = 0;
              rxState = null;
              pending = null;
              handshake = null;
              const firstPeriodInfo = new Promise((resolve, reject) => {
                handshake = {
                  resolve,
                  reject,
                  timer: setTimeout(
                    () => reject(new Error("MT80 handshake timed out")),
                    handshakeTimeoutMs
                  ),
                };
              });
              firstPeriodInfo.catch(() => {});
              session.gatt.onDisconnect(() => {
                abortPending(new Error("MT80 disconnected"));
                context = null;
              });
              await session.gatt.subscribe(service, tx, (data) => {
                const json = reassemble(data, Date.now());
                if (json !== null) deliver(json);
              });
              await send(
                JSON.stringify({ request: { appHello: { op: "handshake" } } })
              );
              await firstPeriodInfo;
            },
            disconnect() {
              abortPending(new Error("MT80 disconnected"));
              context = null;
            },
            execute,
          };
        },
      });
    },
  };
}

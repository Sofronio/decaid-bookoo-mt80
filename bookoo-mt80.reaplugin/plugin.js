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

  function renderUi() {
    return [
      '<!doctype html><html lang="zh"><head><meta charset="utf-8">',
      '<meta name="viewport" content="width=device-width,initial-scale=1">',
      '<title>Bookoo MT80</title><style>',
      ':root{--bg:#0b0b0d;--card:#16161a;--line:#28282f;--fg:#ececf1;--muted:#8b8b96;--accent:#5eead4}',
      '*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);',
      'font:14px/1.5 ui-sans-serif,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif}',
      'header{display:flex;align-items:center;gap:12px;padding:16px 20px;border-bottom:1px solid var(--line)}',
      'h1{font-size:16px;margin:0;font-weight:600}',
      '.dot{width:8px;height:8px;border-radius:50%;background:#ef4444}.dot.on{background:var(--accent)}',
      '#conn{color:var(--muted);font-size:12px}',
      'button{background:var(--card);color:var(--fg);border:1px solid var(--line);border-radius:8px;',
      'padding:6px 10px;font:inherit;cursor:pointer}button:hover{border-color:#3f3f4a}',
      'main{padding:16px 20px;display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));align-items:start}',
      '.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px}',
      'h2{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:0 0 10px}',
      '.readout{grid-column:1/-1;display:flex;flex-wrap:wrap;gap:28px;align-items:baseline}',
      '.big{font-size:52px;font-weight:600;font-variant-numeric:tabular-nums}',
      '.big small{font-size:16px;color:var(--muted);margin-left:6px;font-weight:400}',
      '.sub{color:var(--muted)}.sub b{color:var(--fg);font-weight:600}',
      'table{width:100%;border-collapse:collapse}td{padding:4px 0;vertical-align:middle}',
      'td:first-child{color:var(--muted)}td:last-child{text-align:right;font-weight:500;font-variant-numeric:tabular-nums}',
      '.row{display:grid;grid-template-columns:88px 1fr 52px;gap:10px;align-items:center;padding:5px 0}',
      '.row label{color:var(--muted);font-size:13px}',
      '.row output{text-align:right;font-variant-numeric:tabular-nums}',
      'input[type=range]{width:100%;accent-color:var(--accent)}',
      '.chips{display:flex;flex-wrap:wrap;gap:8px}',
      '.chip{padding:5px 11px;border-radius:999px;border:1px solid var(--line);background:#1d1d22;',
      'cursor:pointer;font-size:13px}.chip:hover{border-color:#3f3f4a}',
      '.chip.on{border-color:var(--accent);color:var(--accent)}',
      '.chip small{color:var(--muted);margin-left:6px}',
      '.toggles{display:flex;flex-wrap:wrap;gap:14px;margin-top:10px}',
      '.toggle{display:flex;align-items:center;gap:7px;cursor:pointer;font-size:13px}',
      '.toggle input{accent-color:var(--accent)}',
      '#logs{max-height:260px;overflow:auto;font:12px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace}',
      '.log{display:flex;gap:8px;padding:2px 0;border-bottom:1px solid #1e1e23}',
      '.log i{font-style:normal;flex:0 0 34px;color:var(--muted)}',
      '.log.send i{color:#60a5fa}.log.response i{color:#fbbf24}.log.broadcast i{color:#6b7280}',
      '.log span{word-break:break-all;color:#c9c9d1}',
      '.note{color:var(--muted);font-size:12px;margin-top:8px}',
      '</style></head><body>',
      '<header><h1>Bookoo MT80</h1><span class="dot" id="dot"></span>',
      '<span id="conn">--</span>',
      '<span style="flex:1"></span>',
      '<button id="lang">English</button></header>',
      '<main>',
      '<section class="card readout">',
      '<div><div class="big"><span id="bladeGap">--</span><small>um</small></div>',
      '<div class="sub" id="state">--</div></div>',
      '<div class="sub" id="rpm"></div>',
      '</section>',
      '<section class="card"><h2 id="h-status">Live</h2><table id="status"></table></section>',
      '<section class="card"><h2 id="h-set">Settings</h2><div id="sliders"></div>',
      '<div class="toggles" id="toggles"></div><div class="note" id="setNote"></div></section>',
      '<section class="card"><h2 id="h-preset">Presets</h2><div class="chips" id="presets"></div>',
      '<h2 id="h-section" style="margin-top:14px">Sections</h2><div class="chips" id="sections"></div>',
      '<div class="note" id="secNote"></div></section>',
      '<section class="card"><h2>Logs</h2><div id="logs"></div></section>',
      '</main><script>',
      'var ENDPOINT=location.pathname;',
      'var LANG="zh";',
      'var T={zh:{live:"\\u5b9e\\u65f6\\u72b6\\u6001",settings:"\\u5b9e\\u65f6\\u8bbe\\u7f6e",presets:"\\u9884\\u8bbe",sections:"\\u7814\\u78e8\\u6bb5",',
      'connected:"\\u5df2\\u8fde\\u63a5",offline:"\\u672a\\u8fde\\u63a5",drag:"\\u6ed1\\u5757\\u62d6\\u52a8\\u5373\\u53d1\\u9001",',
      'cumulative:"\\u7d2f\\u8ba1\\u7814\\u78e8",humidity:"\\u6e7f\\u5ea6",network:"\\u7f51\\u7edc",serial:"\\u5e8f\\u5217\\u53f7",',
      'sectionNote:"\\u70b9\\u51fb\\u5206\\u6bb5\\u53ea\\u5199\\u5165\\u5bf9\\u5e94\\u7684\\u7814\\u78e8\\u5ea6\\u6570\\u503c\\uff0c\\u4e0d\\u4f1a\\u6539\\u53d8\\u7269\\u7406\\u5200\\u76d8\\u95f4\\u8ddd\\u3002"},',
      'en:{live:"Live",settings:"Settings",presets:"Presets",sections:"Sections",connected:"Connected",',
      'offline:"Not connected",drag:"drag to send",cumulative:"Total grinds",humidity:"Humidity",',
      'network:"Network",serial:"Serial",sectionNote:"A section click only writes that grind-size value; it does not move the physical burr."}};',
      'var LABEL={feedingRpm:["Feed RPM","\\u4e0b\\u8c46\\u901f\\u5ea6"],grindRpm:["Grind RPM","\\u5200\\u76d8\\u8f6c\\u901f"],',
      'bladeGap:["Grind size","\\u7814\\u78e8\\u5ea6"],brightness:["Brightness","\\u4eae\\u5ea6"],standbySec:["Standby","\\u7184\\u5c4f\\u79d2"],',
      'cupDetect:["Cup detect","\\u676f\\u68c0"],autoStop:["Auto stop","\\u81ea\\u52a8\\u505c\\u6b62"],fastClean:["Fast clean","\\u5f3a\\u529b\\u6e05\\u7c89"],',
      'devState:["State","\\u72b6\\u6001"],netState:["Network","\\u7f51\\u7edc"],totalGrinds:["Total grinds","\\u7d2f\\u8ba1\\u7814\\u78e8"]};',
      'var STATE={IDLE:["Idle","\\u5f85\\u673a\\u4e2d"],GRINDING:["Grinding","\\u7814\\u78e8\\u4e2d"],',
      'HighSpeedClean:["High-speed clean","\\u9ad8\\u8f6c\\u6392\\u7c89"],SETTING:["Setting","\\u8bbe\\u7f6e\\u4e2d"]};',
      // Official geneSetting ranges; the device rejects anything outside them.
      'var RANGES={feedingRpm:[10,65,1],grindRpm:[500,1500,10],bladeGap:[0,999,1],brightness:[1,5,1],standbySec:[60,900,10]};',
      'var BOOLS=["cupDetect","autoStop","fastClean"];',
      'var slidersBuilt=false;var last={};var deb={};var cached={snapshot:null,presets:[],sections:[]};',
      'function t(k){return T[LANG][k]}',
      'function label(k){var e=LABEL[k];return e?(LANG==="zh"?e[1]:e[0]):k}',
      'function post(commandId,params){return fetch(ENDPOINT,{method:"POST",headers:{"Content-Type":"application/json"},',
      'body:JSON.stringify({commandId:commandId,params:params||{}})}).then(function(r){return r.json()}).then(function(r){',
      'if(!r.ok)throw new Error(r.error);return r.result})}',
      'function buildSliders(){var host=document.getElementById("sliders");',
      'Object.keys(RANGES).forEach(function(key){var r=RANGES[key];',
      'var row=document.createElement("div");row.className="row";',
      'row.innerHTML=\'<label></label><input type="range"><output></output>\';',
      'var lab=row.querySelector("label"),inp=row.querySelector("input"),out=row.querySelector("output");',
      'lab.textContent=label(key);inp.min=r[0];inp.max=r[1];inp.step=r[2];',
      'inp.addEventListener("input",function(){out.textContent=inp.value;clearTimeout(deb[key]);',
      'deb[key]=setTimeout(function(){post("setSettings",JSON.parse(\'{"\'+key+\'":\'+inp.value+"}")).catch(function(e){console.warn(e)})},250)});',
      'row.dataset.key=key;host.appendChild(row)});',
      'var th=document.getElementById("toggles");',
      'BOOLS.forEach(function(key){var w=document.createElement("label");w.className="toggle";',
      'w.innerHTML=\'<input type="checkbox"><span></span>\';',
      'w.querySelector("span").textContent=label(key);w.dataset.key=key;',
      'w.querySelector("input").addEventListener("change",function(e){var o={};o[key]=e.target.checked;',
      'post("setSettings",o).catch(function(err){console.warn(err)})});',
      'th.appendChild(w)});slidersBuilt=true}',
      'function paintSettings(s){if(!slidersBuilt)buildSliders();',
      'Object.keys(RANGES).forEach(function(key){var v=s[key];if(v===undefined||v===null)return;',
      'var row=document.querySelector(\'.row[data-key="\'+key+\'"]\');',
      'if(!row||document.activeElement===row.querySelector("input"))return;',
      'row.querySelector("input").value=v;row.querySelector("output").textContent=v});',
      'BOOLS.forEach(function(key){var v=s[key];if(v===undefined||v===null)return;',
      'var w=document.querySelector(\'.toggle[data-key="\'+key+\'"]\');',
      'if(w)w.querySelector("input").checked=!!v})}',
      'function paintPresets(presets,selected){var host=document.getElementById("presets");host.textContent="";',
      'if(!presets.length){host.innerHTML=\'<span class="note">\\u2014</span>\';return}',
      'presets.forEach(function(p){var b=document.createElement("button");b.className="chip"+(p.index===selected?" on":"");',
      'b.innerHTML=String(p.name).replace(/[<>&]/g,"")+"<small>"+p.bladeGap+"</small>";',
      'b.addEventListener("click",function(){post("setSettings",{selectPreset:p.index}).catch(function(e){console.warn(e)})});',
      'host.appendChild(b)})}',
      'function paintSections(sections){var host=document.getElementById("sections");host.textContent="";',
      'sections.forEach(function(s){var b=document.createElement("button");b.className="chip";',
      'b.innerHTML=String(s.name).replace(/[<>&]/g,"")+"<small>"+s.range[0]+"-"+s.range[1]+"</small>";',
      'b.addEventListener("click",function(){post("setSettings",{bladeGap:s.range[0]}).catch(function(e){console.warn(e)})});',
      'host.appendChild(b)})}',
      'function paintStatus(s,connected){var rows=[',
      '[label("devState"),s?(STATE[s.devState]?(LANG==="zh"?STATE[s.devState][1]:STATE[s.devState][0]):s.devState):"\\u2014"],',
      '[label("humidity"),(s&&s.humidity!=null?s.humidity+" %RH":"\\u2014")],',
      '[label("totalGrinds"),(s&&s.totalGrinds!=null?s.totalGrinds:"\\u2014")],',
      '[label("netState"),(s&&s.netState?s.netState:"\\u2014")],',
      '[t("serial"),(cached.baseInfo&&cached.baseInfo.snCode)?cached.baseInfo.snCode:"\\u2014"],',
      '["",connected?t("connected"):t("offline")]];',
      'document.getElementById("status").innerHTML=rows.map(function(r){',
      'return "<tr><td>"+r[0]+"</td><td>"+String(r[1]).replace(/[<>&]/g,"")+"</td></tr>"}).join("")}',
      'function paintLogs(logs){var host=document.getElementById("logs");',
      'host.innerHTML=logs.slice().reverse().map(function(l){return \'<div class="log \'+l.kind+\'"><i>\'+l.kind+\'</i><span>\'+',
      'String(l.text).replace(/[<>&]/g,"")+"</span></div>"}).join("")}',
      'function apply(d){if(!d)return;cached=d;var s=d.snapshot;var c=!!d.connected;',
      'document.getElementById("dot").className="dot"+(c?" on":"");',
      'document.getElementById("conn").textContent=c?t("connected"):t("offline");',
      'document.getElementById("bladeGap").textContent=s&&s.bladeGap!=null?s.bladeGap:"--";',
      'document.getElementById("state").textContent=s&&s.devState?(STATE[s.devState]?(LANG==="zh"?STATE[s.devState][1]:STATE[s.devState][0]):s.devState):"--";',
      'document.getElementById("rpm").innerHTML=s?\'<b>\'+s.feedingRpm+\'</b> feed &middot; <b>\'+s.grindRpm+\'</b> grind &middot; <b>\'+s.humidity+\'</b> %RH\':"";',
      'paintStatus(s,c);paintSettings(s||{});paintLogs(d.logs||[])}',
      'function labels(){document.getElementById("h-status").textContent=t("live");',
      'document.getElementById("h-set").textContent=t("settings")+" ("+t("drag")+")";',
      'document.getElementById("h-preset").textContent=t("presets");',
      'document.getElementById("h-section").textContent=t("sections");',
      'document.getElementById("secNote").textContent=t("sectionNote");',
      'document.querySelectorAll(".row").forEach(function(r){r.querySelector("label").textContent=label(r.dataset.key)});',
      'document.querySelectorAll(".toggle").forEach(function(w){w.querySelector("span").textContent=label(w.dataset.key)});',
      'document.getElementById("lang").textContent=LANG==="zh"?"English":"\\u4e2d\\u6587"}',
      'function tick(){fetch(ENDPOINT+"?state=1").then(function(r){return r.json()}).then(apply).catch(function(){})}',
      'document.getElementById("lang").addEventListener("click",function(){LANG=LANG==="zh"?"en":"zh";labels();',
      'paintPresets(cached.presets,(cached.snapshot||{}).selectPreset);paintStatus(cached.snapshot,!!cached.connected)});',
      'function loadLists(){post("getPresets").then(function(r){cached.presets=r.presets||[];',
      'paintPresets(cached.presets,(cached.snapshot||{}).selectPreset)}).catch(function(){}).then(function(){',
      'return post("getSections")}).then(function(r){cached.sections=r.sections||[];',
      'paintSections(cached.sections)}).catch(function(){})}',
      'labels();buildSliders();tick();loadLists();setInterval(tick,500);setInterval(loadLists,15000);',
      '</script></body></html>',
    ].join("");
  }

  // The loader aliases `handleHttpRequest` on the object `createPlugin`
  // returns, not on the device the driver factory returns, so the driver
  // publishes its handler here.
  let deviceHandler = null;

  return {
    id: "bookoo-mt80.reaplugin",
    handleHttpRequest(request) {
      const json = (value) => ({
        status: 200,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(value),
      });
      if (request.method === "GET") {
        if (request.query && request.query.state === "1") {
          return json(
            deviceHandler
              ? deviceHandler.state()
              : { connected: false, snapshot: null, baseInfo: null, logs: [] }
          );
        }
        // The page is device-independent, so it renders before anything binds
        // and simply reports "not connected".
        return {
          status: 200,
          headers: { "Content-Type": "text/html; charset=utf-8" },
          body: renderUi(),
        };
      }
      if (request.method === "POST") {
        if (!deviceHandler) {
          return json({ ok: false, error: "no MT80 device bound" });
        }
        return Promise.resolve(deviceHandler.post(request.body || {})).then(
          json
        );
      }
      return {
        status: 405,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ok: false, error: "method not allowed" }),
      };
    },
    onLoad() {
      return host.devices.bindDriver("mt80", {
        create(device) {
          let context = null;
          let sequence = 0;
          let pending = null;
          let rxState = null;
          let handshake = null;
          let snapshot = null;
          let baseInfo = null;
          const logs = [];

          function log(kind, text) {
            logs.push({ kind, text, at: Date.now() });
            if (logs.length > 200) logs.splice(0, logs.length - 200);
          }

          function send(json) {
            const bytes = utf8Encode(json);
            if (bytes.length === 0 || bytes.length > maxTotalLength) {
              return Promise.reject(new Error("MT80 message length out of range"));
            }
            log("send", json);
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
              if (message.broadcast.baseInfo) {
                baseInfo = { ...message.broadcast.baseInfo };
                log("broadcast", json);
              }
              const info = message.broadcast.periodInfo;
              if (!info) return;
              if (handshake) {
                const current = handshake;
                handshake = null;
                clearTimeout(current.timer);
                current.resolve();
              }
              snapshot = { ...info };
              log("broadcast", json);
              context.publish({ ...info });
              return;
            }
            if (message.response) {
              log("response", json);
              settlePending(message.response);
            }
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


          function uiState() {
            return {
              connected: context !== null,
              snapshot,
              baseInfo,
              logs: logs.slice(-120),
            };
          }

          // The page drives the same command surface the Sensor API exposes;
          // the HTTP layer is transport only, not a second vocabulary.
          async function handlePost(body) {
            try {
              const result = await execute({
                commandId: body.commandId,
                params: body.params || {},
              });
              return { ok: true, result };
            } catch (error) {
              return {
                ok: false,
                error: String(error && error.message ? error.message : error),
              };
            }
          }

          deviceHandler = { state: uiState, post: handlePost };

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

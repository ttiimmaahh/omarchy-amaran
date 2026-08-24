#!/usr/bin/env node
// A stand-in for the amaran BLE daemon's REST API, for developing this widget
// without a Bluetooth radio or a light in the room. It speaks the same routes
// as wesbos/amaran-BLE-control's daemon and logs every command it receives.
//
//   node tools/mock-daemon.mjs [--port 2708] [--with-state] [--api-key KEY]
//
// --with-state makes GET / also report live fixture state, which the real
// daemon does not do today. The widget honours it when present, so this
// exercises that path.

import http from "node:http";

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const at = args.indexOf(name);
  return at === -1 ? fallback : args[at + 1];
};

const port = Number(flag("--port", 2708));
const apiKey = flag("--api-key", "");
const withState = args.includes("--with-state");

const lights = [
  { key: "keylight", name: "Verge Key", mac: "A4:C1:38:13:41:38", address: 2 },
  { key: "fill", name: "Verge Fill", mac: "A4:C1:38:13:30:86", address: 4 },
];

// Mirrors the real daemon's internal Home Assistant shaped state map.
const state = new Map(
  lights.map((l) => [l.key, { state: "OFF", brightness: 128, color_temp: 179 }]),
);

const json = (res, status, body) => {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
};

const readBody = (req) =>
  new Promise((resolve) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      try {
        resolve(raw ? JSON.parse(raw) : {});
      } catch {
        resolve({});
      }
    });
  });

const patch = (key, next) => {
  for (const light of key === "all" ? lights : lights.filter((l) => l.key === key)) {
    state.set(light.key, { ...state.get(light.key), ...next });
  }
};

const server = http.createServer(async (req, res) => {
  if (apiKey && req.headers.authorization !== `Bearer ${apiKey}`) {
    return json(res, 401, { ok: false, error: "Unauthorized" });
  }

  const url = req.url ?? "/";
  const method = req.method ?? "GET";

  if (method === "GET" && (url === "/" || url === "/lights")) {
    const roster = withState
      ? lights.map((l) => ({ ...l, ...state.get(l.key) }))
      : lights;
    return json(res, 200, { ok: true, lights: roster, daemon: true });
  }

  const all = url.match(/^\/lights\/(on|off)$/);
  if (method === "POST" && all) {
    console.log(`[mock] ALL → ${all[1].toUpperCase()}`);
    patch("all", { state: all[1].toUpperCase() });
    return json(res, 200, { ok: true, result: "ok" });
  }

  const one = url.match(/^\/lights\/([^/]+)\/([^/]+)$/);
  if (method === "POST" && one) {
    const [, key, cmd] = one;
    const body = await readBody(req);
    if (key !== "all" && !lights.some((l) => l.key === key)) {
      return json(res, 400, { ok: false, error: `Unknown light: "${key}"` });
    }
    if (cmd === "on" || cmd === "off") {
      console.log(`[mock] ${key} → ${cmd.toUpperCase()}`);
      patch(key, { state: cmd.toUpperCase() });
    } else if (cmd === "brightness") {
      console.log(`[mock] ${key} brightness → ${body.value}%`);
      patch(key, { state: "ON", brightness: Math.round((body.value ?? 0) * 2.55) });
    } else if (cmd === "cct") {
      console.log(`[mock] ${key} CCT → ${body.brightness}%, ${body.kelvin}K`);
      patch(key, {
        state: "ON",
        brightness: Math.round((body.brightness ?? 0) * 2.55),
        color_temp: Math.round(1000000 / (body.kelvin || 5600)),
      });
    } else if (cmd === "hsi" || cmd === "hsl") {
      console.log(`[mock] ${key} HSI → ${body.brightness}%, ${body.hue}°, ${body.saturation}%`);
      patch(key, { state: "ON" });
    } else {
      return json(res, 400, { ok: false, error: `Unknown command: ${cmd}` });
    }
    return json(res, 200, { ok: true, result: "ok" });
  }

  json(res, 404, { ok: false, error: `No route for ${method} ${url}` });
});

server.listen(port, "127.0.0.1", () => {
  console.log(`[mock] amaran daemon stand-in on http://127.0.0.1:${port}`);
  console.log(`[mock] lights: ${lights.map((l) => l.key).join(", ")}${withState ? " (reporting state)" : ""}`);
});

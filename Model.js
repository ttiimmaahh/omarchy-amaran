// Pure helpers for the Amaran bar widget. No QML types are touched here so the
// whole file stays trivially testable and cheap to re-evaluate during a drag.

function clamp(value, low, high) {
  var n = Number(value)
  if (isNaN(n)) return low
  return Math.max(low, Math.min(high, n))
}

// Tanner Helland's blackbody approximation, good enough over the 1800-10000K
// range a video light actually covers. Returned as "#rrggbb" so it can be
// assigned straight to a QML color property.
function kelvinToColor(kelvin) {
  var temp = clamp(kelvin, 1000, 40000) / 100
  var r, g, b

  if (temp <= 66) {
    r = 255
    g = 99.4708025861 * Math.log(temp) - 161.1195681661
    b = temp <= 19 ? 0 : 138.5177312231 * Math.log(temp - 10) - 305.0447927307
  } else {
    r = 329.698727446 * Math.pow(temp - 60, -0.1332047592)
    g = 288.1221695283 * Math.pow(temp - 60, -0.0755148492)
    b = 255
  }

  return "#" + [r, g, b].map(function (channel) {
    var byte = Math.round(clamp(channel, 0, 255))
    return (byte < 16 ? "0" : "") + byte.toString(16)
  }).join("")
}

function formatKelvin(kelvin) {
  return Math.round(clamp(kelvin, 0, 100000)) + "K"
}

function formatPercent(percent) {
  return Math.round(clamp(percent, 0, 100)) + "%"
}

// One line summarising a fixture for the row header: "62% · 5600K" / "Off".
function describeLight(light) {
  if (!light) return ""
  if (!light.on) return "Off"
  return formatPercent(light.brightness) + " · " + formatKelvin(light.kelvin)
}

function describeCount(onCount, total) {
  if (total === 0) return "No lights configured"
  if (onCount === 0) return total === 1 ? "Off" : "All off"
  if (onCount === total) return total === 1 ? "On" : "All on"
  return onCount + " of " + total + " on"
}

// The daemon's GET / only guarantees the static roster (key, name, mac,
// address). Anything it does volunteer about live state is honoured, in either
// the Home Assistant shape it uses internally or a plain one, so a patched
// daemon or an ESP32 bridge lights this widget up with no changes here.
function adoptState(entry, previous, defaults) {
  var state = {
    key: String(entry.key),
    name: String(entry.name || entry.key),
    mac: String(entry.mac || ""),
    address: Number(entry.address) || 0,
    on: previous ? previous.on : false,
    brightness: previous ? previous.brightness : defaults.brightness,
    kelvin: previous ? previous.kelvin : defaults.kelvin
  }

  if (entry.state === "ON" || entry.state === "OFF") state.on = entry.state === "ON"
  else if (typeof entry.on === "boolean") state.on = entry.on

  // Home Assistant reports brightness as 0-255; a plain daemon may use 0-100.
  if (typeof entry.brightness === "number") {
    state.brightness = entry.brightness > 100
      ? clamp(Math.round(entry.brightness / 2.55), 0, 100)
      : clamp(Math.round(entry.brightness), 0, 100)
  }

  // color_temp is in mireds, kelvin is in kelvin.
  if (typeof entry.color_temp === "number" && entry.color_temp > 0) {
    state.kelvin = Math.round(1000000 / entry.color_temp)
  } else if (typeof entry.kelvin === "number" && entry.kelvin > 0) {
    state.kelvin = Math.round(entry.kelvin)
  }

  return state
}

// Merge a fresh roster with what we already knew, so a poll never blanks the
// sliders. Lights the daemon has dropped disappear; new ones arrive at the
// caller's defaults.
function mergeRoster(roster, previousLights, defaults) {
  var byKey = {}
  for (var p = 0; p < previousLights.length; p++) byKey[previousLights[p].key] = previousLights[p]

  var merged = []
  for (var i = 0; i < roster.length; i++) {
    var entry = roster[i]
    if (!entry || entry.key === undefined || entry.key === null) continue
    merged.push(adoptState(entry, byKey[String(entry.key)], defaults))
  }
  return merged
}

// Restore persisted state onto the live roster after a shell restart. Only
// fixtures the daemon still reports survive.
function applySnapshot(lights, snapshot) {
  if (!snapshot || typeof snapshot !== "object") return lights
  return lights.map(function (light) {
    var saved = snapshot[light.key]
    if (!saved || typeof saved !== "object") return light
    return {
      key: light.key,
      name: light.name,
      mac: light.mac,
      address: light.address,
      on: typeof saved.on === "boolean" ? saved.on : light.on,
      brightness: typeof saved.brightness === "number" ? clamp(Math.round(saved.brightness), 0, 100) : light.brightness,
      kelvin: typeof saved.kelvin === "number" ? Math.round(saved.kelvin) : light.kelvin
    }
  })
}

function snapshotOf(lights) {
  var snapshot = {}
  for (var i = 0; i < lights.length; i++) {
    snapshot[lights[i].key] = {
      on: lights[i].on,
      brightness: lights[i].brightness,
      kelvin: lights[i].kelvin
    }
  }
  return snapshot
}

// Parse the daemon's GET / envelope: { ok: true, lights: [...] }.
function parseRoster(raw) {
  var parsed = JSON.parse(String(raw || ""))
  if (!parsed || typeof parsed !== "object") throw new Error("daemon returned a non-object")
  if (parsed.ok === false) throw new Error(String(parsed.error || "daemon reported an error"))
  var lights = parsed.lights
  if (!(lights instanceof Array)) throw new Error("daemon response has no lights array")
  return lights
}

// curl writes the transport failure to stderr; the daemon writes protocol
// failures into a JSON body. Turn either into one short human sentence.
function describeFailure(exitCode, stderr, stdout) {
  var err = String(stderr || "").trim()
  var out = String(stdout || "").trim()

  if (out) {
    try {
      var parsed = JSON.parse(out)
      if (parsed && parsed.error) return String(parsed.error)
    } catch (e) { /* not JSON, fall through to the curl diagnosis */ }
  }

  if (exitCode === 7) return "Cannot reach the daemon"
  if (exitCode === 28) return "Daemon timed out"
  if (exitCode === 22) return err.indexOf("401") !== -1 ? "Daemon rejected the API key" : "Daemon returned an error"
  if (err) return err.split("\n")[0]
  return "Daemon request failed (curl " + exitCode + ")"
}

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Talks to the amaran BLE mesh daemon's REST API over curl, the same way the
// first-party weather widget talks to its provider. Everything the panel
// renders lives here; Panel.qml only draws it.
//
// The daemon's GET / is a roster plus a health check — it does not report live
// dimmer state — so this service is the source of truth for what each fixture
// is doing, updated optimistically the moment you touch a control and
// persisted so a shell restart does not forget. Model.adoptState still honours
// live state if a daemon ever volunteers it.
Item {
  id: root

  property var settings: ({})

  readonly property string host: String(setting("host", "127.0.0.1"))
  readonly property int port: intSetting("port", 2708, 1, 65535)
  readonly property string apiKey: String(setting("apiKey", ""))
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 5, 3600)
  readonly property int minKelvin: intSetting("minKelvin", 2700, 1800, 10000)
  readonly property int maxKelvin: Math.max(minKelvin + 100, intSetting("maxKelvin", 6500, 1800, 10000))
  readonly property string baseUrl: "http://" + host + ":" + port

  // Where a fixture starts before anyone has touched it or the daemon has said
  // otherwise. Mid-brightness at daylight balance is the least surprising
  // thing to hand someone who then drags a slider.
  readonly property var defaultState: ({ brightness: 50, kelvin: Math.round((minKelvin + maxKelvin) / 2) })

  property var lights: []
  property bool reachable: false
  property bool everChecked: false
  property string lastError: ""

  readonly property int count: lights.length
  readonly property int litCount: {
    var n = 0
    for (var i = 0; i < lights.length; i++) if (lights[i].on) n++
    return n
  }
  readonly property bool anyOn: litCount > 0
  readonly property bool busy: cmdProc.running
  readonly property string statusText: {
    if (!everChecked) return "Connecting…"
    if (!reachable) return lastError || "Daemon unreachable"
    return Model.describeCount(litCount, count)
  }

  // Where the BLE daemon (and its key-bearing lights.json) lives, so the
  // panel's setup button can hand the wizard the right directory.
  readonly property string daemonDir: String(setting("daemonDir", Quickshell.env("HOME") + "/amaran-BLE-control"))

  readonly property string home: Quickshell.env("HOME")
  readonly property string statePath: home + "/.local/state/omarchy-amaran/state.json"

  signal commandFailed(string message)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, low, high) {
    var parsed = parseInt(setting(name, fallback), 10)
    if (isNaN(parsed)) parsed = fallback
    return Math.max(low, Math.min(high, parsed))
  }

  function lightFor(key) {
    for (var i = 0; i < lights.length; i++) if (lights[i].key === key) return lights[i]
    return null
  }

  // ---- Local state -------------------------------------------------------

  // Reassign rather than mutate: QML only re-evaluates bindings on the
  // property write, not on an in-place edit of the array's contents.
  function _patch(key, patch) {
    var next = []
    for (var i = 0; i < lights.length; i++) {
      var light = lights[i]
      if (light.key !== key) { next.push(light); continue }
      next.push({
        key: light.key,
        name: light.name,
        mac: light.mac,
        address: light.address,
        on: patch.on === undefined ? light.on : patch.on,
        brightness: patch.brightness === undefined ? light.brightness : patch.brightness,
        kelvin: patch.kelvin === undefined ? light.kelvin : patch.kelvin
      })
    }
    lights = next
    saveTimer.restart()
  }

  function _patchAll(patch) {
    for (var i = 0; i < lights.length; i++) _patch(lights[i].key, patch)
  }

  // ---- Commands ----------------------------------------------------------

  function setPower(key, on) {
    _patch(key, { on: on })
    _enqueue(key + ":power", _curl("POST", "/lights/" + encodeURIComponent(key) + "/" + (on ? "on" : "off"), null))
  }

  function setAllPower(on) {
    _patchAll({ on: on })
    // The daemon has a dedicated broadcast route; one mesh message beats N.
    _enqueue("all:power", _curl("POST", "/lights/" + (on ? "on" : "off"), null))
  }

  // Brightness and CCT both light the fixture up, so both imply power on —
  // which is what the daemon records internally too.
  function setBrightness(key, percent) {
    var value = Math.round(Model.clamp(percent, 0, 100))
    _patch(key, { brightness: value, on: true })
    _enqueue(key + ":level", _curl("POST", "/lights/" + encodeURIComponent(key) + "/brightness", { value: value }))
  }

  // The daemon's CCT command carries brightness in the same packet, so the
  // current level has to ride along or the fixture would jump to the route's
  // 80% default.
  function setKelvin(key, kelvin) {
    var light = lightFor(key)
    if (!light) return
    var value = Math.round(Model.clamp(kelvin, minKelvin, maxKelvin))
    _patch(key, { kelvin: value, on: true })
    _enqueue(key + ":cct", _curl("POST", "/lights/" + encodeURIComponent(key) + "/cct", {
      brightness: Math.round(light.brightness),
      kelvin: value
    }))
  }

  function setAllBrightness(percent) {
    var value = Math.round(Model.clamp(percent, 0, 100))
    _patchAll({ brightness: value, on: true })
    _enqueue("all:level", _curl("POST", "/lights/all/brightness", { value: value }))
  }

  // No broadcast here: the daemon's CCT packet carries one brightness, so a
  // broadcast would flatten every fixture to the same level. Per-light keeps
  // each one's own brightness, and the queue still coalesces per fixture.
  function setAllKelvin(kelvin) {
    for (var i = 0; i < lights.length; i++) setKelvin(lights[i].key, kelvin)
  }

  function _curl(method, path, body) {
    var argv = ["curl", "-fsS", "--max-time", "6", "-X", method, baseUrl + path]
    if (apiKey !== "") argv.push("-H", "Authorization: Bearer " + apiKey)
    if (body !== null && body !== undefined)
      argv.push("-H", "Content-Type: application/json", "-d", JSON.stringify(body))
    return argv
  }

  // ---- Command queue -----------------------------------------------------
  //
  // A mesh round trip costs the daemon roughly half a second, and a slider
  // drag can emit sixty positions a second. So commands queue, and a queued
  // command is *replaced* when a newer one supersedes it: dragging brightness
  // leaves at most one pending brightness command for that fixture, and the
  // value that lands is the one the slider stopped on. The cooldown then caps
  // the mesh at roughly five commands a second.

  property var _queue: []
  property string _inflightId: ""

  function _enqueue(id, argv) {
    var next = _queue.slice()
    for (var i = 0; i < next.length; i++) {
      if (next[i].id === id) { next.splice(i, 1); break }
    }
    next.push({ id: id, argv: argv })
    _queue = next
    _pump()
  }

  function _pump() {
    if (cmdProc.running || cooldown.running || _queue.length === 0) return
    var next = _queue.slice()
    var job = next.shift()
    _queue = next
    _inflightId = job.id
    cmdProc.command = job.argv
    cmdProc.running = true
  }

  Timer {
    id: cooldown
    interval: 200
    repeat: false
    onTriggered: root._pump()
  }

  Process {
    id: cmdProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode === 0) {
        root.reachable = true
        root.lastError = ""
      } else {
        var message = Model.describeFailure(exitCode, cmdProc.stderr.text, cmdProc.stdout.text)
        root.lastError = message
        // Only a transport failure means the daemon is gone; a 4xx means it
        // answered and disliked the request.
        if (exitCode === 7 || exitCode === 28) root.reachable = false
        root.commandFailed(message)
      }
      root._inflightId = ""
      cooldown.restart()
    }
  }

  // ---- Roster polling ----------------------------------------------------

  function refresh() {
    if (rosterProc.running) return
    rosterProc.command = _curl("GET", "/", null)
    rosterProc.running = true
  }

  Process {
    id: rosterProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function (exitCode) {
      root.everChecked = true
      if (exitCode !== 0) {
        root.reachable = false
        root.lastError = Model.describeFailure(exitCode, rosterProc.stderr.text, rosterProc.stdout.text)
        return
      }
      try {
        var roster = Model.parseRoster(rosterProc.stdout.text)
        root.lights = Model.mergeRoster(roster, root.lights, root.defaultState)
        if (!root._snapshotApplied) {
          root.lights = Model.applySnapshot(root.lights, root._snapshot)
          root._snapshotApplied = true
        }
        root.reachable = true
        root.lastError = ""
      } catch (e) {
        root.reachable = false
        root.lastError = String(e.message || e)
      }
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- Persistence -------------------------------------------------------
  //
  // The daemon cannot tell us what the fixtures are doing, so remember it
  // ourselves. Written on a debounce so a drag does not hit the disk sixty
  // times, and applied once, after the first roster arrives.

  property var _snapshot: ({})
  property bool _snapshotApplied: false

  Process {
    running: true
    command: ["mkdir", "-p", root.home + "/.local/state/omarchy-amaran"]
  }

  Timer {
    id: saveTimer
    interval: 800
    repeat: false
    onTriggered: if (root.lights.length > 0) stateFile.setText(JSON.stringify(Model.snapshotOf(root.lights), null, 2) + "\n")
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        root._snapshot = JSON.parse(String(text() || "{}")) || ({})
      } catch (e) {
        root._snapshot = ({})
      }
    }
    onLoadFailed: root._snapshot = ({})
  }
}

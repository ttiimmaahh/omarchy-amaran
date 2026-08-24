import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Bar button plus a control panel for amaran / Aputure fixtures: a master
// switch in the hero, then one card per light with power, brightness and
// colour temperature.
//
// Every control writes through Service.qml, which owns the state and the mesh
// command queue. The temperature slider tints its own fill with the colour it
// is dialling in, so the control reads as what it does.
Panel {
  id: root
  moduleName: "io.github.ttiimmaahh.amaran"
  ipcTarget: "amaran"
  // Own the handler so the target carries light commands as well as the
  // base class's open/close/toggle.
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color background: bar ? bar.background : Color.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.55)

  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"

  // This plugin's own directory, so the setup wizard can be launched from
  // wherever the plugin happens to be installed.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    var path = url.indexOf("file://") === 0 ? url.substring(7) : url
    return path.charAt(path.length - 1) === "/" ? path : path + "/"
  }

  function launchSetup() {
    root.close()
    Quickshell.execDetached([
      root.omarchyPath + "/bin/omarchy-launch-terminal",
      root.pluginDir + "tools/amaran-setup",
      amaran.daemonDir
    ])
  }

  // Panel cursor. `cursorActive` stays false until the keyboard or the mouse
  // asks for a highlight, so an untouched panel opens without one.
  property bool cursorActive: false
  property int cursorRow: 0
  property bool sliderDragging: false

  // A flat list of everything the cursor can land on, in visual order: the
  // master switch, then power / brightness / temperature for each fixture.
  readonly property var cursorTargets: {
    var targets = [{ kind: "master", light: -1 }]
    for (var i = 0; i < amaran.lights.length; i++) {
      targets.push({ kind: "power", light: i })
      if (amaran.lights[i].on) {
        targets.push({ kind: "level", light: i })
        targets.push({ kind: "temp", light: i })
      }
    }
    return targets
  }

  readonly property var cursorTarget: cursorTargets[Math.max(0, Math.min(cursorRow, cursorTargets.length - 1))]

  function targetHasCursor(kind, lightIndex) {
    if (!cursorActive) return false
    var target = cursorTarget
    return target && target.kind === kind && target.light === lightIndex
  }

  function setCursor(kind, lightIndex) {
    for (var i = 0; i < cursorTargets.length; i++) {
      if (cursorTargets[i].kind === kind && cursorTargets[i].light === lightIndex) {
        cursorActive = true
        cursorRow = i
        return
      }
    }
  }

  function moveCursor(delta) {
    if (cursorTargets.length === 0) return
    cursorRow = Math.max(0, Math.min(cursorTargets.length - 1, cursorRow + delta))
  }

  // Left/right nudges whatever the cursor is sitting on. The steps match the
  // slider wheel steps so keyboard and wheel feel like the same control.
  function adjustCursor(direction) {
    var target = cursorTarget
    if (!target) return
    var light = target.light >= 0 ? amaran.lights[target.light] : null
    if (!light || !light.on) return
    if (target.kind === "level") amaran.setBrightness(light.key, light.brightness + direction * 5)
    else if (target.kind === "temp") amaran.setKelvin(light.key, light.kelvin + direction * 100)
  }

  function activateCursor() {
    var target = cursorTarget
    if (!target) return
    if (target.kind === "master") { amaran.setAllPower(!amaran.anyOn); return }
    var light = amaran.lights[target.light]
    if (!light) return
    if (target.kind === "power") amaran.setPower(light.key, !light.on)
  }

  function barIcon() {
    return amaran.anyOn ? "󰛨" : "󰌵"
  }

  onOpenedChanged: {
    if (opened) amaran.refresh()
    else {
      cursorActive = false
      sliderDragging = false
    }
  }

  Service {
    id: amaran
    settings: root.settings
  }

  // Everything the panel can do, reachable without opening it — so the lights
  // can go on a keybind:
  //
  //   bind = SUPER, L, exec, omarchy-shell amaran toggleAll
  //   bind = SUPER SHIFT, L, exec, omarchy-shell amaran setBrightness 100
  IpcHandler {
    target: "amaran"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function allOn(): void { amaran.setAllPower(true) }
    function allOff(): void { amaran.setAllPower(false) }
    function toggleAll(): void { amaran.setAllPower(!amaran.anyOn) }
    function setBrightness(percent: string): void { amaran.setAllBrightness(parseFloat(percent)) }
    function setTemperature(kelvin: string): void { amaran.setAllKelvin(parseFloat(kelvin)) }
    function refresh(): void { amaran.refresh() }
  }

  // The bar sizes each slot from the widget root's implicit size, so a root
  // that never sets one collapses to zero width and renders nothing. Lift it
  // off the button, the way every first-party widget does.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barIcon()
    // A lit bar icon means at least one fixture is on; dimmed means all off.
    opacity: amaran.anyOn ? 1.0 : 0.55

    onPressed: function (which) {
      // Right-click is the panic switch — kill every light without opening
      // anything, the way the audio widget mutes from the bar.
      if (which === Qt.RightButton) amaran.setAllPower(false)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustCursor(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (character) {
        // Whole-rig shortcuts, so you never have to walk the list to go dark.
        if (character === "a" || character === "A") amaran.setAllPower(true)
        else if (character === "o" || character === "O") amaran.setAllPower(false)
        else if (character === "r" || character === "R") amaran.refresh()
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height && !root.sliderDragging
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: bulb · title/status · master switch ----------
          Item {
            id: heroItem
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, masterSwitch.implicitHeight)

            Text {
              id: heroIcon
              text: root.barIcon()
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              opacity: amaran.anyOn ? 1.0 : 0.5
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: masterSwitch
              checked: amaran.anyOn
              hasCursor: root.targetHasCursor("master", -1)
              foreground: root.foreground
              enabled: amaran.count > 0
              opacity: amaran.count > 0 ? 1.0 : 0.4
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onHovered: function (on) { if (on) root.setCursor("master", -1) }
              onToggled: amaran.setAllPower(!amaran.anyOn)

              PanelToolTip {
                visible: masterSwitch.containsMouse
                text: amaran.anyOn ? "Turn every light off" : "Turn every light on"
                fontFamily: root.fontFamily
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: masterSwitch.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Amaran"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: amaran.statusText
                color: amaran.reachable || !amaran.everChecked ? root.dim : Color.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Setup help, shown only when there is nothing to drive ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: amaran.everChecked && amaran.lights.length === 0

            PanelSeparator { foreground: root.foreground }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: amaran.reachable
                ? "The daemon is running but has no lights configured yet. Set up adds your mesh keys and fixtures."
                : "No amaran daemon at " + amaran.baseUrl + ".\n\nControlling amaran lights needs a Bluetooth Mesh network key and app key, exported from the amaran Desktop app. Set up walks through it."
            }

            Item { width: 1; height: Style.space(2) }

            Button {
              text: "Set up lights…"
              iconText: "󰒓"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.launchSetup()
            }
          }

          // ---------- One card per fixture ----------
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: amaran.lights.length > 0

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "LIGHTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: amaran.lights

              LightCard {
                required property var modelData
                required property int index
                light: modelData
                lightIndex: index
                width: panelColumn.width
              }
            }
          }
        }
      }
    }
  }

  // A fixture: name and summary with a power switch, then brightness and
  // colour temperature sliders.
  component LightCard: CursorSurface {
    id: card

    required property var light
    required property int lightIndex

    hasCursor: root.targetHasCursor("power", lightIndex)
      || root.targetHasCursor("level", lightIndex)
      || root.targetHasCursor("temp", lightIndex)
    foreground: root.foreground
    bordered: true
    implicitHeight: cardColumn.implicitHeight + Style.space(20)

    Column {
      id: cardColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      // ---- Name · summary · power ----
      Item {
        width: parent.width
        implicitHeight: Math.max(nameColumn.implicitHeight, powerSwitch.implicitHeight)

        ToggleSwitch {
          id: powerSwitch
          checked: card.light.on
          hasCursor: root.targetHasCursor("power", card.lightIndex)
          foreground: root.foreground
          trackHeight: Math.max(18, Math.round(Style.spacing.controlHeight * 0.45))
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          onHovered: function (on) { if (on) root.setCursor("power", card.lightIndex) }
          onToggled: amaran.setPower(card.light.key, !card.light.on)

          PanelToolTip {
            visible: powerSwitch.containsMouse
            text: card.light.on ? "Turn " + card.light.name + " off" : "Turn " + card.light.name + " on"
            fontFamily: root.fontFamily
          }
        }

        Column {
          id: nameColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.rightMargin: powerSwitch.width + Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            width: parent.width
            text: card.light.name
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: Model.describeLight(card.light)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      // ---- Brightness ----
      SliderRow {
        width: parent.width
        glyph: "󰃠"
        hasCursor: root.targetHasCursor("level", card.lightIndex)
        valueText: Model.formatPercent(card.light.brightness)
        minimum: 0
        maximum: 100
        step: 5
        value: card.light.brightness
        fillColor: root.foreground
        faded: !card.light.on
        enabled: card.light.on
        onHoveredIn: root.setCursor("level", card.lightIndex)
        onMovedTo: function (v) { if (card.light.on) amaran.setBrightness(card.light.key, v) }
      }

      // ---- Colour temperature ----
      SliderRow {
        width: parent.width
        glyph: "󰔏"
        hasCursor: root.targetHasCursor("temp", card.lightIndex)
        valueText: Model.formatKelvin(card.light.kelvin)
        minimum: amaran.minKelvin
        maximum: amaran.maxKelvin
        step: 100
        value: card.light.kelvin
        // Tint the fill with the temperature being dialled in: warm amber at
        // the bottom of the range, daylight blue-white at the top.
        fillColor: Model.kelvinToColor(card.light.kelvin)
        temperature: true
        faded: !card.light.on
        enabled: card.light.on
        onHoveredIn: root.setCursor("temp", card.lightIndex)
        onMovedTo: function (v) { if (card.light.on) amaran.setKelvin(card.light.key, v) }
      }
    }
  }

  // Icon · slider · value, sized so every row's slider starts and ends on the
  // same x regardless of how wide the value label renders.
  component SliderRow: Item {
    id: sliderRow

    property string glyph: ""
    property string valueText: ""
    property real minimum: 0
    property real maximum: 100
    property real step: 5
    property real value: 0
    property color fillColor: root.foreground
    property bool hasCursor: false
    property bool faded: false
    property bool temperature: false

    signal hoveredIn()
    signal movedTo(real value)

    implicitHeight: Math.max(Style.space(24), slider.implicitHeight)
    opacity: faded ? 0.55 : 1.0

    Behavior on opacity {
      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }

    Text {
      id: rowGlyph
      text: sliderRow.glyph
      color: sliderRow.hasCursor ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
      width: Style.space(20)
      horizontalAlignment: Text.AlignHCenter
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: rowValue
      text: slider.dragging
        ? (sliderRow.temperature ? Model.formatKelvin(slider.liveValue) : Model.formatPercent(slider.liveValue))
        : sliderRow.valueText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      width: Style.space(44)
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }

    PanelSlider {
      id: slider
      bar: root.bar
      minimum: sliderRow.minimum
      maximum: sliderRow.maximum
      step: sliderRow.step
      integer: true
      value: sliderRow.value
      fillColor: sliderRow.temperature && slider.dragging ? Model.kelvinToColor(slider.liveValue) : sliderRow.fillColor
      knobColor: sliderRow.temperature && slider.dragging ? Model.kelvinToColor(slider.liveValue) : sliderRow.fillColor
      anchors.left: rowGlyph.right
      anchors.leftMargin: Style.space(8)
      anchors.right: rowValue.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter

      onDraggingChanged: root.sliderDragging = slider.dragging
      onReleased: function (v) { sliderRow.movedTo(v) }
    }

    HoverHandler {
      onHoveredChanged: if (hovered) sliderRow.hoveredIn()
    }
  }
}

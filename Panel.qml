import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// OBSBOT Meet SE webcam controls. All device access goes through the
// bundled obsbot-ctl helper (v4l2-ctl for standard UVC controls, the OBSBOT
// vendor extension unit for AI framing and HDR); the panel only reads JSON.
// The camera is only queried when the panel opens or after a change, and
// hotplug is detected from /dev/v4l/by-id without opening the device, so
// nothing here interferes with a call that is using the camera.
Panel {
  id: root
  moduleName: "ulfendk.obsbot"
  ipcTarget: "ulfendk.obsbot"

  // The helper ships inside the plugin folder; run it through python3 so a
  // checkout without the executable bit still works.
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string ctl: pluginDir + "/bin/obsbot-ctl"
  // Settings from this widget's shell.json entry.
  // demoFixture: path to a saved `v4l2-ctl -L` dump; runs against it instead of the camera.
  readonly property string demoFixture: String(setting("demoFixture", ""))
  readonly property int panStepDegrees: Number(setting("panStepDegrees", 5))
  readonly property bool restoreOnReplug: setting("restoreOnReplug", true) === true
  readonly property var ctlEnv: demoFixture !== "" ? ({ OBSBOT_CTL_FAKE: demoFixture }) : ({})

  property bool present: false
  property bool presenceKnown: false
  property bool fake: false
  property var controls: ({})
  property var ai: ({ available: false })
  property var presets: []
  property string lastError: ""
  property var pending: ({})
  property int wheelAccumulator: 0

  readonly property bool hasControls: Object.keys(controls).length > 0
  readonly property int zoom: ctrlValue("zoom_absolute", 0)
  readonly property string framing: ai && ai.framing ? String(ai.framing) : "off"
  readonly property string statusText: !present ? "NOT CONNECTED"
    : (fake ? "DEMO MODE" : "CONNECTED")
      + (zoom > 0 ? " · ZOOM " + zoom : "")
      + (ai.available && framing !== "off" ? " · FRAMING " + framing.toUpperCase() : "")

  function ctrl(name) { return controls[name] }
  function ctrlValue(name, fallback) {
    var c = controls[name]
    return c && c.value !== undefined ? c.value : fallback
  }

  function applyResult(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { return }
    if (!data) return
    if (data.present !== undefined) present = data.present === true
    if (data.present === false) { controls = ({}); return }
    if (data.controls) {
      fake = data.fake === true
      // Sets queued while this ran are newer than what the helper saw.
      var next = data.controls
      for (var name in pending)
        if (next[name]) next[name] = Object.assign({}, next[name], { value: pending[name] })
      controls = next
    }
    if (data.ai) ai = data.ai
    if (data.presets) presets = data.presets
    var errs = data.errors ? Object.keys(data.errors) : []
    lastError = data.error ? String(data.error)
      : errs.length > 0 ? errs.map(function(n) { return n + ": " + data.errors[n] }).join("\n")
      : ""
  }

  function run(proc, args) {
    if (proc.running) return false
    proc.command = ["python3", root.ctl].concat(args)
    proc.running = true
    return true
  }

  function refresh() {
    run(stateProc, ["state"])
    run(presetProc, ["preset", "list"])
  }

  // Optimistic: the slider moves now, the write is batched and debounced.
  function setCtrl(name, value) {
    var c = controls[name]
    if (!c) return
    value = Math.max(c.min, Math.min(c.max, Math.round(value)))
    var next = Object.assign({}, controls)
    next[name] = Object.assign({}, c, { value: value })
    controls = next
    var p = Object.assign({}, pending)
    p[name] = value
    pending = p
    setTimer.restart()
  }

  function flushPending() {
    var names = Object.keys(pending)
    if (names.length === 0) return
    if (setProc.running) { setTimer.restart(); return }
    var args = ["set"]
    for (var i = 0; i < names.length; i++) args.push(names[i] + "=" + pending[names[i]])
    pending = ({})
    run(setProc, args)
  }

  function nudge(name, steps) {
    var c = controls[name]
    if (c) setCtrl(name, c.value + steps * (c.step || 1))
  }

  function panBy(dx, dy) {
    var unit = 3600 * root.panStepDegrees
    var pan = ctrl("pan_absolute"), tilt = ctrl("tilt_absolute")
    if (dx !== 0 && pan) setCtrl("pan_absolute", pan.value + dx * unit)
    if (dy !== 0 && tilt) setCtrl("tilt_absolute", tilt.value + dy * unit)
  }

  function recenter() {
    if (ctrl("pan_absolute")) setCtrl("pan_absolute", 0)
    if (ctrl("tilt_absolute")) setCtrl("tilt_absolute", 0)
  }

  function action(args) {
    if (run(actionProc, args)) return
    actionRetry.args = args
    actionRetry.restart()
  }

  function savePreset(name) {
    name = String(name || "").trim()
    if (name === "") return
    action(["preset", "save", name])
  }

  function onPresence(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { return }
    var now = data && data.present === true
    var wasKnown = presenceKnown
    var was = present
    presenceKnown = true
    present = now
    if (!now) { controls = ({}); return }
    if (!was) {
      // Replug (not first start): the camera forgot its settings.
      if (wasKnown && restoreOnReplug) action(["restore"])
      else if (opened) refresh()
    }
  }

  Component.onCompleted: run(presentProc, ["present"])
  onOpenedChanged: if (opened) refresh()
  onDemoFixtureChanged: { controls = ({}); run(presentProc, ["present"]); if (opened) refresh() }

  Process {
    id: presentProc
    environment: root.ctlEnv
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.onPresence(text) }
  }

  Process {
    id: stateProc
    environment: root.ctlEnv
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyResult(text) }
  }

  Process {
    id: presetProc
    environment: root.ctlEnv
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyResult(text) }
  }

  Process {
    id: setProc
    environment: root.ctlEnv
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyResult(text) }
    onRunningChanged: if (!running && Object.keys(root.pending).length > 0) setTimer.restart()
  }

  Process {
    id: actionProc
    environment: root.ctlEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.applyResult(text)
        // AI commands answer with their own status; re-read the full state.
        if (actionProc.command.length > 2 && actionProc.command[2] === "ai") root.run(stateProc, ["state"])
      }
    }
  }

  Timer { id: setTimer; interval: 80; onTriggered: root.flushPending() }

  Timer {
    id: actionRetry
    property var args: []
    interval: 150
    onTriggered: root.action(args)
  }

  // Hotplug check: a by-id glob, never opens the device.
  Timer { interval: 4000; running: true; repeat: true; onTriggered: root.run(presentProc, ["present"]) }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.present ? "󰖠" : "󱜷"
    dimmed: !root.present
    tooltipText: root.present
      ? "OBSBOT Meet SE" + (root.fake ? " (demo)" : "") + (root.zoom > 0 ? " · zoom " + root.zoom : "")
        + "\nScroll to zoom · right-click to recenter"
      : "OBSBOT not connected"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.recenter()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (!root.present) return
      if (!root.hasControls) { root.run(stateProc, ["state"]); return }
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps !== 0) root.nudge("zoom_absolute", wheel.steps)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { root.panBy(dx, -dy) }
      onTextKey: function(t) {
        if (t === "+" || t === "=") root.nudge("zoom_absolute", 1)
        else if (t === "-") root.nudge("zoom_absolute", -1)
        else if (t === "0") root.recenter()
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: column.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: column.implicitHeight > scrollArea.height
        }

        Column {
          id: column
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: camera icon · name/status · reset ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: button.text
              color: root.bar.foreground
              opacity: root.present ? 1.0 : 0.5
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            PanelActionButton {
              id: resetButton
              visible: root.hasControls
              iconText: "󰑓"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.action(["reset"])

              PanelToolTip {
                visible: resetButton._hot
                text: "Reset every setting to the camera default"
                fontFamily: root.bar.fontFamily
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: resetButton.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "OBSBOT Meet SE"
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                text: root.statusText
                textFormat: Text.PlainText
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          Caption {
            visible: root.lastError !== ""
            text: root.lastError
            color: Color.urgent
            opacity: 1
          }

          Caption {
            visible: !root.present
            text: "Plug in the camera and it will show up here. Settings you made last time are re-applied when it reconnects."
          }

          Caption {
            visible: root.present && !root.hasControls
            text: "Reading camera…"
          }

          // ---------- Framing ----------
          Section {
            title: "FRAMING"
            visible: root.hasControls

            Item {
              width: parent.width
              implicitHeight: pad.implicitHeight

              Grid {
                id: pad
                columns: 3
                spacing: Style.space(4)
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter

                Item { width: padUp.width; height: padUp.height }
                PadButton { id: padUp; text: "▲"; tip: "Tilt up"; onClicked: root.panBy(0, 1) }
                Item { width: padUp.width; height: padUp.height }
                PadButton { text: "◀"; tip: "Pan left"; onClicked: root.panBy(-1, 0) }
                PadButton { text: "●"; tip: "Recenter (0)"; onClicked: root.recenter() }
                PadButton { text: "▶"; tip: "Pan right"; onClicked: root.panBy(1, 0) }
                Item { width: padUp.width; height: padUp.height }
                PadButton { text: "▼"; tip: "Tilt down"; onClicked: root.panBy(0, -1) }
                Item { width: padUp.width; height: padUp.height }
              }

              Column {
                anchors.left: pad.right
                anchors.leftMargin: Style.space(16)
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                SliderRow { name: "zoom_absolute"; label: "Zoom"; format: function(v, c) { return v + " / " + c.max } }
                SliderRow { name: "pan_absolute"; label: "Pan"; format: function(v) { return Math.round(v / 3600) + "°" } }
                SliderRow { name: "tilt_absolute"; label: "Tilt"; format: function(v) { return Math.round(v / 3600) + "°" } }
              }
            }
          }

          // ---------- AI (OBSBOT vendor extension unit) ----------
          Section {
            title: "AI"
            visible: root.hasControls

            Caption {
              visible: !root.ai.available
              text: "AI controls are unavailable" + (root.ai.error ? ": " + root.ai.error : ".")
            }

            Item {
              visible: root.ai.available === true
              width: parent.width
              implicitHeight: Math.max(framingLabel.implicitHeight, framingGroup.implicitHeight)

              Text {
                id: framingLabel
                text: "Auto-framing"
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              ButtonGroup {
                id: framingGroup
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                options: [
                  { value: "off", label: "Off" },
                  { value: "single", label: "Single" },
                  { value: "group", label: "Group" }
                ]
                value: root.framing
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                focusable: false
                onChanged: function(v) { root.action(["ai", "framing", v]) }
              }
            }

            SwitchRow {
              visible: root.ai.available === true
              label: "HDR"
              checked: root.ai.hdr === true
              onToggled: root.action(["ai", "hdr", root.ai.hdr === true ? "off" : "on"])
            }
          }

          // ---------- Focus ----------
          Section {
            title: "FOCUS"
            visible: root.hasControls && !!root.ctrl("focus_automatic_continuous")

            SwitchRow {
              label: "Autofocus"
              checked: root.ctrlValue("focus_automatic_continuous", 0) === 1
              onToggled: root.setCtrl("focus_automatic_continuous", checked ? 0 : 1)
            }
            SliderRow { name: "focus_absolute"; label: "Manual focus" }
          }

          // ---------- Exposure ----------
          Section {
            title: "EXPOSURE"
            visible: root.hasControls && !!root.ctrl("auto_exposure")

            ButtonGroup {
              readonly property var c: root.ctrl("auto_exposure")
              options: {
                var labels = { "Auto Mode": "Auto", "Manual Mode": "Manual", "Aperture Priority Mode": "Aperture", "Shutter Priority Mode": "Shutter" }
                var menu = c ? c.menu : {}
                return Object.keys(menu || {}).map(function(k) { return { value: k, label: labels[menu[k]] || menu[k] } })
              }
              value: c ? String(c.value) : ""
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              focusable: false
              onChanged: function(v) { root.setCtrl("auto_exposure", Number(v)) }
            }
            SliderRow { name: "exposure_time_absolute"; label: "Shutter"; format: function(v) { return (v / 10).toFixed(1) + " ms" } }
            SliderRow { name: "gain"; label: "Gain" }
            SliderRow { name: "backlight_compensation"; label: "Backlight compensation" }
          }

          // ---------- White balance ----------
          Section {
            title: "WHITE BALANCE"
            visible: root.hasControls && !!root.ctrl("white_balance_automatic")

            SwitchRow {
              label: "Automatic"
              checked: root.ctrlValue("white_balance_automatic", 0) === 1
              onToggled: root.setCtrl("white_balance_automatic", checked ? 0 : 1)
            }
            SliderRow { name: "white_balance_temperature"; label: "Temperature"; format: function(v) { return v + " K" } }
          }

          // ---------- Image ----------
          Section {
            title: "IMAGE"
            visible: root.hasControls

            SliderRow { name: "brightness"; label: "Brightness" }
            SliderRow { name: "contrast"; label: "Contrast" }
            SliderRow { name: "saturation"; label: "Saturation" }
            SliderRow { name: "hue"; label: "Hue" }
            SliderRow { name: "sharpness"; label: "Sharpness" }

            Item {
              readonly property var c: root.ctrl("power_line_frequency")
              visible: !!c
              width: parent.width
              implicitHeight: Math.max(flickerLabel.implicitHeight, flickerGroup.implicitHeight)

              Text {
                id: flickerLabel
                text: "Anti-flicker"
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              ButtonGroup {
                id: flickerGroup
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                options: {
                  var menu = parent.c ? parent.c.menu : {}
                  return Object.keys(menu || {}).map(function(k) { return { value: k, label: menu[k] === "Disabled" ? "Off" : menu[k] } })
                }
                value: parent.c ? String(parent.c.value) : ""
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.caption
                focusable: false
                onChanged: function(v) { root.setCtrl("power_line_frequency", Number(v)) }
              }
            }
          }

          // ---------- Presets ----------
          Section {
            title: "PRESETS"
            visible: root.hasControls

            Caption {
              visible: root.presets.length === 0
              text: "No presets yet. Save the current look under a name to recall it later."
            }

            Repeater {
              model: root.presets

              Item {
                required property string modelData
                width: column.width
                implicitHeight: presetButton.implicitHeight

                Button {
                  id: presetButton
                  anchors.left: parent.left
                  anchors.right: deleteButton.left
                  anchors.rightMargin: Style.space(6)
                  text: modelData
                  leftAlign: true
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.font.bodySmall
                  tooltipText: "Apply this preset"
                  onClicked: root.action(["preset", "load", modelData])
                }

                PanelActionButton {
                  id: deleteButton
                  iconText: "󰆴"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  onClicked: root.action(["preset", "delete", modelData])
                }
              }
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(presetName.implicitHeight, saveButton.implicitHeight)

              TextField {
                id: presetName
                anchors.left: parent.left
                anchors.right: saveButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                placeholderText: "Preset name"
                foreground: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                onAccepted: { root.savePreset(text); text = "" }
              }

              Button {
                id: saveButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Save"
                bordered: true
                enabled: presetName.text.trim() !== ""
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: { root.savePreset(presetName.text); presetName.text = "" }
              }
            }
          }
        }
      }
    }
  }

  // Separator + header + content, collapsed entirely when hidden.
  component Section: Column {
    property string title: ""
    default property alias content: body.children

    width: column.width
    spacing: Style.space(8)

    PanelSeparator { foreground: root.bar.foreground }

    PanelSectionHeader {
      text: parent.title
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }

    Column {
      id: body
      width: parent.width
      spacing: Style.space(8)
    }
  }

  component Caption: Text {
    width: column.width
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.caption
  }

  // One V4L2 integer control: label, live value, slider. Greyed out while
  // its auto mode owns it (the helper reports that as `inactive`).
  component SliderRow: Column {
    id: sliderRow
    property string name: ""
    property string label: ""
    property var format: null
    readonly property var c: root.controls[name]
    readonly property bool locked: !c || c.inactive === true

    visible: !!c
    width: parent ? parent.width : 0
    spacing: Style.space(2)
    opacity: locked ? 0.4 : 1.0
    enabled: !locked

    Item {
      width: parent.width
      implicitHeight: rowLabel.implicitHeight

      Text {
        id: rowLabel
        text: sliderRow.label
        textFormat: Text.PlainText
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.left: parent.left
      }

      Text {
        readonly property real shown: slider.dragging ? slider.liveValue : (sliderRow.c ? sliderRow.c.value : 0)
        text: sliderRow.c ? (sliderRow.format ? sliderRow.format(Math.round(shown), sliderRow.c) : String(Math.round(shown))) : ""
        textFormat: Text.PlainText
        color: root.bar.foreground
        opacity: 0.7
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: rowLabel.verticalCenter
      }
    }

    PanelSlider {
      id: slider
      bar: root.bar
      width: parent.width
      integer: true
      minimum: sliderRow.c ? sliderRow.c.min : 0
      maximum: sliderRow.c ? sliderRow.c.max : 1
      step: sliderRow.c ? (sliderRow.c.step || 1) : 1
      value: sliderRow.c ? sliderRow.c.value : 0
      onMoved: function(v) { root.setCtrl(sliderRow.name, v) }
    }
  }

  component SwitchRow: Item {
    id: switchRow
    property string label: ""
    property bool checked: false
    signal toggled()

    width: parent ? parent.width : 0
    implicitHeight: Math.max(switchLabel.implicitHeight, toggle.implicitHeight)

    Text {
      id: switchLabel
      text: switchRow.label
      textFormat: Text.PlainText
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    ToggleSwitch {
      id: toggle
      checked: switchRow.checked
      trackHeight: 16
      foreground: root.bar.foreground
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      onToggled: switchRow.toggled()
    }
  }

  component PadButton: Button {
    property string tip: ""
    width: Style.space(34)
    height: Style.space(30)
    bordered: true
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    fontSize: Style.font.bodySmall
    tooltipText: tip
  }
}

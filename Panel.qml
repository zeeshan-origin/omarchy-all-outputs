import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.zeeshan-origin.all-outputs"
  ipcTarget: "io.github.zeeshan-origin.all-outputs"

  readonly property string combineName: "combine_all_outputs"

  // Scripts live inside the plugin folder, so find that folder from this file.
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    if (u.indexOf("file://") === 0) u = u.substring(7)
    return u.replace(/\/$/, "")
  }
  readonly property string cli: pluginDir + "/bin/all-outputs"
  readonly property string setupScript: pluginDir + "/setup/install.sh"

  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var defaultSink: Pipewire.defaultAudioSink
  readonly property var defaultSource: Pipewire.defaultAudioSource

  readonly property var combineSink: {
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && String(n.name) === combineName) return n
    }
    return null
  }

  // Real hardware only. The combine sink is a sink too but a slider for it
  // would just be the master volume the bar already has.
  readonly property var candidateDevices: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && Model.isHardwareSink(n)) list.push(n)
    }
    return list
  }

  readonly property var candidateSources: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && !n.isSink && !n.isStream && Model.isMicrophone(n)) list.push(n)
    }
    return list
  }

  readonly property bool combineLoaded: !!combineSink
  property bool settingUp: false
  property string setupError: ""

  // Quickshell's defaultAudioSink sometimes keeps reporting the old device
  // after the default moved to the combine sink. pactl is always right, so
  // ask it. The built in Audio panel polls the same way.
  property string defaultSinkName: ""
  readonly property bool broadcasting: defaultSinkName === combineName
  readonly property var currentSink: {
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && String(n.name) === defaultSinkName) return n
    }
    return defaultSink
  }

  function refreshDefaultSink() {
    if (!defaultSinkProc.running) defaultSinkProc.running = true
  }
  onDefaultSinkChanged: refreshDefaultSink()

  // Same availability list the Audio panel uses, so an unplugged jack or a
  // dark HDMI port drops out of this list at the same time.
  property var sinkAvailability: ({})
  property bool sinkAvailabilityLoaded: false

  function sinkAvailable(node) {
    if (!node || !node.name || !sinkAvailabilityLoaded) return true
    return sinkAvailability[String(node.name)] !== false
  }

  readonly property var devices: {
    var list = []
    for (var i = 0; i < candidateDevices.length; i++)
      if (sinkAvailable(candidateDevices[i])) list.push(candidateDevices[i])
    return list
  }

  // Repeaters get a copy of the list, not the live PipeWire model. Rebuilding
  // a Repeater while PipeWire is still removing a node has crashed the shell
  // before, so let that settle for a moment first.
  property var displayDevices: []
  property var displaySources: []

  function refreshDisplayModels() {
    if (!opened) return
    displayDevices = devices.slice()
    displaySources = candidateSources.slice()
  }

  function scheduleRefresh() {
    if (!opened) return
    refreshTimer.restart()
  }

  onDevicesChanged: scheduleRefresh()
  onCandidateSourcesChanged: scheduleRefresh()
  onOpenedChanged: {
    if (opened) refreshDisplayModels()
    else { displayDevices = []; displaySources = [] }
  }

  readonly property string statusLine: {
    if (settingUp) return "SETTING UP..."
    if (setupError !== "") return setupError.toUpperCase()
    if (!combineLoaded) return "NOT SET UP YET"
    if (broadcasting) return "PLAYING ON " + devices.length + (devices.length === 1 ? " DEVICE" : " DEVICES")
    return "OFF, " + Model.nodeLabel(currentSink).toUpperCase()
  }

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Color.accent)
    : Style.hoverFillFor(Color.foreground, Color.accent)
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Color.accent)
    : Style.selectedFillFor(Color.foreground, Color.accent)

  function setBroadcast(on) {
    if (on) {
      if (!combineSink) return
      Pipewire.preferredDefaultAudioSink = combineSink
      Quickshell.execDetached([cli, "on"])
    } else {
      Quickshell.execDetached([cli, "off"])
    }
    // The script runs detached, give it a moment then read the default again.
    afterActionTimer.restart()
  }

  function runSetup() {
    if (settingUp) return
    settingUp = true
    setupError = ""
    setupProc.running = true
  }

  function setDefaultSource(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSource = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached(["omarchy-audio-input-set-default", String(node.id), String(node.name)])
  }

  function isDefaultSource(node) {
    return !!defaultSource && !!node && defaultSource.id === node.id
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  PwObjectTracker { objects: root.candidateDevices }
  PwObjectTracker { objects: root.candidateSources }
  PwObjectTracker { objects: root.combineSink ? [root.combineSink] : [] }

  Process {
    id: sinkAvailabilityProc
    command: ["omarchy-audio-sink-availability"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.sinkAvailability = Model.parseSinkAvailability(text)
        root.sinkAvailabilityLoaded = true
      }
    }
  }

  Process {
    id: defaultSinkProc
    command: ["pactl", "get-default-sink"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.defaultSinkName = String(text).trim()
    }
  }

  // Setup restarts audio, which can take a while. Cap it so a stuck restart
  // can never leave the panel showing "setting up" forever.
  Process {
    id: setupProc
    command: ["/usr/bin/timeout", "--kill-after=5", "90", root.setupScript, "--yes"]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text).trim().split("\n").pop() || ""
        if (msg !== "") root.setupError = msg.replace(/^all-outputs setup: /, "")
      }
    }
    onExited: function(code) {
      root.settingUp = false
      if (code === 0) root.setupError = ""
      else if (root.setupError === "") root.setupError = "setup failed (" + code + ")"
      afterActionTimer.restart()
    }
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!sinkAvailabilityProc.running) sinkAvailabilityProc.running = true
  }

  Timer {
    id: refreshTimer
    interval: 75
    repeat: false
    onTriggered: root.refreshDisplayModels()
  }

  // Quick while open, slow but always on so the bar icon stays right.
  Timer {
    interval: 2000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshDefaultSink()
  }

  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshDefaultSink()
  }

  Timer {
    id: afterActionTimer
    interval: 600
    repeat: false
    onTriggered: root.refreshDefaultSink()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.broadcasting ? "󰓸" : "󰓃"
    tooltipText: root.broadcasting
      ? "All Outputs: playing on " + root.devices.length + " device" + (root.devices.length === 1 ? "" : "s")
      : "All Outputs: off"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.setBroadcast(!root.broadcasting)
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
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === " " || t === "b" || t === "B") root.setBroadcast(!root.broadcasting)
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
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // Header: icon, title and status, on/off switch
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, broadcastSwitch.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.broadcasting ? "󰓸" : "󰓃"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              opacity: root.broadcasting ? 1.0 : 0.5
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: broadcastSwitch
              checked: root.broadcasting
              interactive: root.combineLoaded && !root.settingUp
              foreground: root.bar.foreground
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.setBroadcast(!root.broadcasting)

              PanelToolTip {
                visible: broadcastSwitch.containsMouse
                text: root.combineLoaded
                  ? (root.broadcasting ? "Switch off: play on one device only" : "Switch on: play on every device at once")
                  : "Run Set up first"
                fontFamily: root.bar.fontFamily
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: broadcastSwitch.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "All Outputs"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.statusLine
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

          // First run: the PipeWire sink is not installed yet
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: !root.combineLoaded

            PanelSeparator { foreground: root.bar.foreground }

            Text {
              text: "The All Outputs sink is not installed. Set up copies one PipeWire config file into your config and restarts audio."
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
              leftPadding: Style.space(6)
              rightPadding: Style.space(6)
            }

            ActionRow {
              width: parent.width
              label: root.settingUp ? "Setting up..." : "Set up"
              enabled: !root.settingUp
              onClicked: root.runSetup()
            }
          }

          // Per device volume
          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "OUTPUTS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Text {
              visible: root.displayDevices.length === 0
              text: "No outputs connected"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              leftPadding: Style.space(6)
            }

            Repeater {
              model: root.displayDevices

              DeviceRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                node: modelData
                rowIndex: index
              }
            }
          }

          // Microphone picker
          PanelSeparator {
            visible: root.displaySources.length > 0
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.displaySources.length > 0

            PanelSectionHeader {
              text: "MICROPHONE"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.displaySources

              SourceRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                node: modelData
                rowIndex: index
              }
            }

            // A Bluetooth headset cannot do high quality playback and its mic
            // at the same time. While something records through it, that one
            // device plays at call quality.
            Text {
              visible: Model.isBluetoothMic(root.defaultSource)
              text: "Bluetooth mic in use: that device plays at call quality while recording"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
              leftPadding: Style.space(6)
              rightPadding: Style.space(6)
            }
          }
        }
      }
    }
  }

  // A clickable text row, used for the Set up button
  component ActionRow: CursorSurface {
    id: actionRow
    property string label: ""
    signal clicked()

    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: actionText.implicitHeight + Style.spacing.xl
    opacity: enabled ? 1.0 : 0.5

    Text {
      id: actionText
      textFormat: Text.PlainText
      text: actionRow.label
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      anchors.fill: parent
      enabled: actionRow.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: actionRow.clicked()
    }
  }

  // One hardware output with its own slider. The slider sets the device's
  // real sink volume, which WirePlumber remembers per device, so the level
  // sticks across reconnects.
  component DeviceRow: CursorSurface {
    id: deviceRow
    required property var node
    required property int rowIndex

    readonly property real volume: node && node.audio ? node.audio.volume : 0
    readonly property bool muted: node && node.audio ? node.audio.muted : false

    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: deviceColumn.implicitHeight + Style.spacing.xl

    Column {
      id: deviceColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(2)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          id: deviceGlyph
          textFormat: Text.PlainText
          text: deviceRow.muted ? "󰝟" : Model.sinkGlyph(deviceRow.node)
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          width: Style.space(22)
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
          opacity: deviceRow.muted ? 0.5 : 1.0

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (deviceRow.node && deviceRow.node.audio) deviceRow.node.audio.muted = !deviceRow.node.audio.muted
          }
        }

        Text {
          textFormat: Text.PlainText
          text: Model.nodeLabel(deviceRow.node)
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width - deviceGlyph.width - devicePct.width - Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
          opacity: deviceRow.muted ? 0.5 : 1.0
        }

        Text {
          id: devicePct
          textFormat: Text.PlainText
          text: Math.round(deviceRow.volume * 100) + "%"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          width: Style.space(36)
          horizontalAlignment: Text.AlignRight
          anchors.verticalCenter: parent.verticalCenter
          opacity: deviceRow.muted ? 0.5 : 1.0
        }
      }

      PanelSlider {
        bar: root.bar
        width: parent.width
        minimum: 0
        maximum: 1
        step: 0.05
        value: deviceRow.volume
        opacity: deviceRow.muted ? 0.5 : 1.0

        onMoved: function(v) {
          if (!deviceRow.node || !deviceRow.node.audio) return
          deviceRow.node.audio.volume = v
          // A muted device ignores volume changes, which looks broken, so
          // moving the slider up also unmutes.
          if (v > 0 && deviceRow.node.audio.muted) deviceRow.node.audio.muted = false
        }
        onRightClicked: if (deviceRow.node && deviceRow.node.audio) deviceRow.node.audio.muted = !deviceRow.node.audio.muted
      }
    }
  }

  component SourceRow: CursorSurface {
    id: sourceRow
    required property var node
    required property int rowIndex

    readonly property bool isActive: root.isDefaultSource(node)

    current: isActive
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: sourceInner.implicitHeight + Style.spacing.xl

    Row {
      id: sourceInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.sourceGlyph(sourceRow.node)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: Model.nodeLabel(sourceRow.node)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: sourceRow.isActive
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.setDefaultSource(sourceRow.node)
    }
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Details panel for the Mac battery widget: live battery facts, the real
// charge limit the SMC firmware is holding, and the stepper that changes it
// through `pkexec battctl set N`.
//
// The limit values are read from sysfs + /etc/battctl.conf, never from
// UPower: on Apple Silicon UPower reports its own hwdb default (75-80%)
// rather than the thresholds the firmware actually holds.
Panel {
  id: root
  moduleName: "io.github.geoochi.mac-battctl"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false
  property int phraseIndex: 0

  // ---- device ---------------------------------------------------------

  readonly property var device: UPower.displayDevice
  readonly property bool batteryPresent: !!(device && device.isPresent)
  readonly property int capacity: Math.round(Model.num(device ? device.percentage : 0, 0) * 100)

  readonly property string powerSupplyRoot: {
    var fromEnv = Quickshell.env("OMARCHY_POWER_SUPPLY_PATH")
    return fromEnv && String(fromEnv).length > 0 ? String(fromEnv) : "/sys/class/power_supply"
  }
  readonly property string batteryName: device && device.nativePath ? String(device.nativePath) : "macsmc-battery"
  readonly property string batteryPath: root.powerSupplyRoot + "/" + root.batteryName

  readonly property string deviceState: {
    var s = device ? device.state : -1
    if (s === UPowerDeviceState.Charging) return "charging"
    if (s === UPowerDeviceState.Discharging) return "discharging"
    if (s === UPowerDeviceState.FullyCharged) return "full"
    if (s === UPowerDeviceState.PendingCharge) return "pending"
    return "unknown"
  }

  // ---- real charge limit (sysfs + battctl config) ---------------------

  property string confText: ""
  property string limitEndRaw: ""
  property string limitStartRaw: ""
  property string cyclesRaw: ""
  property string tempRaw: ""

  readonly property int limitEnd: Math.round(Model.num(limitEndRaw, 100))
  readonly property int limitStart: Math.round(Model.num(limitStartRaw, 0))
  readonly property int confLimit: Model.confLimit(confText)
  readonly property string fwMode: Model.confMode(confText)
  readonly property bool limitActive: root.limitEnd < 100

  readonly property int stepperValue: {
    if (root.confLimit >= Model.MIN_LIMIT) return root.confLimit
    if (root.limitEnd >= Model.MIN_LIMIT) return root.limitEnd
    return 100
  }
  readonly property bool limitMismatch: root.confLimit >= Model.MIN_LIMIT && root.confLimit !== root.limitEnd

  function inputSnapshot() {
    return {
      present: root.batteryPresent,
      percentage: root.capacity,
      state: root.deviceState,
      onBattery: UPower.onBattery,
      limitStart: root.limitStart,
      limitEnd: root.limitEnd,
      phraseIndex: root.phraseIndex
    }
  }

  readonly property var info: Model.describe(root.inputSnapshot())

  // ---- stats ----------------------------------------------------------

  readonly property string sizeText: device && device.energyCapacity !== undefined
    ? Model.formatWh(device.energyCapacity) : "—"
  readonly property string cyclesText: root.cyclesRaw !== "" ? String(Math.round(Model.num(root.cyclesRaw, 0))) : "—"
  readonly property string healthText: device && device.healthSupported
    ? Math.round(Model.num(device.healthPercentage, 0)) + "%" : "—"
  readonly property string tempText: root.tempRaw !== ""
    ? (Model.num(root.tempRaw, 0) / 10).toFixed(1) + " °C" : "—"
  readonly property string rateText: Model.formatWatts(device ? device.changeRate : 0)

  readonly property bool timeIsEmpty: root.info.key === "onBattery" || root.info.key === "capping"
  readonly property string timeLabel: root.timeIsEmpty ? "Time left" : "Time to full"
  readonly property real timeSeconds: {
    if (!root.device) return 0
    if (root.timeIsEmpty) return Model.num(root.device.timeToEmpty, 0)
    if (root.info.key === "charging") return Model.num(root.device.timeToFull, 0)
    return 0
  }
  readonly property string timeText: Model.formatDuration(root.timeSeconds)

  readonly property string limitHint: {
    var end = root.limitEnd
    if (end >= 100) return "No limit set - the battery charges to 100%."
    var text = "Firmware holds " + Model.limitLabel(root.limitStart, end) + "."
    if (root.limitMismatch) text += " " + root.confLimit + "% was requested."
    var note = Model.modeNote(root.fwMode, true)
    return note ? text + " " + note : text
  }

  // ---- charge-limit edits ---------------------------------------------

  property string applyMessage: ""
  property bool applyError: false
  property int pendingLimit: 0

  function setLimit(value) {
    var next = Model.clamp(Math.round(value / Model.STEP_LIMIT) * Model.STEP_LIMIT, Model.MIN_LIMIT, 100)
    if (next === root.stepperValue) return
    root.applyMessage = "Applying " + next + "% …"
    root.applyError = false
    root.pendingLimit = next
    applyProc.command = ["pkexec", "/usr/local/bin/battctl", "set", String(next)]
    applyProc.running = true
  }

  function refreshFiles() {
    confFile.reload()
    limitEndFile.reload()
    limitStartFile.reload()
    cyclesFile.reload()
    tempFile.reload()
  }

  function refresh() {
    if (!batteryPresent) return
    refreshFiles()
    if (!profilesProc.running) profilesProc.running = true
  }

  // ---- profiles -------------------------------------------------------

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Keep the last known profile list across transient empty payloads so the
    // buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", root.info.key === "onBattery" ? "battery" : "ac", profile]
    actionProc.running = true
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  // ---- file watchers --------------------------------------------------

  FileView {
    id: confFile
    path: "/etc/battctl.conf"
    watchChanges: false
    printErrors: false
    onLoaded: root.confText = text()
    onLoadFailed: root.confText = ""
  }

  FileView {
    id: limitEndFile
    path: root.batteryPath + "/charge_control_end_threshold"
    watchChanges: false
    printErrors: false
    onLoaded: root.limitEndRaw = text()
    onLoadFailed: root.limitEndRaw = ""
  }

  FileView {
    id: limitStartFile
    path: root.batteryPath + "/charge_control_start_threshold"
    watchChanges: false
    printErrors: false
    onLoaded: root.limitStartRaw = text()
    onLoadFailed: root.limitStartRaw = ""
  }

  FileView {
    id: cyclesFile
    path: root.batteryPath + "/cycle_count"
    watchChanges: false
    printErrors: false
    onLoaded: root.cyclesRaw = text()
    onLoadFailed: root.cyclesRaw = ""
  }

  FileView {
    id: tempFile
    path: root.batteryPath + "/temp"
    watchChanges: false
    printErrors: false
    onLoaded: root.tempRaw = text()
    onLoadFailed: root.tempRaw = ""
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshFiles()
  }

  Timer {
    interval: 3000
    running: root.opened && root.info.phrases.length > 1
    repeat: true
    onTriggered: root.phraseIndex = root.phraseIndex + 1
  }

  Timer {
    id: messageTimer
    interval: 8000
    onTriggered: root.applyMessage = ""
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Process {
    id: applyProc
    stdout: StdioCollector { id: applyStdout; waitForEnd: true }
    stderr: StdioCollector { id: applyStderr; waitForEnd: true }
    onExited: function(code) {
      var out = String(applyStdout.text || "").trim()
      var err = String(applyStderr.text || "").trim()
      if (code !== 0) {
        root.applyError = true
        root.applyMessage = err || out || ("battctl exited with code " + code)
      } else {
        root.applyError = false
        var lines = out.split("\n")
        root.applyMessage = lines[lines.length - 1] || ("Charge limit set to " + root.pendingLimit + "%.")
      }
      root.refreshFiles()
      messageTimer.restart()
    }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }
      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: battery icon - title/status - percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.info.icon
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Battery"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.info.hero.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.batteryPresent ? root.capacity + "%" : "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Battery progress bar, with the limit marked ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.bar.foreground
            width: Math.max(barTrack.height, barTrack.width * (root.capacity / 100))

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

            // Subtle pulse while current is flowing in.
            SequentialAnimation on opacity {
              running: root.info.key === "charging" && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }

          // Where charging stops.
          Rectangle {
            visible: root.limitActive
            width: Math.max(2, Style.space(2))
            height: barTrack.height + Style.space(4)
            radius: width / 2
            color: root.bar.foreground
            opacity: 0.65
            x: barTrack.width * (root.limitEnd / 100) - width / 2
            anchors.verticalCenter: barTrack.verticalCenter
          }
        }

        // ---------- Stats ----------
        Row {
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Battery size"; value: root.sizeText }
            InfoPair { label: "Charge cycles"; value: root.cyclesText }
            InfoPair { label: "Health"; value: root.healthText }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: root.timeIsEmpty ? "Discharging" : "Charging"; value: root.rateText }
            InfoPair { label: root.timeLabel; value: root.timeText }
            InfoPair { label: "Temperature"; value: root.tempText }
          }
        }

        // ---------- Charge limit ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "CHARGE LIMIT"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: limitRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real stepWidth: Style.space(46)
            readonly property real offWidth: Style.space(64)
            readonly property real valueWidth: Math.max(Style.space(60),
              width - stepWidth * 2 - offWidth - spacing * 3)

            Button {
              width: limitRow.stepWidth
              text: "−"
              fontSize: Style.font.title
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              enabled: !applyProc.running && root.stepperValue > Model.MIN_LIMIT
              opacity: enabled ? 1.0 : 0.4
              onClicked: root.setLimit(root.stepperValue - Model.STEP_LIMIT)
            }

            Item {
              width: limitRow.valueWidth
              height: limitValueText.implicitHeight + Style.space(12)

              Text {
                id: limitValueText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.stepperValue >= 100 ? "100% · off" : root.stepperValue + "%"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true

                Behavior on color { ColorAnimation { duration: 200 } }
              }
            }

            Button {
              width: limitRow.stepWidth
              text: "+"
              fontSize: Style.font.title
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              enabled: !applyProc.running && root.stepperValue < 100
              opacity: enabled ? 1.0 : 0.4
              onClicked: root.setLimit(root.stepperValue + Model.STEP_LIMIT)
            }

            Button {
              width: limitRow.offWidth
              text: "Off"
              tooltipText: "Remove the charge limit (charge to 100%)"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              enabled: !applyProc.running && root.stepperValue < 100
              opacity: enabled ? 1.0 : 0.4
              onClicked: root.setLimit(100)
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.limitHint
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.applyMessage !== ""
            textFormat: Text.PlainText
            text: root.applyMessage
            color: root.applyError
              ? (root.bar && root.bar.urgent ? root.bar.urgent : "#ff5555")
              : Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: Model.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}

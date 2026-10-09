import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar entry for the Mac battery widget: percentage + state icon, and the host
// for the details panel where the charge limit can be changed.
//
// The button needs the real charge limit as well as the battery state, so it
// reads sysfs thresholds directly. UPower reports its own hwdb default
// (75-80% on Apple Silicon) instead of what the SMC firmware holds, so its
// threshold values are not used anywhere in this plugin.
BarWidget {
  id: root
  moduleName: "io.github.geoochi.mac-battctl"

  property string limitEndRaw: ""
  property string limitStartRaw: ""

  readonly property bool showPercentage: setting("showPercentage", true) === true

  readonly property var device: UPower.displayDevice
  readonly property bool batteryPresent: !!(device && device.isPresent)
  readonly property int capacity: Math.round(Model.num(device ? device.percentage : 0, 0) * 100)
  readonly property int limitEnd: Math.round(Model.num(limitEndRaw, 100))
  readonly property int limitStart: Math.round(Model.num(limitStartRaw, 0))

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

  function snapshot() {
    return {
      present: root.batteryPresent,
      percentage: root.capacity,
      state: root.deviceState,
      onBattery: UPower.onBattery,
      limitStart: root.limitStart,
      limitEnd: root.limitEnd,
      phraseIndex: 0
    }
  }

  readonly property var info: Model.describe(root.snapshot())

  function refreshFiles() {
    limitEndFile.reload()
    limitStartFile.reload()
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

  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshFiles()
  }

  // ---- Panel host contract -------------------------------------------
  // Bar.findPanelWidget requires open/close/opened on the bar-widget root,
  // and the popout coordinator reads popoutSwitchClosing back off it.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.geoochi.mac-battctl"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function togglePercentage(): void { root.togglePercentage() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showPercentage && !vertical
      ? root.capacity + "% " + root.info.icon
      : root.info.icon
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    tooltipText: root.info.key === "absent" ? "" : Model.tooltipText(root.snapshot())
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else root.togglePanel()
    }
  }
}

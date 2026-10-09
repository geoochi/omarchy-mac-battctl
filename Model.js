// Pure helpers for the power widget. No QML imports on purpose: the state
// machine and the parsers stay exercisable on their own.
//
// Live battery facts come from Quickshell's UPower binding. The charge limit
// does not: UPower reports its own hwdb default (75-80% on Apple Silicon)
// instead of what the firmware actually holds, so the widget reads the real
// values from sysfs and /etc/battctl.conf.

var MIN_LIMIT = 10
var STEP_LIMIT = 5
var HYSTERESIS = 5

var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
var fullIcon = "󰂅"

var chargingPhrases = [
  "Pumping power",
  "Injecting electrons",
  "Pouring juice",
  "Amassing watts",
  "Hoarding joules",
  "Sucking volts",
  "Topping reserves",
  "Soaking amps",
  "Inhaling kilowatts"
]

var onBatteryPhrases = [
  "Slurping power",
  "Spending joules",
  "Draining watts",
  "Burning electrons",
  "Sipping juice",
  "Spending coulombs",
  "Bleeding amps",
  "Guzzling volts",
  "Munching reserves"
]

function num(value, fallback) {
  var n = Number(String(value === undefined || value === null ? "" : value).trim())
  return isFinite(n) ? n : (fallback === undefined ? 0 : fallback)
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

function selectProfileIndex(index, delta, profiles) {
  var values = Array.isArray(profiles) ? profiles : []
  if (values.length === 0) return 0
  return clampIndex(index + delta, values.length)
}

function profileIcon(name) {
  if (name === "power-saver") return "󰌪"
  if (name === "balanced") return "󰊚"
  if (name === "performance") return "󰓅"
  return "󰂄"
}

function parseProfiles(raw, previousIndex) {
  var lines = String(raw || "").split("\n")
  var list = []
  var active = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    list.push(parts[0])
    if (parts[1] === "1") active = parts[0]
  }
  return {
    profiles: list,
    activeProfile: active,
    profileIndex: clampIndex(previousIndex || 0, list.length)
  }
}

// ---- /etc/battctl.conf ----------------------------------------------------

function confLimit(raw) {
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*charge_limit\s*=\s*([0-9]{1,3})\s*$/)
    if (m) {
      var value = parseInt(m[1], 10)
      return value >= MIN_LIMIT && value <= 100 ? value : -1
    }
  }
  return -1
}

function confMode(raw) {
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*firmware_mode\s*=\s*([A-Za-z_]+)/)
    if (m) return m[1].toLowerCase()
  }
  return ""
}

// ---- state ----------------------------------------------------------------

function cappingPhrases(limit) {
  return [
    "Draining to " + limit + "%",
    "Coming down to the cap",
    "Releasing charge",
    "Backing off to " + limit + "%",
    "Shedding charge"
  ]
}

function limitLabel(start, end) {
  if (end >= 100) return "100% (off)"
  if (start >= MIN_LIMIT && start < end) return start + "-" + end + "%"
  return end + "%"
}

// input: {
//   present, percentage, state: "charging"|"discharging"|"pending"|"full"|"unknown",
//   onBattery, limitStart, limitEnd, phraseIndex
// }
function describe(input) {
  var capacity = clamp(Math.round(num(input.percentage, 0)), 0, 100)
  var limitEnd = clamp(Math.round(num(input.limitEnd, 100)), 0, 100)
  var limitStart = clamp(Math.round(num(input.limitStart, 0)), 0, 100)
  var limitActive = limitEnd < 100
  var state = String(input.state || "unknown")
  var onBattery = input.onBattery === true
  var iconIndex = clampIndex(Math.floor(capacity / 10), defaultIcons.length)

  var key
  var label
  var phrases = []

  if (input.present !== true) {
    key = "absent"
    label = ""
  } else if (onBattery) {
    key = "onBattery"
    label = "On battery"
    phrases = onBatteryPhrases
  } else if (state === "discharging") {
    if (limitActive) {
      key = "capping"
      label = "Discharging to limit"
      phrases = cappingPhrases(limitEnd)
    } else {
      key = "idle"
      label = "Discharging on AC"
    }
  } else if (limitActive && (state === "pending" || state === "full" || capacity >= limitEnd)) {
    key = "holding"
    label = "Holding at " + limitLabel(limitStart, limitEnd)
  } else if (state === "full") {
    key = "full"
    label = "Fully charged"
  } else if (state === "charging") {
    key = "charging"
    label = limitActive ? "Charging to " + limitEnd + "%" : "Charging"
    phrases = chargingPhrases
  } else {
    key = "idle"
    label = "Plugged in"
  }

  var hero = label
  if (phrases.length > 0)
    hero = phrases[clamp(num(input.phraseIndex, 0), 0, phrases.length - 1) % phrases.length]

  var icon = ""
  if (key === "charging") icon = chargingIcons[iconIndex]
  else if (key === "full") icon = fullIcon
  else if (key !== "absent") icon = defaultIcons[iconIndex]

  return {
    key: key,
    capacity: capacity,
    label: label,
    hero: hero,
    phrases: phrases,
    icon: icon
  }
}

function modeNote(mode, limitActive) {
  if (mode === "chwa") return "This firmware only supports 80% or 100%."
  if (mode === "chls" && limitActive) return "The firmware holds it even while the machine is suspended."
  return ""
}

function tooltipText(input) {
  var d = describe(input)
  if (d.key === "absent") return ""
  var parts = ["Battery " + d.capacity + "%"]
  if (d.label) parts.push(d.label)
  var end = Math.round(num(input.limitEnd, 100))
  if (end < 100) parts.push("limit " + limitLabel(Math.round(num(input.limitStart, 0)), end))
  return parts.join(" · ")
}

// ---- formatting -----------------------------------------------------------

function formatWatts(watts) {
  var rounded = Math.round(Math.abs(num(watts, 0)) * 10) / 10
  return (rounded % 1 === 0 ? rounded.toFixed(0) : rounded.toFixed(1)) + "W"
}

function formatWh(wh) {
  var rounded = Math.round(num(wh, 0) * 10) / 10
  return (rounded % 1 === 0 ? rounded.toFixed(0) : rounded.toFixed(1)) + "Wh"
}

function formatDuration(seconds) {
  var s = num(seconds, 0)
  if (s <= 0) return "—"
  var h = Math.floor(s / 3600)
  var m = Math.round((s % 3600) / 60)
  if (h <= 0) return m + "m"
  return m > 0 ? h + "h " + m + "m" : h + "h"
}

if (typeof module !== "undefined") {
  module.exports = {
    MIN_LIMIT: MIN_LIMIT,
    STEP_LIMIT: STEP_LIMIT,
    HYSTERESIS: HYSTERESIS,
    num: num,
    clamp: clamp,
    clampIndex: clampIndex,
    selectProfileIndex: selectProfileIndex,
    profileIcon: profileIcon,
    parseProfiles: parseProfiles,
    confLimit: confLimit,
    confMode: confMode,
    limitLabel: limitLabel,
    describe: describe,
    modeNote: modeNote,
    tooltipText: tooltipText,
    formatWatts: formatWatts,
    formatWh: formatWh,
    formatDuration: formatDuration
  }
}

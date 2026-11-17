function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

function selectProfileIndex(index, delta, profiles) {
  var values = Array.isArray(profiles) ? profiles : []
  if (values.length === 0) return 0
  return clampIndex(index + delta, values.length)
}

function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
  }
  return next
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

function profileIcon(name) {
  if (name === "power-saver") return "󰌪"
  if (name === "balanced") return "󰊚"
  if (name === "performance") return "󰓅"
  return "󰂄"
}

function batteryFraction(device) {
  return device && device.isPresent ? Math.max(0, Math.min(1, device.percentage)) : 0
}

function chargeThresholdActive(device, onBattery, states) {
  var d = device || {}
  var s = states || {}
  if (!(d && d.isPresent && !onBattery)) return false

  var fraction = batteryFraction(d)
  if (d.state === s.Discharging) return false
  if (d.state === s.PendingCharge) return true
  if (d.state === s.FullyCharged && fraction < 0.99) return true
  if (d.state !== s.Charging || fraction >= 0.99) return false

  return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60
}

function batteryIcon(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(9, Math.floor(d.percentage * 10)))
  var threshold = chargeThresholdActive(d, onBattery, states)

  if (threshold) return defaultIcons[index]
  if (d.state === states.FullyCharged) return "󰂅"
  if (!onBattery) return chargingIcons[index]
  return defaultIcons[index]
}

function modeLabel(device, onBattery, states, tr) {
  var t = typeof tr === "function" ? tr : function(key, english) { return english }
  var d = device || {}
  if (!d.isPresent) return ""

  var percentage = d.isPresent ? d.percentage : 0
  if (chargeThresholdActive(d, onBattery, states)) return t("power.threshold", "Threshold")
  if (onBattery) return t("power.onBattery", "On battery")
  if (!onBattery && percentage >= 1) return t("power.fullyCharged", "Fully charged")
  return t("power.charging", "Charging")
}

// omarchy-battery-status --shell answers in plain digits with the unit
// attached ("13.1W", "75-80%"); the panel writes each number in the
// language's digits and decimal separator, keeping its decimals and unit.
function localizeReading(raw, fmt) {
  var f = typeof fmt === "function" ? fmt : function(v, d) { return d === undefined ? String(v) : Number(v).toFixed(d) }
  return String(raw === undefined || raw === null ? "" : raw).replace(/\d+(?:\.\d+)?/g, function(number) {
    var dot = number.indexOf(".")
    return f(Number(number), dot < 0 ? undefined : number.length - dot - 1)
  })
}

function profileLabel(name, tr) {
  var t = typeof tr === "function" ? tr : function(key, english) { return english }
  var value = String(name || "")
  if (value === "power-saver") return t("power.profilePowerSaver", "Power-saver")
  if (value === "balanced") return t("power.profileBalanced", "Balanced")
  if (value === "performance") return t("power.profilePerformance", "Performance")
  return value.charAt(0).toUpperCase() + value.slice(1)
}


// `gdbus call` prints a boolean property as "(<true>,)" or "(<false>,)".
// Anything else (an error, no output) is unknown.
function parseGdbusBoolean(raw) {
  var text = String(raw || "").trim()
  if (text === "(<true>,)") return true
  if (text === "(<false>,)") return false
  return null
}

// chargeLimitReadProc prints three gdbus answers, one per line:
// ChargeThresholdSupported, ChargeThresholdEnabled, ChargeEndThreshold
// ("(<true>,)", "(<false>,)", "(<uint32 80>,)"). A failed call prints an
// empty line. Returns null unless all three parse.
function parseChargeLimit(raw) {
  var lines = String(raw || "").split("\n")
  if (lines.length < 3) return null
  var supported = parseGdbusBoolean(lines[0])
  var enabled = parseGdbusBoolean(lines[1])
  var match = /^\(<uint32 (\d{1,3})>,\)$/.exec(lines[2].trim())
  if (supported === null || enabled === null || !match) return null
  var end = parseInt(match[1], 10)
  if (end < 1 || end > 100) return null
  return { supported: supported, enabled: enabled, end: end }
}

// Rolling window of watt samples: appends one, drops any older than maxAge
// seconds. Non-finite or negative readings are skipped.
function appendSample(samples, watts, now, maxAge) {
  var next = (samples || []).slice()
  var w = Number(watts)
  if (isFinite(w) && w >= 0) next.push({ t: now, w: w })
  while (next.length > 0 && next[0].t < now - maxAge) next.shift()
  return next
}

// top-power.sh prints "name<TAB>cpu" rows. Names are bounded to 40
// characters and at most `limit` rows are kept.
function parseTopApps(raw, limit) {
  var rows = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length && rows.length < (limit || 3); i++) {
    var parts = lines[i].split("\t")
    if (parts.length !== 2 || !parts[0]) continue
    var cpu = parseFloat(parts[1])
    if (!isFinite(cpu) || cpu < 0) continue
    rows.push({ name: parts[0].substring(0, 40), cpu: cpu })
  }
  return rows
}

if (typeof module !== "undefined") {
  module.exports = {
    clampIndex: clampIndex,
    selectProfileIndex: selectProfileIndex,
    parseKeyValue: parseKeyValue,
    parseProfiles: parseProfiles,
    profileIcon: profileIcon,
    batteryFraction: batteryFraction,
    chargeThresholdActive: chargeThresholdActive,
    batteryIcon: batteryIcon,
    modeLabel: modeLabel,
    profileLabel: profileLabel,
    localizeReading: localizeReading,
    parseGdbusBoolean: parseGdbusBoolean,
    parseChargeLimit: parseChargeLimit,
    appendSample: appendSample,
    parseTopApps: parseTopApps
  }
}

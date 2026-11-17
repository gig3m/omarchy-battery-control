import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.gig3m.battery-control"
  ipcTarget: "omarchy.power"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false

  // ---- Additions over the built-in Power widget: charge limit toggle, watts
  //      history and top power users.
  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  property var chargeLimit: null          // {supported, enabled, end} from UPower, null until it answers
  property bool chargeLimitReread: false  // a read was asked for while one was running
  property var wattSamples: []            // [{t: seconds, w: watts}], last 10 min
  property var topApps: []                // [{name, cpu}]

  readonly property string topPowerScript: String(Qt.resolvedUrl("top-power.sh")).replace(/^file:\/\//, "")

  // Sets $battery to the UPower object of the system battery (the one that
  // powers the machine, not a mouse or headset), or exits.
  readonly property string batterySetup:
    'battery=; for device in $(upower -e | grep /battery_); do LC_ALL=C upower -i "$device" | grep -q "power supply: *yes" && { battery=$device; break; }; done; test -n "$battery" || exit 1; '
  readonly property bool showPercentage: setting("showPercentage", false) === true
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0
  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates(), Commons.I18n.t)
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Commons.Color.foreground
  }

  // Cute agent-flavored phrases shown in the hero status line, rotated on a
  // timer so the panel feels alive when current is flowing (either direction).
  readonly property var chargingPhrases: [
    Commons.I18n.t("power.chargingPhrase1"),
    Commons.I18n.t("power.chargingPhrase2"),
    Commons.I18n.t("power.chargingPhrase3"),
    Commons.I18n.t("power.chargingPhrase4"),
    Commons.I18n.t("power.chargingPhrase5"),
    Commons.I18n.t("power.chargingPhrase6"),
    Commons.I18n.t("power.chargingPhrase7"),
    Commons.I18n.t("power.chargingPhrase8"),
    Commons.I18n.t("power.chargingPhrase9")
  ]
  readonly property var onBatteryPhrases: [
    Commons.I18n.t("power.dischargingPhrase1"),
    Commons.I18n.t("power.dischargingPhrase2"),
    Commons.I18n.t("power.dischargingPhrase3"),
    Commons.I18n.t("power.dischargingPhrase4"),
    Commons.I18n.t("power.dischargingPhrase5"),
    Commons.I18n.t("power.dischargingPhrase6"),
    Commons.I18n.t("power.dischargingPhrase7"),
    Commons.I18n.t("power.dischargingPhrase8"),
    Commons.I18n.t("power.dischargingPhrase9")
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current power state.
  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  // The battery script's readings in the current language's digits; the
  // time field already comes translated, so it is shown as it arrives.
  function reading(raw) {
    return Model.localizeReading(raw, Commons.I18n.formatNumber)
  }

  readonly property string heroStatusText: {
    if (fullyCharged) return Commons.I18n.t("power.fullyCharged")
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return modeLabel()
  }

  function refresh() {
    if (!batteryPresent) return

    if (!batteryProc.running) batteryProc.running = true
    if (!profilesProc.running) profilesProc.running = true
    if (!systemProc.running) systemProc.running = true
    readChargeLimit()
    if (!topAppsProc.running) topAppsProc.running = true
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    if (Object.keys(next).length === 0) return
    if (targetName === "battery") batteryInfo = next
    else systemInfo = next
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
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
    actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    actionProc.running = true
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function recordWattSample() {
    var d = UPower.displayDevice
    if (!d || !d.isPresent) return
    wattSamples = Model.appendSample(wattSamples, d.changeRate, Date.now() / 1000, 600)
  }

  // The graph shows one direction: start it over on plug-in or unplug, so
  // drain history is never labelled as charge rate.
  onDischargingChanged: {
    wattSamples = []
    recordWattSample()
  }

  // A read already in flight may predate a change, so ask for another one
  // when it finishes instead of dropping the request.
  function readChargeLimit() {
    if (chargeLimitReadProc.running) chargeLimitReread = true
    else chargeLimitReadProc.running = true
  }

  function toggleChargeLimit() {
    if (!chargeLimit || !chargeLimit.supported || chargeLimitActionProc.running) return
    chargeLimitActionProc.command = ["bash", "-c",
      batterySetup + 'gdbus call --system --dest org.freedesktop.UPower --object-path "$battery" --method org.freedesktop.UPower.Device.EnableChargeThreshold "$1"',
      "_", chargeLimit.enabled ? "false" : "true"]
    chargeLimitActionProc.running = true
  }

  ShellIpc {
    target: "omarchy.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        // Deferred: closing here writes the very property whose change
        // is being notified, which QML reports as a binding loop for
        // Panel.opened on every open attempt without a battery.
        Qt.callLater(function() { root.close() })
        return
      }

      refresh()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  // Reads the limit straight from UPower. omarchy-battery-status drops UPower's
  // thresholds while the limit is off, so its "threshold" can't drive this.
  Process {
    id: chargeLimitReadProc
    command: ["bash", "-c", root.batterySetup
      + 'for p in ChargeThresholdSupported ChargeThresholdEnabled ChargeEndThreshold; do gdbus call --system --dest org.freedesktop.UPower --object-path "$battery" --method org.freedesktop.DBus.Properties.Get org.freedesktop.UPower.Device "$p" || echo; done']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.chargeLimit = Model.parseChargeLimit(text)
    }
    onExited: {
      if (!root.chargeLimitReread) return
      root.chargeLimitReread = false
      running = true
    }
  }

  // Re-read after a change rather than assuming it worked: polkit may refuse.
  Process {
    id: chargeLimitActionProc
    onExited: { root.readChargeLimit(); root.refresh() }
  }

  Process {
    id: topAppsProc
    command: [root.topPowerScript, "2"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.topApps = Model.parseTopApps(text, 3) }
  }

  // Sampled all the time, not only while the panel is open, so the graph has
  // history when it opens. Reads UPower's cached value; spawns nothing.
  Timer {
    interval: 10000
    running: root.batteryPresent
    repeat: true
    triggeredOnStart: true
    onTriggered: root.recordWattSample()
  }

  // Rotate the status phrase while the panel is open and we're in a
  // rotating state (charging or on battery). The text swap is wrapped in a
  // fade so the changeover reads as one organism rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: panel.loadedContent ? panel.loadedContent.heroStatus : null; property: "opacity"
      to: 0.0; duration: Style.duration(150); easing.type: Easing.OutCubic
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: panel.loadedContent ? panel.loadedContent.heroStatus : null; property: "opacity"
      to: 1.0; duration: Style.duration(200); easing.type: Easing.OutCubic
    }
  }

  // If we leave a rotating state mid-swap, halt the animation and snap back
  // to full opacity so "FULLY CHARGED" is legible immediately rather than
  // appearing dimmed.
  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        if (panel.loadedContent) panel.loadedContent.heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.batteryIcon()
    labelText: root.showPercentage && !vertical ? Commons.I18n.formatNumber(Math.round(root.batteryFraction * 100)) + "%" : ""
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1)
    tooltipText: ""
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias heroStatus: heroStatus
      anchors.fill: parent
      implicitHeight: column.implicitHeight
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

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: Style.duration(200) } }
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
              text: Commons.I18n.t("power.battery")
              textFormat: Text.PlainText
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
              text: root.heroStatusText.toUpperCase()
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
            text: root.reading(root.batteryInfo.percentage) || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: Style.duration(200) } }
          }
        }

        // ---------- Battery progress bar ----------
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
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: Style.duration(220) } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened && !Style.reduceMotion
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: Style.duration(950); easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: Style.duration(950); easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Stats ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the section never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: Commons.I18n.t("power.batterySize"); value: root.reading(root.batteryInfo.size) }
            InfoPair { label: Commons.I18n.t("power.chargeCycles"); value: root.reading(root.batteryInfo.cycles) || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? Commons.I18n.t("power.chargeLimit") : (root.discharging ? Commons.I18n.t("power.timeLeft") : Commons.I18n.t("power.timeToFull"))
              value: root.chargeThresholdActive ? (root.reading(root.batteryInfo.threshold) || "-") : (root.batteryFlowIdle ? "-" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              label: root.chargeThresholdActive ? Commons.I18n.t("power.batteryState") : (root.discharging ? Commons.I18n.t("power.discharging") : Commons.I18n.t("power.charging"))
              value: root.chargeThresholdActive ? Commons.I18n.t("power.holding") : (root.batteryFull ? "-" : root.reading(root.batteryInfo.rate))
            }
          }
        }

        // ---------- Watts history ----------
        Column {
          visible: root.wattSamples.length > 1
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(historyHeader.implicitHeight, historyNow.implicitHeight)

            PanelSectionHeader {
              id: historyHeader
              text: (root.discharging ? strings.t("history.drain") : strings.t("history.charge")).toUpperCase()
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            InfoValue {
              id: historyNow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.wattSamples.length > 0
                ? Commons.I18n.formatNumber(root.wattSamples[root.wattSamples.length - 1].w, 1) + "W"
                : ""
            }
          }

          Canvas {
            id: sparkline
            width: parent.width
            height: Style.space(40)
            // Inset so a flat line near 0 W stays visible above the bottom edge.
            readonly property real topInset: Style.space(4)
            readonly property real bottomInset: Style.space(6)
            onWidthChanged: requestPaint()
            onPaint: {
              var ctx = getContext("2d")
              ctx.clearRect(0, 0, width, height)
              var samples = root.wattSamples
              if (samples.length < 2) return
              var maxW = 1
              for (var i = 0; i < samples.length; i++) maxW = Math.max(maxW, samples[i].w)
              maxW *= 2  // scale to twice the peak, so a steady draw sits mid-graph
              var minT = samples[0].t
              var spanT = Math.max(1, samples[samples.length - 1].t - minT)
              var plotHeight = height - topInset - bottomInset
              ctx.strokeStyle = Style.selectedStateColor(root.bar.foreground, Commons.Color.accent)
              ctx.lineWidth = 1.5
              ctx.beginPath()
              for (var j = 0; j < samples.length; j++) {
                var x = ((samples[j].t - minT) / spanT) * width
                var y = topInset + plotHeight - (samples[j].w / maxW) * plotHeight
                if (j === 0) ctx.moveTo(x, y)
                else ctx.lineTo(x, y)
              }
              ctx.stroke()
            }

            Connections {
              target: root
              function onWattSamplesChanged() { sparkline.requestPaint() }
            }
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
            text: Commons.I18n.t("power.powerProfile")
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
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: Model.profileLabel(modelData, Commons.I18n.t)
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

        // ---------- Charge limit ----------
        // Shown only when the battery reports a threshold and UPower has
        // answered whether it is enforced.
        Column {
          visible: !!root.chargeLimit && root.chargeLimit.supported
          width: parent.width
          spacing: Style.space(10)

          PanelSeparator { foreground: root.bar.foreground }

          Toggle {
            width: parent.width
            label: strings.t("chargeLimit.title")
            description: (root.chargeLimit && root.chargeLimit.enabled ? strings.t("chargeLimit.on") : strings.t("chargeLimit.off"))
              .arg(root.chargeLimit ? Commons.I18n.formatNumber(root.chargeLimit.end) + "%" : "")
            checked: !!root.chargeLimit && root.chargeLimit.enabled
            foreground: root.bar.foreground
            accent: Commons.Color.accent
            fontFamily: root.bar.fontFamily
            onClicked: root.toggleChargeLimit()
          }
        }

        // ---------- Top power users ----------
        Column {
          visible: root.topApps.length > 0
          width: parent.width
          spacing: Style.spacing.labelGap

          PanelSeparator { foreground: root.bar.foreground }

          PanelSectionHeader {
            text: strings.t("topApps.title").toUpperCase()
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Repeater {
            model: root.topApps
            InfoPair {
              required property var modelData
              label: modelData.name
              value: strings.t("topApps.cpu").arg(Commons.I18n.formatNumber(modelData.cpu, 0))
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

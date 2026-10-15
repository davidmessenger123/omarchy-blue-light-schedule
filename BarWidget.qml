pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

// Blue Light Schedule — bar surface for the plugin.
//
// A thin view: every decision (when to tint, how warm) belongs to the shared
// davidjm.blue-light-schedule service, and this widget only renders the
// service's state and edits it through service.update(). The panel is where the
// user actually picks the window, so that is where the controls live.
//
// Left click: schedule panel. The -/+ steppers are deliberate rather than a
// text field: a "start time" that can be typed into a wrong shape is a worse
// experience than one that can only ever be a valid clock time.
BarWidget {
  id: root

  moduleName: "davidjm.blue-light-schedule"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var svc: bar && bar.shell
    ? bar.shell.serviceFor("davidjm.blue-light-schedule") : null
  readonly property var cfg: svc ? (svc.settings || ({})) : ({})

  readonly property bool ready: svc !== null
  readonly property bool enabledNow: cfg.enabled === true
  readonly property bool filterOn: svc ? svc.scheduleActive : false
  readonly property string startTime: cfg.start || "—"
  readonly property string stopTime: cfg.stop || "—"
  readonly property int temperature: cfg.temperature || 4000
  readonly property string liveTemperature: svc ? (svc.currentTemperature || "") : ""
  readonly property string changeIn: svc ? svc.changeIn : "—"

  property bool panelOpen: false

  function togglePanel() { root.panelOpen = !root.panelOpen }
  function closePanel() { root.panelOpen = false }
  // KeyboardPanel funnels outside-click dismissal and popout handoff through
  // `owner`; both call these.
  function close() { root.closePanel() }
  function closeForPopoutSwitch() { root.closePanel() }

  function update(patch) {
    if (root.svc) root.svc.update(patch)
  }

  function tempLabel(kelvin) {
    var n = Number(kelvin)
    if (!isFinite(n)) return "—"
    return n + " K"
  }

  // The preset list, plus whatever the settings file actually holds so a hand
  // -edited temperature still shows as selected instead of an empty row.
  readonly property var temperatureOptions: {
    var presets = [3000, 3500, 4000, 4500, 5000, 5500]
    var current = root.temperature
    if (presets.indexOf(current) === -1) {
      presets = presets.concat([current])
      presets.sort(function(a, b) { return a - b })
    }
    return presets.map(function(k) { return { value: String(k), label: root.tempLabel(k) } })
  }

  // ------------------------------------------------------------------ bar

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // U+F185 fa-sun / U+F186 fa-moon. Sun when the filter is actually tinting,
    // moon when the schedule is waiting for its next window.
    text: !root.ready ? "\uF185  —"
      : !root.enabledNow ? "\uF186  off"
      : root.filterOn ? "\uF185  " + root.tempLabel(root.temperature)
      : "\uF186  " + root.changeIn
    tooltipText: !root.ready ? "blue light schedule — starting"
      : "Blue light " + (root.enabledNow ? (root.filterOn ? "on" : "off") : "disabled")
        + " · " + root.startTime + " – " + root.stopTime
        + " · " + root.tempLabel(root.temperature)
        + (root.liveTemperature ? " · screen at " + root.liveTemperature + " K" : "")
        + (root.enabledNow ? " · changes in " + root.changeIn : "")
        + " — click to edit"
    horizontalMargin: 6
    active: root.filterOn
    dimmed: root.ready && !root.enabledNow
    onPressed: function(mouseButton) { root.togglePanel() }
  }

  // ---------------------------------------------------------------- panel

  component LabelText: Text {
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1
  }

  component ValueText: Text {
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.heading
    font.bold: true
  }

  // A clock time with 15-minute steppers either side. `which` is the schedule
  // key ("start" / "stop"); the service does the wrapping arithmetic so the
  // panel never has to think about midnight.
  component TimeRow: RowLayout {
    id: row
    required property string which
    required property string label
    required property string value
    required property var svc
    spacing: Style.space(6)

    LabelText {
      text: row.label
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
    }

    PanelActionButton {
      iconText: "−"
      focusable: true
      tooltipText: "15 minutes earlier"
      onClicked: row.svc.stepTime(row.which, -15)
    }

    ValueText {
      text: row.value
      Layout.preferredWidth: Style.space(62)
      horizontalAlignment: Text.AlignHCenter
    }

    PanelActionButton {
      iconText: "+"
      focusable: true
      tooltipText: "15 minutes later"
      onClicked: row.svc.stepTime(row.which, 15)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.panelOpen
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(form.implicitHeight)

    PanelKeyCatcher {
      anchors.fill: parent
      onCloseRequested: root.closePanel()

      ColumnLayout {
        id: form
        anchors.fill: parent
        spacing: Style.space(8)

        Text {
          text: "BLUE LIGHT SCHEDULE"
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 2
        }

        Text {
          text: !root.ready ? "starting…"
            : root.enabledNow
              ? (root.filterOn ? "Filtering now · off at " + root.stopTime
                               : "Not filtering · on at " + root.startTime)
              : "Schedule disabled"
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          Layout.fillWidth: true
          Layout.topMargin: -4
          elide: Text.ElideRight
        }

        Toggle {
          label: "Follow a daily schedule"
          description: "hyprsunset applies the temperature between the two times below"
          checked: root.enabledNow
          Layout.fillWidth: true
          onClicked: root.update({ enabled: !root.enabledNow })
        }

        PanelSectionHeader {
          text: "WINDOW"
          Layout.fillWidth: true
          Layout.topMargin: Style.space(2)
        }

        TimeRow {
          which: "start"
          label: "FILTER ON"
          value: root.startTime
          svc: root.svc
          Layout.fillWidth: true
          enabled: root.enabledNow
          opacity: root.enabledNow ? 1 : 0.45
        }

        TimeRow {
          which: "stop"
          label: "FILTER OFF"
          value: root.stopTime
          svc: root.svc
          Layout.fillWidth: true
          enabled: root.enabledNow
          opacity: root.enabledNow ? 1 : 0.45
        }

        Text {
          text: root.startTime === root.stopTime
            ? "Start and stop are the same, so the window is empty."
            : (root.cfg.start > root.cfg.stop
                ? "Overnight window — it runs past midnight."
                : "")
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          Layout.fillWidth: true
          visible: text !== ""
          wrapMode: Text.WordWrap
        }

        PanelSectionHeader {
          text: "TEMPERATURE"
          Layout.fillWidth: true
          Layout.topMargin: Style.space(2)
        }

        Dropdown {
          value: String(root.temperature)
          options: root.temperatureOptions
          Layout.fillWidth: true
          onChanged: function(value) { root.update({ temperature: Number(value) }) }
        }

        PanelSeparator {
          Layout.fillWidth: true
        }

        Text {
          text: {
            if (!root.ready) return "starting…"
            var parts = []
            parts.push("screen " + (root.liveTemperature ? root.liveTemperature + " K" : "—"))
            if (root.enabledNow && root.changeIn !== "—") parts.push("changes in " + root.changeIn)
            if (root.svc && !root.svc.hyprsunsetRunning) parts.push("hyprsunset not running")
            if (root.svc && root.svc.confDisabled) parts.push("hyprsunset.conf has disable = true")
            return parts.join(" · ")
          }
          color: (root.svc && (!root.svc.hyprsunsetRunning || root.svc.confDisabled))
            ? Color.urgent : Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          Layout.fillWidth: true
          wrapMode: Text.WordWrap
        }

        Text {
          text: root.svc && root.svc.lastError ? root.svc.lastError : ""
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          Layout.fillWidth: true
          visible: text !== ""
          wrapMode: Text.WordWrap
        }

        // hyprsunset is not a systemd service, so the service puts it back on
        // its own. This is for the impatient: "I know the screen is wrong, fix
        // it now" rather than waiting for the next poll.
        Button {
          Layout.fillWidth: true
          text: "Re-apply now"
          onClicked: if (root.svc) root.svc.refresh()
        }
      }
    }
  }
}
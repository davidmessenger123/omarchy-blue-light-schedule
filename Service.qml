pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Blue Light Schedule — puts a hyprsunset colour temperature on the screen
// during a daily window the user picks (default 20:00 -> 07:00), and takes it
// off again at the stop time.
//
// The timing is hyprsunset's job, not a QML timer's. This service writes the
// window into ~/.config/hypr/hyprsunset.conf as a managed block -- one profile
// with the temperature at `start`, one identity profile at `stop` -- and then
// restarts hyprsunset. hyprsunset re-checks the profile set every minute, so
// the schedule keeps working across shell restarts and even while the shell is
// not running. A timer inside the shell would only be correct while the shell
// happened to be alive.
//
// The service owns three things, and the bar widget is a thin view over them:
//   * ~/.config/blue-light-schedule/settings.json  -- the user's choices
//   * the managed block in hyprsunset.conf          -- the applied schedule
//   * the live readout (is hyprsunset up, what K is it at) for the bar
//
// The one thing that is *not* ours is the profile set in hyprsunset.conf. Any
// uncommented `profile { }` block we did not write is removed before the
// managed block goes in, because two profiles disagreeing about the same minute
// is exactly the kind of thing that silently does nothing. The user's original
// file is copied to hyprsunset.conf.bak.<timestamp> before the first edit.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/blue-light-schedule"
  readonly property string settingsPath: configDir + "/settings.json"
  readonly property string hyprsunsetConf: home + "/.config/hypr/hyprsunset.conf"

  readonly property string markerBegin: "# >>> davidjm.blue-light-schedule >>>"
  readonly property string markerEnd: "# <<< davidjm.blue-light-schedule <<<"

  readonly property var defaults: ({
    version: 1,
    enabled: true,
    start: "20:00",
    stop: "07:00",
    temperature: 4000
  })

  // Valid bounds for hyprsunset's temperature, in kelvin.
  readonly property int minTemperature: 1000
  readonly property int maxTemperature: 10000

  property var settings: root.defaults
  property bool settingsResolved: false
  property bool confResolved: false
  property bool dirsReady: false
  property bool backedUp: false
  property string appliedSignature: ""
  property bool restartInFlight: false
  property bool restartQueued: false
  property int consecutiveMisses: 0
  property double lastRestartAt: 0
  readonly property int restartCooldownMs: 15000
  property bool writePending: false
  property bool restartAfterWrite: false
  property int watchTicks: 0

  // Live state, read back from hyprsunset rather than assumed from the schedule.
  property bool hyprsunsetRunning: false
  property string currentTemperature: ""
  property bool confDisabled: false
  property bool applied: false
  property string lastAction: "starting"
  property string lastError: ""

  // Clock. The bar shows "on/off" from this, so it tracks the schedule even
  // between polls; hyprsunset itself is what actually changes the screen.
  property int nowMinutes: root.minutesOfDay(new Date())

  readonly property bool scheduleActive: root.settings.enabled && root.isActive(root.nowMinutes)
  readonly property int minutesToChange: root.minutesToNextBoundary(root.nowMinutes)
  readonly property string changeIn: root.describeMinutes(root.minutesToChange)
  readonly property string wrapsMidnight: root.toMinutes(root.settings.start) > root.toMinutes(root.settings.stop)

  // ------------------------------------------------------------- validation

  // "7:5" -> "07:05"; anything not a real clock time -> the fallback.
  function normalizeTime(value, fallback) {
    var s = String(value === undefined || value === null ? "" : value).trim()
    var m = /^([0-9]{1,2}):([0-9]{1,2})$/.exec(s)
    if (!m) return fallback
    var h = parseInt(m[1], 10)
    var mi = parseInt(m[2], 10)
    if (!(h >= 0 && h <= 23) || !(mi >= 0 && mi <= 59)) return fallback
    return (h < 10 ? "0" + h : "" + h) + ":" + (mi < 10 ? "0" + mi : "" + mi)
  }

  function normalizeTemperature(value, fallback) {
    var n = Number(value)
    if (!isFinite(n)) return fallback
    return Math.max(root.minTemperature, Math.min(root.maxTemperature, Math.round(n)))
  }

  // A hand-edited settings file must never put a wrong type into a binding.
  function normalize(raw) {
    var d = root.defaults
    var s = raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}
    return {
      version: 1,
      enabled: typeof s.enabled === "boolean" ? s.enabled : d.enabled,
      start: root.normalizeTime(s.start, d.start),
      stop: root.normalizeTime(s.stop, d.stop),
      temperature: root.normalizeTemperature(s.temperature, d.temperature)
    }
  }

  // ----------------------------------------------------------------- clock

  function toMinutes(hhmm) {
    var m = /^([0-9]{2}):([0-9]{2})$/.exec(String(hhmm))
    if (!m) return 0
    return parseInt(m[1], 10) * 60 + parseInt(m[2], 10)
  }

  function fromMinutes(mins) {
    var m = ((mins % 1440) + 1440) % 1440
    var h = Math.floor(m / 60)
    var mi = m % 60
    return (h < 10 ? "0" + h : "" + h) + ":" + (mi < 10 ? "0" + mi : "" + mi)
  }

  function minutesOfDay(date) {
    return date.getHours() * 60 + date.getMinutes()
  }

  // The window is [start, stop). When start > stop it wraps past midnight,
  // which is the normal case for an evening filter.
  function isActive(minutes) {
    var s = root.toMinutes(root.settings.start)
    var e = root.toMinutes(root.settings.stop)
    if (s === e) return false
    if (s < e) return minutes >= s && minutes < e
    return minutes >= s || minutes < e
  }

  function minutesToNextBoundary(minutes) {
    if (!root.settings.enabled) return -1
    var s = root.toMinutes(root.settings.start)
    var e = root.toMinutes(root.settings.stop)
    if (s === e) return -1
    var best = -1
    var edges = [s, e]
    for (var i = 0; i < edges.length; i++) {
      var d = edges[i] - minutes
      if (d <= 0) d += 1440
      if (best === -1 || d < best) best = d
    }
    return best
  }

  function describeMinutes(mins) {
    if (mins < 0) return "—"
    if (mins === 0) return "now"
    if (mins < 60) return mins + " min"
    var h = Math.floor(mins / 60)
    var m = mins % 60
    return m === 0 ? h + " h" : h + " h " + m + " min"
  }

  // ------------------------------------------------------------ the conf

  // The block we own. Comments and non-profile settings above it are kept.
  function managedBlock() {
    var out = []
    out.push(root.markerBegin)
    out.push("# Managed by the davidjm.blue-light-schedule Omarchy plugin.")
    out.push("# Set the times from the bar widget's panel instead of editing here —")
    out.push("# this block is rewritten every time the schedule changes.")

    if (!root.settings.enabled) {
      // Disabled is a real state, not "no profiles": identity at midnight
      // means hyprsunset never tints, and it keeps running so a tint applied
      // earlier is actively undone rather than merely abandoned.
      out.push("profile {")
      out.push("    time = 00:00")
      out.push("    identity = true")
      out.push("}")
    } else if (root.settings.start === root.settings.stop) {
      // A zero-length window can never be active, so it gets the identity
      // profile rather than two profiles fighting over the same minute.
      out.push("profile {")
      out.push("    time = " + root.settings.stop)
      out.push("    identity = true")
      out.push("}")
      out.push("# start and stop are both " + root.settings.start + ", so this window is empty.")
    } else {
      out.push("# filter on at " + root.settings.start)
      out.push("profile {")
      out.push("    time = " + root.settings.start)
      out.push("    temperature = " + root.settings.temperature)
      out.push("}")
      out.push("")
      out.push("# filter off at " + root.settings.stop)
      out.push("profile {")
      out.push("    time = " + root.settings.stop)
      out.push("    identity = true")
      out.push("}")
    }

    out.push(root.markerEnd)
    return out.join("\n") + "\n"
  }

  // Remove our previous managed block, then every remaining uncommented
  // `profile { }` block. Commented-out profiles (like the stock Omarchy
  // hyprsunset.conf ships) are left alone — they are documentation.
  //
  // Returns null if the file has an unterminated profile block, in which case
  // the caller must not write: stripping it would swallow the rest of the file.
  function stripProfiles(text) {
    var src = String(text === undefined || text === null ? "" : text)

    var begin = src.indexOf(root.markerBegin)
    if (begin !== -1) {
      var end = src.indexOf(root.markerEnd, begin)
      if (end !== -1) {
        var after = end + root.markerEnd.length
        if (src[after] === "\n") after++
        src = src.slice(0, begin) + src.slice(after)
      }
    }

    var lines = src.split("\n")
    var kept = []
    var depth = 0
    var started = false
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (!started && /^\s*profile\s*\{/.test(line)) {
        started = true
        depth = 1
        continue
      }
      if (started) {
        depth += (line.match(/\{/g) || []).length
        depth -= (line.match(/\}/g) || []).length
        if (depth <= 0) {
          started = false
          depth = 0
        }
        continue
      }
      kept.push(line)
    }

    // Still inside a block at EOF means the file is malformed or mid-edit.
    if (started) return null
    return kept.join("\n")
  }

  function composeSchedule(existing) {
    var stripped = root.stripProfiles(existing)
    if (stripped === null) return null
    var body = stripped.replace(/\s+$/, "")
    var head = body.length ? body + "\n\n" : ""
    return head + root.managedBlock()
  }

  // Reads the temperature profile back out of the managed block, so the panel
  // can say "applied" about what hyprsunset actually has rather than what we
  // last asked for.
  function parseManaged(text) {
    var src = String(text === undefined || text === null ? "" : text)
    var begin = src.indexOf(root.markerBegin)
    if (begin === -1) return null
    var end = src.indexOf(root.markerEnd, begin)
    if (end === -1) return null
    var block = src.slice(begin, end)
    var temps = []
    var times = []
    var re = /(time|temperature|identity)\s*=\s*([0-9]{1,2}:[0-9]{2}|[0-9]+|true|false)/g
    var m
    while ((m = re.exec(block)) !== null) {
      if (m[1] === "time") times.push(m[2])
      else if (m[1] === "temperature") temps.push(parseInt(m[2], 10))
    }
    return { times: times, temperature: temps.length ? temps[0] : null }
  }

  // ------------------------------------------------------------- applying

  // Every input has to have landed before the conf is rewritten. Applying
  // against a confFile that has not loaded yet would read it as empty and
  // replace the user's commented-out stock file with nothing but our block.
  function readyToApply() {
    return root.dirsReady && root.settingsResolved && root.confResolved
  }

  // What hyprsunset has been told, as one comparable string. applySchedule is
  // reached from several independent async completions (settings, conf, mkdir),
  // so it runs several times per change; without this each of those would
  // restart hyprsunset again for a schedule that is already correct.
  function scheduleSignature() {
    var s = root.settings
    return (s.enabled ? "1" : "0") + "|" + s.start + "|" + s.stop + "|" + s.temperature
  }

  function applySchedule() {
    if (!root.readyToApply()) return
    if (root.writePending) return

    var existing = confFile.text()
    var composed = root.composeSchedule(existing)
    if (composed === null) {
      root.lastError = "hyprsunset.conf has an unterminated profile block; not touching it."
      return
    }
    if (composed === existing) {
      // The conf is already right. hyprsunset still has to be (re)started if it
      // has not seen this schedule -- notably on shell start, where it may have
      // been killed and restarted, or never launched at all.
      if (root.appliedSignature !== root.scheduleSignature()) {
        root.appliedSignature = root.scheduleSignature()
        root.restartHyprsunset()
      }
      return
    }
    // The schedule owns the profile set, so the first edit is the one that
    // destroys whatever was there. Keep a copy before that happens, once.
    if (existing.length && !backupProc.running && !root.backedUp) {
      backupProc.running = false
      backupProc.running = true
      return
    }
    root.writePending = true
    root.restartAfterWrite = true
    confFile.setText(composed)
  }

  // Re-send the current schedule to hyprsunset. For the panel's "apply now",
  // and for when hyprsunset was killed behind our back.
  function refresh() {
    if (!root.readyToApply()) return
    root.restartHyprsunset()
  }

  function update(patch) {
    var merged = {}
    var current = root.settings || {}
    for (var k in current) merged[k] = current[k]
    if (patch && typeof patch === "object") {
      for (var p in patch) merged[p] = patch[p]
    }
    root.settings = root.normalize(merged)
    root.saveSettings()
    root.applySchedule()
  }

  // Step a time by whole minutes, wrapping across midnight. The panel uses
  // this for its -/+ buttons so the user never types a malformed time.
  function stepTime(which, deltaMinutes) {
    var current = root.toMinutes(root.settings[which])
    root.update(which, root.fromMinutes(current + deltaMinutes))
  }

  function saveSettings() {
    if (root.settingsResolved) settingsFile.setText(JSON.stringify(root.settings, null, 2) + "\n")
  }

  // omarchy-restart-app kills the old scope before spawning the new one, so two
  // restarts in flight kill each other and leave nothing running. Queue instead
  // of overlapping, and apply the same rule to the self-heal below.
  function restartHyprsunset() {
    root.lastRestartAt = new Date().getTime()
    if (root.restartInFlight) {
      root.restartQueued = true
      return
    }
    root.restartInFlight = true
    restartProc.running = true
  }

  // ------------------------------------------------------------- readback

  // One process answers both questions the bar cares about. hyprctl needs the
  // socket hyprsunset creates, so "is it running" gates the temperature read.
  function queryState() {
    root.nowMinutes = root.minutesOfDay(new Date())
    if (!queryProc.running) queryProc.running = true
  }

  function applyQueryOutput(output) {
    var raw = String(output === undefined || output === null ? "" : output)
    if (/^STOPPED/.test(raw.trim())) {
      root.hyprsunsetRunning = false
      root.currentTemperature = ""
      root.selfHeal()
      return
    }
    root.hyprsunsetRunning = true
    root.consecutiveMisses = 0
    root.lastError = ""
    // hyprctl prints the bare temperature on success, but its failure text embeds
    // the hyprsunset socket path, which is full of digit runs ("/run/user/1000/
    // .../1325033211"). Only a whole-output number is trusted; anything else is
    // treated as "temperature unknown" rather than guessed at.
    var t = raw.trim()
    var strict = /^[0-9]{3,6}$/.exec(t)
    if (strict) root.currentTemperature = strict[0]
    else if (/temperature (?:is )?([0-9]{3,6})/i.exec(t)) root.currentTemperature = RegExp.$1
    else root.currentTemperature = ""
  }

  // ---------------------------------------------------------------- files

  Process {
    running: true
    command: ["mkdir", "-p", "--", root.configDir]
    onExited: function(exitCode, exitStatus) {
      root.dirsReady = exitCode === 0
      if (root.dirsReady) root.applySchedule()
    }
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    blockWrites: true
    printErrors: false
    onLoaded: {
      var parsed = null
      try { parsed = JSON.parse(text()) } catch (e) { parsed = null }
      root.settings = root.normalize(parsed)
      root.settingsResolved = true
      settingsRetry.stop()
      root.applySchedule()
    }
    // No file yet is the first run: the defaults stand, and they are written
    // out so the schedule is discoverable as a file the user can also edit.
    // (Editing that file by hand works too -- the view is watched.)
    onLoadFailed: {
      root.settingsResolved = true
      root.saveSettings()
      root.applySchedule()
      // Quickshell only watches a path that resolved to a file at load time,
      // so a file that did not exist when this started is never noticed when
      // it appears -- including the one just written above. Re-read until it
      // does, then stop watching via the timer.
      settingsRetry.restart()
    }
    onFileChanged: reload()
  }

  Timer {
    id: settingsRetry
    interval: 3000
    repeat: true
    onTriggered: settingsFile.reload()
  }

  FileView {
    id: confFile
    path: root.hyprsunsetConf
    watchChanges: true
    blockWrites: true
    printErrors: false
    onLoaded: {
      var parsed = root.parseManaged(text())
      root.applied = parsed !== null
      root.confDisabled = /^\s*disable\s*=\s*true\s*$/m.test(text())
      root.confResolved = true
      confRetry.stop()
      if (root.writePending) {
        root.writePending = false
        root.lastAction = "schedule written to hyprsunset.conf"
        root.lastError = ""
      }
      if (root.restartAfterWrite) {
        root.restartAfterWrite = false
        root.appliedSignature = root.scheduleSignature()
        root.restartHyprsunset()
      }
      root.applySchedule()
    }
    // A missing hyprsunset.conf is legitimate: write the managed block and
    // hyprsunset will read it on start. Same un-watched-path problem as the
    // settings file, so it gets the same retry until it shows up.
    onLoadFailed: {
      root.applied = false
      root.confResolved = true
      confRetry.restart()
      root.applySchedule()
    }
    onFileChanged: reload()
  }

  Timer {
    id: confRetry
    interval: 3000
    repeat: true
    onTriggered: confFile.reload()
  }

  // -------------------------------------------------------------- process

  // The schedule owns the profile set in hyprsunset.conf, so the first time it
  // writes, whatever was in that file goes away. Keep one copy. The name is
  // fixed rather than timestamped so it is taken exactly once, no matter how
  // many times the shell restarts.
  Process {
    id: backupProc
    running: false
    command: ["cp", "-n", "--", root.hyprsunsetConf, root.hyprsunsetConf + ".bak.pre-blue-light-schedule"]
    onExited: function(exitCode, exitStatus) {
      root.backedUp = true
      if (exitCode !== 0) root.lastError = "could not back up hyprsunset.conf (cp exited " + exitCode + ")"
      root.applySchedule()
    }
  }

  Process {
    id: restartProc
    running: false
    command: ["omarchy-restart-hyprsunset"]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.lastError = String(text || "").trim().split("\n").slice(-3).join(" ")
      }
    }
    onExited: function(exitCode, exitStatus) {
      root.restartInFlight = false
      if (exitCode !== 0) {
        root.lastError = "omarchy-restart-hyprsunset exited " + exitCode
      } else {
        // Give hyprsunset a moment to create its socket before the first read.
        root.watchTicks = Math.max(root.watchTicks, 4)
      }
      if (root.restartQueued) {
        root.restartQueued = false
        Qt.callLater(root.restartHyprsunset)
      }
      Qt.callLater(root.queryState)
    }
  }

  // Nothing in Omarchy keeps hyprsunset alive: it is not a systemd service, and
  // the stock hyprsunset.conf does not launch it. So when the schedule is meant
  // to be filtering and hyprsunset turns out to be gone, put it back rather
  // than leaving the screen untinted until the next login. Bounded, so a
  // hyprsunset that refuses to start is retried a few times and then reported
  // instead of being respawned forever.
  function selfHeal() {
    if (!root.settings.enabled) return
    if (root.restartInFlight) return
    if (root.consecutiveMisses >= 3) {
      root.lastError = "hyprsunset keeps exiting; schedule is not being applied"
      return
    }
    var now = new Date().getTime()
    if (now - root.lastRestartAt < root.restartCooldownMs) return
    root.consecutiveMisses++
    root.restartHyprsunset()
  }

  Process {
    id: queryProc
    running: false
    command: ["sh", "-c",
      "pgrep -x hyprsunset >/dev/null || { echo STOPPED; exit 0; }; "
      + "hyprctl hyprsunset temperature 2>/dev/null || echo NOTEMP"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.applyQueryOutput(String(text || ""))
      }
    }
  }

  Timer {
    running: true
    repeat: true
    // watchTicks is how many more fast polls are owed after an action; between
    // actions this drops to a slow poll, because nothing about the readout
    // changes except at a boundary.
    interval: root.watchTicks > 0 ? 2000 : 60000
    onTriggered: {
      if (root.watchTicks > 0) root.watchTicks--
      root.queryState()
    }
  }

  // Keep the clock-derived state honest between polls.
  Timer {
    interval: 20000
    repeat: true
    running: true
    onTriggered: root.nowMinutes = root.minutesOfDay(new Date())
  }

  Component.onCompleted: {
    root.watchTicks = 5
    root.queryState()
  }
}
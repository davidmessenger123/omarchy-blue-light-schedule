const markerBegin = "# >>> davidjm.blue-light-schedule >>>"
const markerEnd = "# <<< davidjm.blue-light-schedule <<<"

function normalizeTime(value, fallback) {
  var s = String(value === undefined || value === null ? "" : value).trim()
  var m = /^([0-9]{1,2}):([0-9]{1,2})$/.exec(s)
  if (!m) return fallback
  var h = parseInt(m[1], 10); var mi = parseInt(m[2], 10)
  if (!(h >= 0 && h <= 23) || !(mi >= 0 && mi <= 59)) return fallback
  return (h < 10 ? "0" + h : "" + h) + ":" + (mi < 10 ? "0" + mi : "" + mi)
}
function toMinutes(hhmm) { var m = /^([0-9]{2}):([0-9]{2})$/.exec(String(hhmm)); return m ? parseInt(m[1],10)*60+parseInt(m[2],10) : 0 }
function fromMinutes(mins) { var m=((mins%1440)+1440)%1440, h=Math.floor(m/60), mi=m%60; return (h<10?"0"+h:""+h)+":"+(mi<10?"0"+mi:""+mi) }
function isActive(settings, minutes) {
  var s = toMinutes(settings.start), e = toMinutes(settings.stop)
  if (s === e) return false
  if (s < e) return minutes >= s && minutes < e
  return minutes >= s || minutes < e
}
function minutesToNextBoundary(settings, minutes) {
  var s = toMinutes(settings.start), e = toMinutes(settings.stop)
  if (s === e) return -1
  var best = -1; var edges = [s, e]
  for (var i=0;i<edges.length;i++){ var d=edges[i]-minutes; if(d<=0)d+=1440; if(best===-1||d<best)best=d }
  return best
}
function stripProfiles(text) {
  var src = String(text === undefined || text === null ? "" : text)
  var begin = src.indexOf(markerBegin)
  if (begin !== -1) { var end = src.indexOf(markerEnd, begin)
    if (end !== -1) { var after = end + markerEnd.length; if (src[after] === "\n") after++; src = src.slice(0,begin)+src.slice(after) } }
  var lines = src.split("\n"), kept = [], depth = 0, started = false
  for (var i=0;i<lines.length;i++){ var line=lines[i]
    if (!started && /^\s*profile\s*\{/.test(line)) { started=true; depth=1; continue }
    if (started) { depth += (line.match(/\{/g)||[]).length; depth -= (line.match(/\}/g)||[]).length
      if (depth<=0){started=false;depth=0} continue }
    kept.push(line) }
  if (started) return null
  return kept.join("\n")
}
function managedBlock(settings) {
  var out=[]; out.push(markerBegin)
  out.push("profile {"); out.push("    time = " + settings.start); out.push("    temperature = " + settings.temperature); out.push("}")
  out.push(""); out.push("profile {"); out.push("    time = " + settings.stop); out.push("    identity = true"); out.push("}")
  out.push(markerEnd); return out.join("\n") + "\n"
}
function composeSchedule(settings, existing) {
  var stripped = stripProfiles(existing)
  if (stripped === null) return null
  var body = stripped.replace(/\s+$/, "")
  var head = body.length ? body + "\n\n" : ""
  return head + managedBlock(settings)
}
function parseManaged(text) {
  var src=String(text||""); var b=src.indexOf(markerBegin); if(b===-1) return null
  var e=src.indexOf(markerEnd,b); if(e===-1) return null
  var block=src.slice(b,e); var temps=[],times=[]; var re=/(time|temperature|identity)\s*=\s*([0-9]{1,2}:[0-9]{2}|[0-9]+|true|false)/g, m
  while((m=re.exec(block))!==null){ if(m[1]==="time")times.push(m[2]); else if(m[1]==="temperature")temps.push(parseInt(m[2],10)) }
  return {times:times, temperature:temps.length?temps[0]:null}
}


let fails = 0
const eq = (got, want, what) => {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (!ok) { fails++; console.log("FAIL", what, "got", JSON.stringify(got), "want", JSON.stringify(want)) }
  else console.log("ok  ", what)
}

console.log("--- time normalization ---")
eq(normalizeTime("7:5","20:00"), "07:05", "pads 7:5")
eq(normalizeTime("20:00","07:00"), "20:00", "keeps 20:00")
eq(normalizeTime("24:00","07:00"), "07:00", "rejects 24:00")
eq(normalizeTime("12:60","07:00"), "07:00", "rejects 12:60")
eq(normalizeTime("garbage","07:00"), "07:00", "rejects garbage")
eq(normalizeTime(null,"07:00"), "07:00", "rejects null")
eq(fromMinutes(toMinutes("20:00") + 15), "20:15", "step +15")
eq(fromMinutes(toMinutes("00:05") - 15), "23:50", "step wraps past midnight")

console.log("--- 20:00 -> 07:00 wrap-around ---")
const night = { start: "20:00", stop: "07:00" }
const at = (hhmm) => isActive(night, toMinutes(hhmm))
eq(at("19:59"), false, "19:59 off")
eq(at("20:00"), true,  "20:00 on")
eq(at("23:30"), true,  "23:30 on")
eq(at("00:00"), true,  "00:00 on (wraps midnight)")
eq(at("06:59"), true,  "06:59 on")
eq(at("07:00"), false, "07:00 off")
eq(at("12:00"), false, "12:00 off")

console.log("--- 08:00 -> 22:00 same-day ---")
const day = { start: "08:00", stop: "22:00" }
const atd = (hhmm) => isActive(day, toMinutes(hhmm))
eq(atd("07:59"), false, "07:59 off")
eq(atd("08:00"), true,  "08:00 on")
eq(atd("21:59"), true,  "21:59 on")
eq(atd("22:00"), false, "22:00 off")

console.log("--- degenerate ---")
eq(isActive({start:"09:00",stop:"09:00"}, toMinutes("09:00")), false, "zero-length window never active")
eq(minutesToNextBoundary({start:"09:00",stop:"09:00"}, 600), -1, "zero-length has no next boundary")

console.log("--- next boundary ---")
eq(minutesToNextBoundary(night, toMinutes("19:00")), 60,  "19:00 -> 60 min")
eq(minutesToNextBoundary(night, toMinutes("23:59")), 421, "23:59 -> 421 min (07:00 next day)")
eq(minutesToNextBoundary(night, toMinutes("20:00")), 660, "20:00 -> 660 min (07:00)")
eq(minutesToNextBoundary(night, toMinutes("06:59")), 1,   "06:59 -> 1 min")

console.log("--- conf rewriting ---")
// A stand-in for a conf the plugin has never touched. The tests are
// hermetic on purpose: the live file cannot be used here, because once the
// plugin is installed it is managed, and asserting on it would only
// prove the plugin had already run.
const stock = [
  "# Makes hyprsunset do nothing to the screen by default",
  "# Without this, the default applies some tint to the monitor",
  "",
  "# profile {",
  "#     time = 20:00",
  "#     temperature = 4000",
  "# }",
  ""
].join("\n")
const out = composeSchedule({start:"20:00",stop:"07:00",temperature:4000}, stock)
console.log(out)
console.log("--- stock comments preserved? ---")
eq(stock.includes("# Makes hyprsunset do nothing to the screen by default"), out.includes("# Makes hyprsunset do nothing to the screen by default"), "header comment kept")
eq(stock.includes("#     temperature = 4000"), out.includes("#     temperature = 4000"), "commented-out profile kept")
eq(/^profile \{/m.test(out), true, "exactly one uncommented profile pair written")
eq(stripProfiles(out).replace(/\s+$/,""), stock.replace(/\s+$/,""), "round trip leaves the stock file byte-identical")

console.log("--- idempotence ---")
const twice = composeSchedule({start:"20:00",stop:"07:00",temperature:4000}, out)
eq(twice, out, "second apply is a no-op")

console.log("--- round trip ---")
eq(parseManaged(out), {times:["20:00","07:00"], temperature:4000}, "parseManaged reads it back")
eq(parseManaged(stock), null, "parseManaged ignores unmanaged conf")

console.log("--- malformed input is refused, not eaten ---")
eq(stripProfiles("profile {\n  time = 20:00\n"), null, "unterminated block -> null")
eq(composeSchedule({}, "profile {\n  time = 20:00\n"), null, "compose refuses malformed file")

console.log(fails === 0 ? "\nALL PASS" : "\n" + fails + " FAILURES")
process.exit(fails === 0 ? 0 : 1)

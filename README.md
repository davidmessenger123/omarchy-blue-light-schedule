# davidjm.blue-light-schedule

Applies a blue light filter during a daily window **you** choose. Defaults to
**20:00 → 07:00 at 4000 K**, but the start time, stop time, temperature, and
whether it runs at all are all yours to set. A sun/moon glyph on the bar shows
whether the filter is on right now and when it changes next; left-click opens a
panel with 15-minute steppers for both times.

It is built as a **service** plus a thin **bar-widget**. One service owns the
schedule, every bar surface renders the same shared state.

## What you get

| Piece | File | Kind |
|---|---|---|
| Schedule engine (settings, hyprsunset profiles, live readout) | `Service.qml` | `service` |
| Bar glyph + schedule panel | `BarWidget.qml` | `bar-widget` |

The widget is **always visible**: it shows the moon and the next change when the
filter is off, the sun and the temperature when it is on, so you can tell at a
glance whether the schedule is actually doing anything.

## Requirements

- **Omarchy 4.x** with the stock shell bar.
- **Hyprland** with `hyprctl`, and the `hyprsunset` binary on `PATH`
  (`omarchy install` includes it; `hyprctl hyprland get version` must work).
- A private `XDG_RUNTIME_DIR` supplied by the desktop session.

No elevation, no daemon, no Python.

## Install

```bash
omarchy plugin add https://github.com/davidmessenger123/omarchy-blue-light-schedule --enable --yes
```

That clones the repo into `~/.config/omarchy/plugins/davidjm.blue-light-schedule`,
registers the **service**, and places the **widget** in the bar (right section
by default). Both are needed: the service is what owns the schedule, and the
layout entry is what puts the glyph on the bar (the widget finds the service via
`bar.shell.serviceFor("davidjm.blue-light-schedule")`).

Or install by hand:

```bash
mkdir -p ~/.config/omarchy/plugins/davidjm.blue-light-schedule
cp manifest.json BarWidget.qml Service.qml README.md LICENSE \
   ~/.config/omarchy/plugins/davidjm.blue-light-schedule/
omarchy-shell shell rescanPlugins
omarchy plugin enable davidjm.blue-light-schedule
```

To move the glyph: `omarchy bar move davidjm.blue-light-schedule --section left`
(or `center`/`right`).

To update later: `omarchy plugin update davidjm.blue-light-schedule`.

## Usage

**Left click** the bar glyph to open the schedule panel:

- **Follow a daily schedule** — master switch.
- **FILTER ON** / **FILTER OFF** — the window, stepped in 15 minutes. Stepping
  past midnight wraps, so an overnight filter is just a start time later than
  the stop time.
- **TEMPERATURE** — 3000–5500 K in the panel; any 1000–10000 K in the settings
  file.
- **Re-apply now** — pushes the schedule to hyprsunset immediately, instead of
  waiting for the next poll.

Everything saves as you change it.

## Configure

The plugin keeps its own settings file, and watches it — hand-editing works and
applies without a restart.

`~/.config/blue-light-schedule/settings.json`:

```json
{
  "version": 1,
  "enabled": true,
  "start": "20:00",
  "stop": "07:00",
  "temperature": 4000
}
```

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | `false` writes an identity profile, so nothing is ever tinted. |
| `start` | string | `"20:00"` | `HH:MM` the filter turns on. |
| `stop` | string | `"07:00"` | `HH:MM` the filter turns off. |
| `temperature` | number | `4000` | Kelvin, clamped to 1000–10000. Lower is warmer. |

The window is `[start, stop)`. When `start` is later than `stop` it wraps past
midnight, which is the normal evening case.

## How it works

The schedule is written into `~/.config/hypr/hyprsunset.conf` as a marked block:

```
# >>> davidjm.blue-light-schedule >>>
profile {
    time = 20:00
    temperature = 4000
}

profile {
    time = 07:00
    identity = true
}
# <<< davidjm.blue-light-schedule <<<
```

hyprsunset re-evaluates its profiles every minute on its own, so the filter
keeps working across shell restarts and while the shell is not running. A
`Timer` inside the shell would only be correct for as long as the shell happened
to be alive — which is why the timing lives in hyprsunset and the plugin is a
settings surface rather than a clock.

That means the plugin is mostly not in the path of the tint: it writes the
profiles, restarts hyprsunset, and reads the result back for the bar.

## Things worth knowing

**The plugin owns the profile set in `hyprsunset.conf`.** Any uncommented
`profile { }` block is removed before the managed block is written, because two
profiles disagreeing about the same minute is exactly the kind of thing that
silently does nothing. Commented-out profiles — including the ones Omarchy ships
— are left alone, and everything outside the block is preserved verbatim. Your
original file is copied once to
`hyprsunset.conf.bak.pre-blue-light-schedule` before the first write.

If that file ever has an unterminated `profile {` block, the plugin refuses to
write rather than truncating your config, and says so in the panel.

**hyprsunset is not kept alive by Omarchy.** It is not a systemd service and the
stock `hyprsunset.conf` does not launch it, so if it is not running the screen is
untinted no matter what the schedule says. The service notices within a minute,
restarts it, and reports in the panel rather than leaving you with a filter that
quietly is not there. Restarts are queued and bounded, so a hyprsunset that
refuses to start is retried a few times and then reported instead of respawned
forever.

**It does not fight `omarchy toggle nightlight`.** That command sets the
temperature directly; hyprsunset reasserts the scheduled profile at the next
boundary. If you use both, the schedule wins at each transition.

**`disable = true` in `hyprsunset.conf` turns hyprsunset itself off.** The panel
flags this rather than appearing to work.

## Tests

```bash
node tests/schedule.test.js   # schedule arithmetic, conf rewriting, idempotence
qmllint --bare Service.qml    # QML syntax
```

The suite covers the past-midnight wrap, time normalization, that the stock
`hyprsunset.conf` round-trips byte-identically outside the managed block, that
applying twice is a no-op, and that a malformed conf is refused rather than
eaten. CI runs both on every push.

## Remove

```bash
omarchy plugin remove davidjm.blue-light-schedule
```

The managed block is left in `~/.config/hypr/hyprsunset.conf` (delete it between
the markers to hand the file back), your settings stay in
`~/.config/blue-light-schedule/settings.json`, and the original conf is at
`hyprsunset.conf.bak.pre-blue-light-schedule`.

## License

MIT — see [`LICENSE`](LICENSE).
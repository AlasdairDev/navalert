---
name: hunt-navalert
description: Hunt for bugs in NavAlert on a real emulator by driving simulated GPS through whole commutes, then report findings bug-bounty style with severity, reproduction, root cause and a suggested fix. Use when asked to test, sweep, scan, QA, stress or find bugs in the app, or to verify a fix on a device rather than only in tests.
---

# Hunting bugs in NavAlert

`flutter test` proves the state machine. It does not prove the app. Every defect
found on the device in this project so far was invisible to a green suite:
buttons drawn behind the navigation bar, a map that fetched four times the tiles
it needed, a blank basemap offline, and an alarm that escalated correctly in the
model while the screen kept showing the previous stage.

That last one is the shape of the whole problem. The suite asserted `vm.phase`
and passed; the screen is driven by `notifyListeners()` and nothing asserted
that. **Hunt in the gap between what the tests assert and what the commuter
sees.**

---

## The one rule

**Rule out the environment before you file anything.**

Two "bugs" in the first sweep of this app were the hunter's own doing: an
onboarding screen that ignored every tap (the taps were landing 4 px outside the
button) and a fake call that launched by itself (a tap landed on a recording row
after a permission dialog dismissed underneath it). Both cost more time than the
checks would have.

Before writing a report, answer all four:

| Check | Command |
|---|---|
| Is the app actually foregrounded? | `adb shell dumpsys activity <pkg> \| grep -i resumed` |
| Is the screen on and unlocked? | `adb shell dumpsys window \| grep -iE 'mAwake\|isKeyguardShowing'` |
| Is the app busy or idle? | `adb shell top -n 1 -b \| grep navalert` |
| Did the tap land where you think? | screenshot **after** the tap and look |

A frozen-looking UI at 0 % CPU with the app resumed is a real finding. The same
thing with the screen asleep is your own fault.

---

## Setup

```bash
.claude/skills/hunt-navalert/prep-device.sh          # build, boot, install, grant, stay awake
.claude/skills/hunt-navalert/prep-device.sh --no-build   # reuse the APK on disk
adb shell am start -n ph.edu.pup.navalert/.MainActivity
```

Build with the emulator **down**. On an 8 GB machine Gradle and qemu together
livelock the kernel — the only swap is zram, so there is no real overflow to
spill into. `prep-device.sh` sequences this for you and stops the Gradle daemon
before booting.

It builds **debug** on purpose: `debugPrint` reaches logcat, and NavAlert reports
its own failures there (`NavAlert: leg geometry unavailable — ...`). Release
strips them and the hunt goes blind.

---

## Driving GPS

```bash
G=.claude/skills/hunt-navalert/gps.sh

$G find "CUBAO"                                  # search the bundled feed
$G stops "MURPHY 15TH AVE - STOP N SHOP"         # inspect a route's stops
$G fix 14.6200 121.0530                          # one position
$G drive 14.6214,121.05 14.6182,121.042          # a trace
$G route "MURPHY 15TH AVE - STOP N SHOP" 2 16    # drive stops 2..16 of a real route
DWELL=6 $G route "CUBAO DIVISORIA"               # slower, for watching a screen
```

**All coordinates are `lat lng`.** `adb emu geo fix` takes longitude first;
`gps.sh` flips it at the boundary so you never have to think about it. Passing
them raw puts the rider in the Pacific with no error — the map simply renders
nothing, which reads as a broken app.

**Trace from the feed, not from imagination.** The app matches routes by
proximity to stops (800 m), advances guide steps by proximity to a leg end
(100 m walking / 150 m riding), and draws geometry OSRM built through those same
stops. A hand-invented trace misses all three and produces symptoms that look
exactly like app bugs: no route match, a step that never advances, a line beside
the road. `gps.sh route` reads the real thing out of `assets/gtfs/routes.json.gz`.

---

## Navigating the UI

**Screenshot, read, then tap. Never replay coordinates from an earlier run.**

```bash
S=.claude/skills/hunt-navalert/shot.sh
HUNT_DIR=/tmp/hunt-$(date +%H%M) "$S" home
adb shell input tap 540 2168
"$S" after-tap
```

Button positions move. One padding change in this app relocated every primary
button by about 126 px, and every stale coordinate then landed on the navigation
bar instead. Traps that have already cost time here:

- **The bottom ~130 px belong to the system bar** on an edge-to-edge screen. A
  tap on a *visible* button label can still go to the navigation bar. If a tap
  seems to do nothing near the bottom, that is the first suspect — and it is
  also a genuine bug class worth reporting (it was, three times).
- **`KEYCODE_BACK` on a top-level screen exits the app.** The next taps then hit
  the launcher, and a long press opens Assistant.
- **A dialog dismissing puts your next tap on whatever was underneath.**

---

## What to sweep

Screens: Home · search · pin-on-map · route suggestions · commute guide · trip
settings · monitoring (alarm on **and** off) · live map · Alarm Stages 1/2/3 ·
overshoot prompt and confirmation · arrival · History · Favorites · Add Favorite
· Emergency · Settings and every sub-page · fake call.

Conditions that have each produced a real bug here:

- **Offline.** `adb shell cmd connectivity airplane-mode enable`. Plan online
  first, then go offline before *Start Trip* — that is the commute the app is
  built for and the least-tested path.
- **GPS stopped.** Deliver one fix and then none. Timer-driven behaviour is
  invisible while a live stream keeps rebuilding the screen; this is exactly how
  the escalation bug hid.
- **Empty state.** No contacts, no favourites, no history. SOS with no contacts
  must fail *loudly*, never pretend to send.
- **Fresh install.** `adb uninstall` then reinstall, and walk onboarding.
- **A short screen.** Layouts here are budgeted in dp and overflow at the bottom.

---

## Verifying, before you claim anything

**Measure. Do not reason about performance.** The obvious cause is often
inverted: the tile server everyone suspected answered in 35 ms, while the
"faster" alternative took 550 ms, and the real cost was a retina flag fetching
4× the tiles. One `curl` loop settled what an afternoon of argument would not.

Useful observations that do not need the UI:

```bash
# what the app cached, and at which zooms — proves offline behaviour
adb shell run-as ph.edu.pup.navalert find . | grep '\.tile$' | wc -l
# the app's own reports
adb logcat -d -t 300 | grep -i "NavAlert:"
```

**A regression test must be proven to fail without the fix.** Disable the fix,
watch the test go red, restore it, watch it go green. In this project two
attempts at that "passed" only because the disabling script silently failed to
match — always assert the edit applied, and never print success unconditionally.

---

## The report

One block per finding, most severe first. Severity is about the commuter, not
the code.

- **Critical** — the alarm can fail to wake someone, or SOS can silently not send
- **High** — a primary action is unreachable, or the app states something false
- **Medium** — a feature degrades where it is most needed (offline, no signal)
- **Low** — cosmetic, copy, inconsistency

```
### [Severity] One-line symptom

Repro
  1. exact steps, with the GPS coordinates used
  2. ...
Expected   what the requirement or mockup says
Actual     what the device did
Evidence   /tmp/hunt-1430/07_stage1.png
Root cause file.dart:123 — the mechanism, not the guess
Fix        the change, and why that one
Test gap   what the suite asserted instead, and the assertion that closes it
```

**Report what you ruled out too.** "SOS with no contacts fails loudly — correct,
not a bug" and "the fake call was my own stray tap" are worth a line each: they
stop the next hunter re-investigating them.

Then say plainly what you did **not** cover. A sweep that claims everything is
fine is less useful than one that names its blind spots.

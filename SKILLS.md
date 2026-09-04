# NavAlert — Embedded Skills

Three skills live in this repository under `.claude/skills/`. They are
**committed with the code**, so they arrive with a clone: nothing to install,
nothing to copy into `~/.claude/`. Open the repository root in Claude Code and
they are there.

They exist because the same problems kept costing the same afternoons. A
groupmate re-cloning on a different laptop hit the toolchain wall; the emulator
crashed on one machine and not another; a bug sweep missed the screen where the
real defect was. Each skill is the written-down version of solving one of those
once.

| Skill | Use it when |
|---|---|
| **`/setup-navalert`** | a machine cannot build or run the project |
| **`/run-navalert`** | you want the app running on an emulator or handset |
| **`/hunt-navalert`** | you want it tested or swept on the **emulator** |

> **They are ordinary scripts too.** Every helper below runs from a plain shell
> without Claude Code. The skill is the method; the scripts are the hands.

---

## `/setup-navalert` — get a machine building

Covers **Windows, macOS and Aurora DX / Fedora Atomic**. Checks Flutter, the
Android SDK, the emulator, a JDK, CMake, the NDK and KVM access, then names what
is missing and the exact command to fix it.

```bash
.claude/skills/setup-navalert/doctor.sh                    # macOS / Linux
powershell -File .claude\skills\setup-navalert\doctor.ps1  # Windows
.claude/skills/setup-navalert/install-aurora.sh            # Fedora Atomic
```

Exit code 0 means the machine is ready.

**On Fedora Atomic, do not `rpm-ostree install` the toolchain.** `/usr` is
read-only there and layering slows every later image update. Nothing NavAlert
needs has to live outside `$HOME`, which is what `install-aurora.sh` does.

The doctor is written to survive the machines it runs on, not just this one:
macOS ships bash 3.2, where reading an empty array under `set -u` aborts the
script, so it counts with a plain integer instead. It reports AVDs by **name**
rather than by count, because a wrong name is the failure that follows.

---

## `/run-navalert` — get the app on screen

Three platforms, three launch paths; what differs is the renderer and the window
manager, not the app.

```bash
.claude/skills/run-navalert/boot-emulator.sh          # picks a usable AVD
.claude/skills/run-navalert/boot-emulator.sh <name>   # or name one
```

Idempotent, waits for boot, and **fails loudly if qemu dies** instead of hanging.

Three things it handles that cost real time to learn:

- **`-gpu host` is mandatory on this Linux laptop.** Any software renderer
  SIGSEGVs about twenty seconds into boot inside SwiftShader's GL JIT.
- **The AVD name is validated before launch.** A wrong one exits qemu instantly
  while `adb wait-for-device` blocks forever — which looks like a slow boot for
  seven minutes.
- **The emulator gets its own systemd scope, memory-capped.** Started from a
  terminal inside VS Code it otherwise lands in the editor's cgroup, and a
  global OOM kills qemu *and tears down the whole scope*, taking the editor and
  every unsaved buffer with it. That happened before this existed.

The remaining scripts are KDE window-management conveniences — floating the
emulator, hiding its side toolbar, snapping it to a size.

---

## `/hunt-navalert` — find bugs on the emulator

**Emulator only.** GPS is driven through `adb emu geo fix`, an emulator-console
command physical handsets do not have, and every script refuses a non-`emulator-*`
serial. Real hardware is still required for SMS delivery, volume-key shortcuts
and audio routing — that is SETUP.md §4.1–4.5, and simulated GPS is no substitute.

`flutter test` proves the state machine. It does not prove the app.

Every defect found on the device in this project was invisible to a green suite:
buttons drawn behind the navigation bar, a map fetching four times the tiles it
needed, a blank basemap offline, and an alarm that escalated correctly in the
model while the screen kept showing the previous stage. **That last one is the
shape of the whole problem** — the suite asserted `vm.phase` and passed; the
screen is driven by `notifyListeners()` and nothing asserted that.

```bash
H=.claude/skills/hunt-navalert

$H/hunt.sh                        # prepare, launch, capture every screen
```

That one command is the whole start of a hunt. The pieces, for when you want
them individually:

| Helper | Does |
|---|---|
| `prep-device.sh` | build only if the APK is stale, boot, install, grant, launch |
| `sweep-ui.sh` | capture every top-level screen, so none is skipped |
| `tap.sh "Start Trip"` | tap by **label**, never by coordinate |
| `gps.sh route "..."` | drive a real route from the bundled feed |
| `check-env.sh` | rule out the environment before filing anything |
| `net.sh off\|on` | go offline, and verify it actually is |
| `logs.sh` | the app's own reports, crashes, and whether it is still alive |
| `shot.sh label` | numbered screenshot into the hunt folder |

```bash
$H/tap.sh --list                  # every label on screen right now
$H/tap.sh "Show Commute Guide"    # tap it
$H/gps.sh find "CUBAO"            # search the bundled feed
$H/gps.sh route "MURPHY 15TH AVE - STOP N SHOP" 2 16
$H/net.sh off                     # offline, confirmed by a ping
$H/logs.sh                        # did anything crash?
```

### Why the helpers are shaped the way they are

**`gps.sh` takes `lat lng`.** `adb emu geo fix` takes longitude *first*, while
every coordinate in this codebase, in the GTFS feed and in a human's head is
lat,lng. Passing them raw puts the rider in the Pacific with **no error** — the
map simply renders nothing, which reads as a broken app rather than a swapped
argument. The flip happens once, at the boundary.

**Traces come from `assets/gtfs/routes.json.gz`, not from imagination.** The app
matches routes within 800 m of a stop, advances guide steps within 100 m
(walking) or 150 m (riding) of a leg end, and draws geometry OSRM built through
those same stops. An invented trace misses all three and produces symptoms
indistinguishable from real bugs.

**`prep-device.sh` builds with the emulator down.** On an 8 GB machine whose
only swap is zram there is no real overflow, so Gradle and qemu together
livelock the kernel rather than OOM-killing anything. It also forces stay-awake:
a sleeping screen pauses the Flutter engine, and a stopped timer looks exactly
like an alarm refusing to escalate.

**`sweep-ui.sh` computes tab positions from `wm size`.** A hardcoded y from
another panel lands on the navigation bar and silently does nothing — the same
trap that makes real taps vanish.

**`tap.sh` finds controls by label, because coordinates were the largest source
of waste.** Flutter exposes its semantics to uiautomator as `content-desc`, so a
control can be resolved to real bounds and tapped at its true centre. An
ambiguous match taps nothing and lists the candidates; guessing between them is
the failure it replaces. It wakes the screen first — uiautomator on a sleeping
one fails with "null root node returned by UiTestAutomationBridge", which names
neither cause nor fix.

**`logs.sh` catches what a screenshot cannot.** A Flutter crash leaves the last
frame on screen, so a sweep can photograph a folder of healthy-looking pages
belonging to a dead process.

### The rule it leads with

**Rule out the environment before filing anything.** Two "bugs" in the first
sweep of this app were the hunter's own doing: taps landing a few pixels outside
a button, and a fake call that launched because a tap hit a recording row after
a dialog dismissed underneath it. Both cost more time than the checks would have.

It also requires that a regression test be **proven to fail without its fix** —
disable the fix, watch it go red, restore it, watch it go green. Two attempts at
that here "passed" only because the disabling script silently failed to match.

Findings come out with severity judged by commuter impact (**Critical** = the
alarm can fail to wake someone), reproduction including the GPS coordinates
used, evidence, root cause at `file:line`, a suggested fix, and the **test gap**
— what the suite asserted instead.

---

## Adding to them

Keep helpers executable and LF-terminated. `.gitattributes` normalises line
endings, but the mode bit is separate:

```bash
git update-index --chmod=+x .claude/skills/<skill>/<script>.sh
```

A shell script committed 100644 arrives unrunnable on a groupmate's clone, and a
CRLF one fails with `bad interpreter` — both have happened here.

Write down *why*, not just *what*. Every "DO NOT MODIFY LOGIC" note in these
scripts marks a failure someone already paid for.

# AGENTS.md

Orientation for AI coding agents (and humans) working on this repository.

## What this is

Battery charge-limit control for Apple Silicon MacBooks running Linux
(Asahi-based kernels, e.g. Omarchy's `linux-aurora`), in two halves:

1. **`battctl/`** - a C11 CLI (`battctl.c`, no dependencies) that writes the
   SMC firmware charge limit through the `macsmc` driver's sysfs attribute
   `charge_control_end_threshold`, plus the plumbing to keep that setting
   applied: a systemd oneshot service (boot), a systemd-sleep hook
   (suspend/resume), a udev rule (AC plug events), a boot-persisted config in
   `/etc/battctl.conf`, and a polkit rule so `wheel` can run the binary via
   `pkexec` without a prompt.
2. **The repository root** - an Omarchy Quickshell plugin
   (`manifest.json`, `BarWidget.qml`, `Panel.qml`, `Model.js`) with the
   permanent id `io.github.geoochi.mac-battctl`. The bar shows percentage +
   state; the panel shows live battery facts and a charge-limit stepper that
   shells out to `pkexec /usr/local/bin/battctl set N`.

The repo root *is* the plugin root (the marketplace requires `manifest.json`
at the repository root). Extra files next to it are intentional; do not
"clean them up" into a subdirectory - only the C tool may live in `battctl/`.

## Domain facts (verified on hardware)

- The kernel driver exposes `charge_control_end_threshold` (writeable, root
  only). Writing it programs the SMC firmware; the firmware then enforces the
  limit by itself, including across `s2idle` suspend, so lid-closed behaviour
  needs no userspace daemon. `charge_control_start_threshold` is read-only in
  effect: the driver ignores writes and reports `end - 5`.
- Two firmware generations exist. **CHLS** (older): end threshold 10-99,
  recharge point fixed at `end - 5`, and the driver always sets a
  force-discharge bit, so a lowered limit makes the battery drain to it even
  on AC. **CHWA** (modern): a single flag; values <= 95 mean "fixed 80%",
  >= 96 mean "100% (off)". The mode must be probed with a real write
  (`battctl detect` writes 90 and reads back: 90 => CHLS, 80 => CHWA).
- UPower's `ChargeStartThreshold`/`ChargeEndThreshold` are **not** the
  firmware values on Apple Silicon - UPower 1.91 ships an hwdb catch-all
  `battery:*:*:dmi:* CHARGE_LIMIT=75,80`. That is why both the CLI and the
  widget read sysfs and `/etc/battctl.conf` directly, and why the widget must
  never use UPower for limit display.
- The percentage read-outs also come from sysfs `capacity` (the firmware's SMC
  BUIC value, the same number macOS and btop show), not UPower's `percentage`:
  UPower recomputes that from `charge_now/charge_full` and disagrees with the
  firmware by several points. The charge limit is enforced against BUIC, so
  every read-out follows it. UPower remains the source for state, rate, time,
  cycles and health.
- `asahi-scripts` ships its own udev/systemd units that persist
  `charge_control_end_threshold` (see `/usr/lib/udev/rules.d/93-macsmc-*`).
  They coexist with battctl; never edit files under `/usr/lib` for this.
- Only one IpcHandler may own an IPC target. The plugin owns
  `io.github.geoochi.mac-battctl`; the stock Omarchy power widget keeps
  `omarchy.power`. Do not reuse `omarchy.*` ids (the validator rejects them).

## Repository layout

```
manifest.json        plugin manifest (root = plugin root, required for publishing)
BarWidget.qml        bar entry: button + panel Loader + IPC + settings toggle
Panel.qml            details panel: stats, charge-limit stepper
Model.js             pure logic (state machine, parsers, formatting) - node-testable
battctl/             the C backend and its installer
  battctl.c          CLI: status | set N | off | apply | detect
  Makefile           `make` builds ./battctl (gitignored)
  install.sh         install/uninstall/status; needs root
  battctl.service    boot: `battctl apply`
  99-battctl         systemd-sleep hook: apply before/after suspend
  99-battctl-power.rules  udev: apply when AC goes online
  49-battctl.rules   polkit: passwordless `pkexec battctl` for wheel
```

## Build, test, validate

```sh
# C side
cd battctl && make                      # -O2 -Wall -Wextra, must be warning-free
./battctl status                        # read-only, no root needed
unshare -r ./battctl detect             # exercise root-only paths in a user namespace

# Pure logic (state machine, config parsing)
node -e 'const M=require("./Model.js"); console.log(M.describe({
  present:true, percentage:48, state:"pending", onBattery:false,
  limitStart:45, limitEnd:50, phraseIndex:0}))'

# Plugin contract (run from the repo root)
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml
```

Root-only behaviour (`set`, `apply`, `detect` against the real sysfs) cannot
be tested without privileges; use `pkexec battctl ...` once the polkit rule is
installed, or ask the user to run it.

### Sandbox-testing the QML without touching the live shell

The widget can be loaded in a throwaway Quickshell instance with a fake bar,
which catches QML errors before they reach the running shell:

```sh
mkdir -p /tmp/qstest && cd /tmp/qstest
ln -sfn "$OMARCHY_PATH/shell/Ui" Ui
ln -sfn "$OMARCHY_PATH/shell/Commons" Commons
ln -sfn /path/to/this/repo plugin
# shell.qml: ShellRoot { ... Loader.setSource("plugin/BarWidget.qml",
#   { bar: fakeBar, moduleName: "io.github.geoochi.mac-battctl", settings: {} }) ... }
# fakeBar needs: foreground/background/urgent/barForeground colors,
# fontFamily, barSize, vertical, position, shell, run(), shellQuote(),
# showTooltip()/hideTooltip(), requestPopout()/releasePopout(),
# foregroundAnimationEnabled
OMARCHY_PATH=/usr/share/omarchy timeout 20 quickshell -p /tmp/qstest 2>&1 | head -60
```

Load errors, missing properties and binding loops all surface here. A warning
about `foregroundAnimationEnabled` usually means the fake bar is incomplete,
not that the widget is broken.

## Live shell debugging

- The running shell logs to `/run/user/1000/quickshell/by-id/<id>/log.qslog`
  (protobuf-ish; use `strings` and grep). Find the live instance via
  `ls -l /proc/$(pgrep -x quickshell | head -1)/fd | grep qslog`.
- QML edits do **not** hot-reload: Omarchy launches the shell with
  `QS_DISABLE_FILE_WATCHER=1`, so the Quickshell engine keeps its cached
  components and neither `rescanPlugins` nor a plugin disable/enable picks up
  new code. Apply plugin changes with `omarchy-restart-shell` (deliberate
  restart; the bar blinks for about a second).
- `omarchy plugin list --json | jq '.[] | select(.id=="io.github.geoochi.mac-battctl")'`
- Installed plugin directory: `~/.config/omarchy/plugins/io.github.geoochi.mac-battctl/`
  (a git checkout managed by `omarchy plugin add/update`; after pushing plugin
  changes, `omarchy plugin update io.github.geoochi.mac-battctl --yes` then
  `omarchy-restart-shell`).

## Commit conventions

Every commit that changes this repository carries a co-author trailer for the
AI agent that worked on it:

```
Co-Authored-By: CodeBuddy Code <codebuddy@example.com>
```

Use `git commit -m "<subject>" -m "Co-Authored-By: CodeBuddy Code <codebuddy@example.com>"`.
A reserved example.com address is intentional: a `users.noreply.github.com`
address would be linked to the real GitHub account that owns that username.
Never amend or force-push published history to add a missed trailer; the
marketplace binds its validation and security baseline to exact commit SHAs.

## Gotchas

- `battctl set` writes sysfs **and** `/etc/battctl.conf`; keep them in sync
  or `battctl apply` will fight the manual value on the next boot/resume.
- The widget's stepper steps by 5% and clamps to 10-100; `100` means "off".
- `pkexec` runs as root and needs the polkit rule installed; the widget shows
  pkexec's stderr verbatim when authorization or the binary is missing, so
  error text quality matters.
- The charge-limit path (`/usr/local/bin/battctl`) and the polkit rule's
  `program` value must stay in sync; both are hardcoded in `Panel.qml` and
  `battctl/49-battctl.rules`.
- Keep `moduleName` identical in `BarWidget.qml` and `Panel.qml` (the bar
  registry looks up settings by it), and keep the plugin folder free of
  symlinks (the validator rejects them).
- No Rust/Go toolchain is assumed: the backend is C11 + make, the plugin is
  QML for Qt 6 / Quickshell.
- If the plugin id ever changes, the `shell.json` bar layout entry must be
  updated too (`omarchy plugin enable <id>` handles the swap for clones, but a
  standalone plugin is placed by id).

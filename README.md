# Mac Battery Limit (battctl)

Keep an Apple Silicon MacBook at a chosen charge level under Linux, and see
what the firmware is actually doing in your Omarchy bar.

Two pieces that work together:

| Piece | What it is |
|---|---|
| `battctl/` | A small C CLI plus systemd/udev/sleep-hook integration that programs the SMC firmware charge limit through the `macsmc` sysfs driver. |
| this repo root | An Omarchy (Quickshell) bar widget, `io.github.geoochi.mac-battctl`, that shows the real battery state and changes the limit with a stepper. |

Because the limit lives in the SMC firmware, it keeps holding while the lid is
closed and the machine is suspended - no daemon required.

## Requirements

- Apple Silicon MacBook running Linux with the `macsmc` power supply driver
  (Asahi Linux kernels, including Omarchy's `linux-aurora`)
- `gcc` + `make` for `battctl`
- Omarchy (Quickshell shell) for the bar widget
- Root access for the initial install (systemd unit, udev rule, sleep hook,
  polkit rule)

## Install

### 1. battctl (the backend)

```sh
git clone https://github.com/geoochi/omarchy-mac-battctl.git
cd omarchy-mac-battctl/battctl
sudo ./install.sh --limit 80
```

The installer builds the binary, installs `/usr/local/bin/battctl`, seeds
`/etc/battctl.conf`, enables the boot service, the suspend/resume hook and the
AC-plug udev rule, and installs the polkit rule that lets the `wheel` group run
`battctl` through `pkexec` without an authentication prompt (that is how the
widget changes the limit).

### 2. The bar widget

```sh
omarchy plugin add https://github.com/geoochi/omarchy-mac-battctl.git --enable
```

## Usage

```sh
battctl status      # battery, firmware mode, real thresholds
sudo battctl set 60 # set the limit (10-100, 100 = off)
sudo battctl off    # charge to 100%
sudo battctl detect # probe which firmware limit mode this machine has
sudo battctl apply  # (re)apply the limit from /etc/battctl.conf
```

Or click the battery in the bar and use the **CHARGE LIMIT** stepper.

**Bar interactions**

- left click: open the details panel
- right click: toggle the percentage label
- panel: live state, capacity, cycles, health, rate, temperature, the limit
  the firmware is holding, the limit stepper, and power profiles

## Firmware modes

The `macsmc` driver exposes two generations of charge-limit support:

- **CHLS** (older firmware): any limit from 10-99%, recharge point fixed at
  limit - 5. Setting a limit makes the firmware discharge the battery down to
  it, even while plugged in.
- **CHWA** (modern firmware): two states only, 80% (the macOS "80% limit") or
  100% (off).

`battctl detect` reports which one your machine has. The widget reads the
result from `/etc/battctl.conf` and labels the state accordingly.

## Uninstall

```sh
omarchy plugin remove io.github.geoochi.mac-battctl
cd omarchy-mac-battctl/battctl && sudo ./install.sh uninstall
```

## Notes

- UPower reports charge thresholds from its own hwdb default (75-80%) on
  Apple Silicon rather than the real firmware values, so both `battctl status`
  and the widget read sysfs directly.
- The Asahi `asahi-scripts` package ships its own persistence helpers for
  `charge_control_end_threshold`. They coexist with `battctl`; nothing in
  `/usr/lib` needs to be edited.

## License

MIT - see [LICENSE](LICENSE). The bar widget is derived from Omarchy's
built-in power widget (Copyright (c) David Heinemeier Hansson).

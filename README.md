# WhipIt 💥

Created in 10 mins with claude code. Build, run locally and whip it!

## How it works

Every Apple Silicon MacBook has an undocumented MEMS accelerometer (Bosch BMI286)
on the sensor processing unit, exposed as an `AppleSPUHIDDevice` over IOKit HID.
WhipIt reads it, removes gravity, and fires when the impact magnitude crosses a
threshold.

Because the sensor needs **root** but audio/UI need your **login session**, it's
two pieces talking over Darwin notifications:

- **`whipd`** — root `LaunchDaemon`: reads the sensor, broadcasts a "slap"
  notification with the impact strength. No audio, no UI.
- **`WhipIt.app`** — menu-bar 💥 in your user session: plays `whip.mp3`, with an
  Enable toggle and a Sensitivity slider.

## Build & install

```sh
./build.sh          # compiles whipd + WhipIt.app, generates the icon, signs both
open WhipIt.app     # 💥 appears in the menu bar
```

Install the background service (one admin-password prompt), either from the
menu-bar **💥 → Install Background Service…**, or directly:

```sh
sudo sh WhipIt.app/Contents/Resources/install-daemon.sh "$PWD/WhipIt.app"
```

Then slap your Mac. Tune with the **Sensitivity** slider; **Uninstall Background
Service…** removes the daemon. Daemon logs: `/var/log/whipd.log`.
Debugging: `tail -f /var/log/whipd.log`

## Sensor notes (the non-obvious bits)

Reverse-engineered specifics that make this work:

- Device: `AppleSPUHIDDevice`, `PrimaryUsagePage 0xFF00`, `PrimaryUsage 3`
  (accelerometer; usage `9` is the gyro). 22-byte input reports.
- Report layout: X/Y/Z = `int32` little-endian at byte offsets **6 / 10 / 14**,
  value **÷ 65536** = g.
- **The sensor is powered down by default.** It only starts streaming after you
  set `SensorPropertyPowerState`, `SensorPropertyReportingState`, and
  `ReportInterval` (µs) on the **`AppleSPUHIDDriver`** service via
  `IORegistryEntrySetCFProperty` — *not* on the device.
- Reports are delivered **only** through
  `IOHIDDeviceRegisterInputReportWithTimeStampCallback` (the plain callback never
  fires). `IOHIDManager` matching also won't stream — open the device directly via
  `IOServiceGetMatchingServices` → `IOHIDDeviceCreate` → `IOHIDDeviceOpen` →
  schedule on the run loop.
- Requires **root**.

## Files

| file | role |
|------|------|
| `whipd.swift` | root daemon: sensor → Darwin notification |
| `app/main.swift` | menu-bar GUI: notification → sound + UI |
| `app/Info.plist` | app bundle metadata (`LSUIElement` = menu-bar only) |
| `com.jinnosuke.whip.plist` | LaunchDaemon definition |
| `install-daemon.sh` | privileged installer (run by the app or by hand) |
| `notify-bridge.h` | exposes `<notify.h>` (Darwin notifications) to Swift |
| `make-icon.swift` | renders the 💥 app icon |
| `build.sh` | builds + assembles + signs everything |
| `whip.swift` | optional standalone CLI — `sudo ./whip --verbose` to watch live g-values for calibration |
| `whip.mp3` | random sound I found on the inter webs

## Notes

- Detection is a gravity-removed threshold + cooldown. Good enough that one slap =
  one sound; can be upgraded to STA/LTA / CUSUM voting if bumps false-trigger.
- For local use the ad-hoc build is enough; distributing to others would need a
  paid Developer account to notarize.

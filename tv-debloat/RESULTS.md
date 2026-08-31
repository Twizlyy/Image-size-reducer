# Results

TCL Smart TV Pro, firmware V8-R51MT05-LF1V652.021344, Android 11 (API 30).
ADB over Ethernet, 192.168.1.29:5555. Completed 31 August 2026.

## 1. Before / after

| Measurement | before | after (settled) | change |
|---|---|---|---|
| Total RAM | 2048 MB | 2048 MB | — |
| **Used RAM** | **1101 MB** | **958 MB** | **-143 MB (-13%)** |
| Free RAM | 520 MB | 404 MB | -116 MB (see below) |
| Enabled packages | 144 | 107 | -37 |
| Disabled packages | 2 | 40 | +38 |

Package counts reconcile: 146 packages before (144 + 2), 147 after (107 + 40).
The extra one is FLauncher, installed during the work.

### How to read these numbers

**Used RAM is the figure that means something**, and it fell by 143 MB.

**Free RAM went down, which is not a regression.** In `dumpsys meminfo`, "Free
RAM" counts cached processes and cached kernel pages, not just unallocated
memory. Fewer background services means fewer cached processes, so the number
shrinks while the machine is in better shape. Android also deliberately fills
unused RAM with cache; a large "Free RAM" is not a goal.

**The comparison is not perfectly clean.** The "before" snapshot was taken on a
TV that had been running for some time; the "after" came after a reboot, and a
reboot alone frees memory. Some part of the 143 MB is the reboot, not the
debloat. The honest claim is "an improvement of up to 143 MB", not exactly that
much.

The real win is not in this table. It is the ad and recommendation rows, the
Alexa and assistant services, and TCL's telemetry uploads, none of which show
up cleanly in a memory total.

## 2. What was disabled

38 packages, in five tested batches. Full record with timestamps in
`kapatilanlar.txt`. Nothing was uninstalled; every change reverses with
`pm enable`.

| Batch | Theme | Count |
|---|---|---|
| 1 | Ads and telemetry | 10 |
| 2 | Voice assistants, screensavers, unused accessibility | 10 |
| 3 | Setup wizards and TCL promo leftovers | 10 |
| 4 | Owner's explicit choices | 7 |
| 5 | Google TV launcher, after FLauncher was confirmed working | 1 |

The home screen was later switched again from FLauncher to Projectivy
Launcher (`com.spocky.projengmenu`). Both are protected in `keep-list.txt`;
the Google TV launcher remains disabled throughout.

### If you install another launcher

Installing a new HOME app clears Android's preferred-home setting. With the
Google TV launcher disabled, HOME then falls back to
`com.android.tv.settings/.system.FallbackHome` - a bare screen that works but
is not a launcher. This happened when Projectivy was installed.

It is not a fault and needs no recovery, just a new default:

```
.\Tv-Debloat.ps1 list-home                              # confirm the package name
.\Tv-Debloat.ps1 set-home -Packages <new launcher>
.\Tv-Debloat.ps1 reboot
```

Check `list-home` after installing any launcher - "Currently active" tells you
whether a preference is set or the TV has quietly dropped to FallbackHome.

This is also why `com.android.tv.settings` is on the keep-list. With the stock
launcher disabled, FallbackHome is the last thing between a cleared preference
and a black screen, and it lives inside the Settings package.

Kept deliberately: the Inputs/Source quick panel, HDMI and tuner services, the
remote control stack, Play Services and Store, fused location, every IME,
Android TV Settings (which also provides FallbackHome), Netflix, YouTube, all
streaming apps in use, the Chromecast receiver, and TCL's firmware updater.

Three opaquely-named packages were initially left alone: `com.tcl.guard`,
`com.tcl.t_solo`, `com.tcl.dashboard`. They were later disabled at the owner's
request, which broke the Netflix hotkey on the remote. Bisecting identified
**`com.tcl.dashboard`** as the cause - despite the name, it is part of the
branded-hotkey path (Netflix/YouTube/Prime buttons), and the `com.tcl.*key*`
keep-list rule does not cover it because `keyhelp` is a separate package.

`com.tcl.dashboard` is now keep-listed. This is undocumented behaviour and is
the main thing worth carrying forward from this exercise.

## 3. Undoing it

```
.\Tv-Debloat.ps1 undo-all
```

Or the single command in `UNDO-EVERYTHING.txt`, produced by
`.\Tv-Debloat.ps1 undo-command`.

Neither restores the Google TV launcher as the *home screen* - re-enabling the
package is not the same as making it default. To go fully back to stock:

```
adb shell cmd package set-home-activity com.google.android.apps.tv.launcherx/.home.HomeActivity
```

Then reboot.

## Note for the future

Firmware updates were deliberately left enabled, for security patches. A major
TCL update can re-enable packages or reintroduce ad features. If the ad rows
come back, re-run `triage` and compare against `kapatilanlar.txt`.

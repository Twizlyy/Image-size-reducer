# Debloat log

TV: TCL, firmware V8-R51MT05-LF1V652.021344
Connection: ADB over Ethernet, 192.168.1.29:5555

`Tv-Debloat.ps1` appends a timestamped entry here every time it changes
something, so this file is the narrative record and `kapatilanlar.txt` is the
machine-readable one. Do not hand-edit `kapatilanlar.txt` — `undo-last` and
`undo-all` read it.

## Ground rules this follows

* Nothing is ever uninstalled. Only `pm disable-user --user 0`.
  Every change reverses with `pm enable <package>`.
* No rooting, no bootloader unlocking, no custom ROM. A TCL Google TV that
  loses its Widevine L1 certificate drops Netflix to SD permanently, and it
  cannot be put back.
* Maximum 10 packages per batch, then stop and test.
* `keep-list.txt` is checked before every disable. A match aborts the whole
  batch — not just the offending package.

## Recovering a TV that will not boot to a usable screen

The connection is Ethernet and ADB survives a reboot, so the TV stays
reachable even with a black screen:

```powershell
.\Tv-Debloat.ps1 connect -Ip 192.168.1.29
.\Tv-Debloat.ps1 undo-last
.\Tv-Debloat.ps1 reboot
```

If ADB itself is gone, hold the remote's power button for ~10 seconds to force
a restart. Last resort is a factory reset from the TV's recovery menu, which
loses settings and apps but not the Widevine certificate.

---

<!-- Entries are appended below this line by the script. -->

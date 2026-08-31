# TV debloat toolkit

Reversible cleanup for a TCL Google TV over ADB, driven from Windows.

## Read this first

The assistant that wrote this runs in a cloud container. Your TV is on your
home LAN. There is no network path between the two, so **you** run these
commands and paste the output back. That is the only reason this is a script
instead of somebody typing `adb` for you.

Your setup, already confirmed working:

* TV at **192.168.1.29**, port 5555 open (`TcpTestSucceeded : True`)
* PC at 192.168.1.15, both wired
* You do **not** need "Wireless debugging". Google TV omits it. The TV uses the
  older ADB-over-TCP listener on 5555, which your existing "USB debugging"
  toggle already opened.

## Quick start

```powershell
cd path\to\tv-debloat

.\Tv-Debloat.ps1 setup                      # downloads adb into this folder
.\Tv-Debloat.ps1 connect -Ip 192.168.1.29   # WATCH THE TV, approve the dialog
.\Tv-Debloat.ps1 measure -Label before      # the "before" numbers
.\Tv-Debloat.ps1 triage                     # writes triage.md - send me this
```

Then send me `triage.md` and I pick the batches. Nothing gets disabled until
you have seen the list and approved it.

If PowerShell refuses to run the script:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

That lasts for the current window only and changes nothing permanently.

## Commands

| Command | What it does |
|---|---|
| `setup` | Downloads Google's platform-tools into this folder. Nothing touches your PATH. |
| `doctor` | Checks adb, lists devices it can see. |
| `connect -Ip <ip>` | Connects. The TV shows an approval dialog — tick "Always allow". |
| `measure -Label <name>` | Saves `dumpsys meminfo` and all package lists to `snapshots\<name>\`. |
| `triage` | Sorts what is actually installed into the three groups → `triage.md`. |
| `disable -Packages a,b,c` | Disables up to 10. Refuses anything keep-listed. |
| `enable -Packages a,b` | Puts specific packages back. |
| `undo-last` | Reverses the most recent batch, on the TV and in the record. |
| `undo-all` | Reverses everything, animation speeds back to stock. |
| `undo-command` | Prints the single command that undoes the lot. |
| `tune` | Animation scales to 0.5. |
| `trim` | `pm trim-caches`. |
| `reboot` | Reboots the TV. |
| `status` | What is disabled, which launcher is active, animation scales. |
| `replace-launcher` | Disables the Google TV home screen — only after FLauncher checks out. |
| `report` | Before/after table → `REPORT.md`. |

## How your rules are enforced

These are checks in code, not things anyone has to remember:

* **No uninstalling.** There is no `pm uninstall` in the script. Only
  `pm disable-user --user 0`.
* **Keep-list.** `keep-list.txt` is consulted before every disable. A match
  aborts the *whole batch*, so a protected package cannot be slipped through
  alongside legal ones.
* **Batches of 10.** Eleven is refused outright.
* **Forced testing.** Every batch ends by printing the six-point checklist and
  stopping.
* **Records.** Each disabled package is appended to `kapatilanlar.txt` with its
  batch number and a one-line description. `DEBLOAT-LOG.md` gets a narrative
  entry. `undo-last` and `undo-all` read the record, so it cannot drift.
* **When unsure, ask.** Anything `triage` does not recognise goes to Group 2
  with "unrecognised — I will not guess what this does", never Group 1.

## Files

| File | Purpose |
|---|---|
| `keep-list.txt` | Never-disable globs. Edit to add, never to remove. |
| `group1-junk.txt` | Candidates I consider safe. Patterns, not assertions. |
| `group2-ask.txt` | Candidates that need your answer first. |
| `kapatilanlar.txt` | The record. Written by the script — do not hand-edit. |
| `DEBLOAT-LOG.md` | What was done and why, with undo commands. |
| `triage.md`, `REPORT.md` | Generated output. |

The candidate lists are **glob patterns**, not a claim that those packages
exist on your TV. `triage` intersects them with the real package list, so a
package I guessed wrong about simply never appears.

## Replacing the home screen

Strict order. Doing this out of order gives you a black screen at boot.

1. On the TV, install **FLauncher** from the Play Store.
2. Open it once. Press Home, choose FLauncher, pick **Always**.
3. `.\Tv-Debloat.ps1 replace-launcher` — it verifies FLauncher is installed
   *and* that HOME actually resolves to it, then asks you to type `YES`.
4. `.\Tv-Debloat.ps1 reboot`, then confirm FLauncher still comes up.

If you do get a black screen, the TV is still on Ethernet and ADB still works:

```powershell
.\Tv-Debloat.ps1 connect -Ip 192.168.1.29
adb shell pm enable com.google.android.apps.tv.launcherx
.\Tv-Debloat.ps1 reboot
```

## An honest word about "faster"

Disabling background packages frees RAM and stops wake-ups, which genuinely
helps a TV with limited memory. But two things are worth knowing:

* **Animation scaling does not make the TV faster.** It makes it *feel* faster
  because you spend less time watching transitions. That is a real improvement
  in how it responds, but not more processing power.
* **"Free RAM" is a misleading number.** Android deliberately fills unused RAM
  with cache. The figure to compare is **Used RAM** measured shortly after a
  reboot, in both snapshots. `report` prints both and flags this.

The big win here is not the RAM figure — it is the ad and recommendation rows
disappearing.

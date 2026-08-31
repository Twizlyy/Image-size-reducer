<#
.SYNOPSIS
    Reversible Android TV debloat over ADB. Built for a TCL Google TV.

.DESCRIPTION
    Every change this script makes is undoable with 'pm enable'. There is no
    call to 'pm uninstall' anywhere in this file, by design.

    Safety rules enforced in code, not left to memory:
      * keep-list.txt is consulted before every disable. A match is refused.
      * No more than 10 packages may be disabled in one batch.
      * After each batch the script stops and prints the test checklist.
      * Every disabled package is appended to kapatilanlar.txt with its batch
        number, so 'undo-last' and 'undo-all' always know what to reverse.

.EXAMPLE
    .\Tv-Debloat.ps1 setup
    .\Tv-Debloat.ps1 connect -Ip 192.168.1.42
    .\Tv-Debloat.ps1 measure -Label before
    .\Tv-Debloat.ps1 triage
    .\Tv-Debloat.ps1 disable -Packages com.a,com.b
    .\Tv-Debloat.ps1 undo-last
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'setup', 'doctor', 'connect', 'measure', 'triage', 'disable',
                 'enable', 'undo-last', 'undo-all', 'undo-command', 'tune', 'trim',
                 'reboot', 'report', 'replace-launcher', 'status')]
    [string]$Command = 'help',

    [string]$Ip,
    [string]$Label,
    [string[]]$Packages,
    [string]$Note = '',
    [switch]$FLauncherIsDefault
)

$ErrorActionPreference = 'Stop'

$Root         = $PSScriptRoot
$SnapDir      = Join-Path $Root 'snapshots'
$DisabledFile = Join-Path $Root 'kapatilanlar.txt'
$LogFile      = Join-Path $Root 'DEBLOAT-LOG.md'
$DeviceFile   = Join-Path $Root '.device'
$ToolsDir     = Join-Path $Root 'platform-tools'
$MaxBatch     = 10
$LauncherPkg  = 'com.google.android.apps.tv.launcherx'
$FLauncherPkg = 'me.efesser.flauncher'

# ---------------------------------------------------------------- output ---
function Say  ($m) { Write-Host "  $m" }
function Step ($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Good ($m) { Write-Host "  [ok] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Fail ($m) { Write-Host "  [X]  $m" -ForegroundColor Red }

# ------------------------------------------------------------------- adb ---
function Get-AdbExe {
    $local = Join-Path $ToolsDir 'adb.exe'
    if (Test-Path $local) { return $local }
    $onPath = Get-Command adb -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

function Assert-Adb {
    $adb = Get-AdbExe
    if (-not $adb) {
        Fail "adb was not found. Run:  .\Tv-Debloat.ps1 setup"
        exit 1
    }
    return $adb
}

function Get-DeviceArg {
    if (Test-Path $DeviceFile) {
        $d = (Get-Content $DeviceFile -Raw).Trim()
        if ($d) { return @('-s', $d) }
    }
    return @()
}

# Runs adb and returns stdout as an array of trimmed lines.
# PowerShell turns anything a native .exe writes to stderr into an ErrorRecord,
# and with $ErrorActionPreference = 'Stop' that becomes a *terminating* error.
# adb writes routine chatter to stderr - "* daemon not running; starting now" -
# so a perfectly healthy first run would otherwise kill the script. Every native
# call goes through here, where the preference is relaxed for that call only
# (assigning it inside a function scopes it to the function).
function Invoke-NativeCapture {
    param([string]$Exe, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $raw  = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = ($raw | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { $_ }
    }) -join "`n"
    return [pscustomobject]@{ Text = $text; Code = $code }
}

# Lines adb prints that are noise, not answers.
function Remove-AdbNoise {
    param([string]$Text)
    return (($Text -split "`r?`n") | Where-Object {
        $_ -notmatch '^\s*\*\s*daemon' -and $_ -notmatch 'daemon started successfully'
    }) -join "`n"
}

function Invoke-Adb {
    param([string[]]$AdbArgs, [switch]$AllowFailure)
    $adb = Assert-Adb
    $all = @(Get-DeviceArg) + $AdbArgs
    $r = Invoke-NativeCapture -Exe $adb -Arguments $all
    $text = Remove-AdbNoise $r.Text
    if ($r.Code -ne 0 -and -not $AllowFailure) {
        Fail "adb $($all -join ' ')  ->  exit $($r.Code)"
        Say $text.Trim()
        exit 1
    }
    return ($text -split "`r?`n" | ForEach-Object { $_.TrimEnd() })
}

function Invoke-AdbShell {
    param([string]$Cmd, [switch]$AllowFailure)
    return Invoke-Adb -AdbArgs @('shell', $Cmd) -AllowFailure:$AllowFailure
}

function Assert-Connected {
    $lines = Invoke-Adb -AdbArgs @('devices') -AllowFailure
    $devices = $lines | Where-Object { $_ -match '^\S+\s+device$' }
    if (-not $devices) {
        $unauth = $lines | Where-Object { $_ -match 'unauthorized' }
        if ($unauth) {
            Fail "The TV says 'unauthorized'."
            Say "Look at the TV screen: approve 'Allow USB debugging from this"
            Say "computer?' and tick 'Always allow from this computer'."
        } else {
            Fail "No TV connected. Run:  .\Tv-Debloat.ps1 connect -Ip <your-tv-ip>"
        }
        exit 1
    }
}

# --------------------------------------------------------------- patterns ---
# Reads 'pattern | reason' files, skipping comments and blank lines.
function Read-PatternFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        # keep-list.txt uses '#' for trailing comments; candidates use '|'.
        if ($line -match '^\s*([^|#]+?)\s*(?:[|#]\s*(.*))?$') {
            [pscustomobject]@{
                Pattern = $Matches[1].Trim()
                Reason  = if ($Matches[2]) { $Matches[2].Trim() } else { '' }
            }
        }
    }
}

function Get-KeepPatterns { Read-PatternFile (Join-Path $Root 'keep-list.txt') }

# Returns the keep-list pattern that protects a package, or $null.
function Get-ProtectingPattern {
    param([string]$Pkg)
    foreach ($p in Get-KeepPatterns) {
        if ($Pkg -like $p.Pattern) { return $p }
    }
    return $null
}

# Accepts an array, a single comma-separated string, or any mix of the two.
# PowerShell binds '-Packages a,b' as an array from a prompt but as one string
# when the script is launched with -File, so never trust it to already be split.
function Expand-PackageList {
    param([string[]]$Raw)
    return @($Raw |
        ForEach-Object { $_ -split '[,;\s]+' } |
        ForEach-Object { $_.Trim() } |
        Where-Object   { $_ } |
        Select-Object -Unique)
}

# Which package currently owns HOME. Android TV builds differ in what
# resolve-activity prints, so try the brief form, the verbose form, and the
# launcher-role query before giving up. Returns '' if none of them answer.
function Get-HomePackage {
    $brief = Invoke-AdbShell 'cmd package resolve-activity --brief -c android.intent.category.HOME' -AllowFailure |
             Where-Object { $_ -match '^[A-Za-z0-9_.]+/' } | Select-Object -First 1
    if ($brief -and $brief -match '^([A-Za-z0-9_.]+)/') { return $Matches[1] }

    $verbose = Invoke-AdbShell 'cmd package resolve-activity -c android.intent.category.HOME' -AllowFailure |
               Where-Object { $_ -match 'packageName=' } | Select-Object -First 1
    if ($verbose -and $verbose -match 'packageName=([A-Za-z0-9_.]+)') { return $Matches[1] }

    $role = Invoke-AdbShell 'cmd shortcut get-default-launcher' -AllowFailure |
            Where-Object { $_ -match '[A-Za-z0-9_.]+/' } | Select-Object -First 1
    if ($role -and $role -match '([A-Za-z0-9_.]+)/') { return $Matches[1] }

    return ''
}

function Get-InstalledPackages {
    Invoke-AdbShell 'pm list packages' |
        Where-Object { $_ -match '^package:' } |
        ForEach-Object { ($_ -replace '^package:', '').Trim() } |
        Where-Object { $_ } | Sort-Object -Unique
}

function Get-DisabledOnDevice {
    Invoke-AdbShell 'pm list packages -d' |
        Where-Object { $_ -match '^package:' } |
        ForEach-Object { ($_ -replace '^package:', '').Trim() } |
        Where-Object { $_ } | Sort-Object -Unique
}

# ---------------------------------------------------------------- records ---
function Initialize-Record {
    if (-not (Test-Path $DisabledFile)) {
        @(
            '# Packages disabled by Tv-Debloat.ps1',
            '# Undo any single line with:   adb shell pm enable <package>',
            '# Tab-separated: timestamp<TAB>batch<TAB>package<TAB>what it was',
            ''
        ) | Set-Content $DisabledFile -Encoding UTF8
    }
}

function Get-RecordRows {
    Initialize-Record
    Get-Content $DisabledFile | ForEach-Object {
        if ($_ -match '^\s*#' -or -not $_.Trim()) { return }
        $f = $_ -split "`t"
        if ($f.Count -ge 3) {
            [pscustomobject]@{
                Time = $f[0]; Batch = [int]$f[1]; Package = $f[2]
                Reason = if ($f.Count -ge 4) { $f[3] } else { '' }
            }
        }
    }
}

function Get-NextBatch {
    $rows = @(Get-RecordRows)
    if (-not $rows) { return 1 }
    return (($rows | Measure-Object -Property Batch -Maximum).Maximum + 1)
}

function Add-Record {
    param([int]$Batch, [string]$Pkg, [string]$Reason)
    Initialize-Record
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    "$stamp`t$Batch`t$Pkg`t$Reason" | Add-Content $DisabledFile -Encoding UTF8
}

function Add-Log {
    param([string]$Text)
    if (-not (Test-Path $LogFile)) {
        "# Debloat log`n" | Set-Content $LogFile -Encoding UTF8
    }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC'
    "`n## $stamp`n`n$Text" | Add-Content $LogFile -Encoding UTF8
}

# ------------------------------------------------------------- the checks ---
function Show-TestChecklist {
    Write-Host ""
    Write-Host "  STOP. Test the TV now, before the next batch." -ForegroundColor Yellow
    Write-Host ""
    Say "1. Press the Inputs / Source button on the remote. Does the menu open?"
    Say "2. Switch to an HDMI input. Does the picture come through?"
    Say "3. Open Netflix. Does it start and play?"
    Say "4. Open YouTube. Does it start and play?"
    Say "5. Is there sound?"
    Say "6. Open something with a text box. Does the on-screen keyboard appear?"
    Write-Host ""
    Say "All six fine  ->  tell me, and we do the next batch."
    Say "Anything broken ->  .\Tv-Debloat.ps1 undo-last"
    Write-Host ""
}

# ------------------------------------------------------------------ verbs ---
function Cmd-Setup {
    Step "Installing Google's platform-tools (adb) into this folder"
    if (Test-Path (Join-Path $ToolsDir 'adb.exe')) {
        Good "adb is already here: $ToolsDir\adb.exe"
        return
    }
    $url = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
    $zip = Join-Path $env:TEMP 'platform-tools.zip'
    Say "Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Say "Extracting into $Root"
    Expand-Archive -Path $zip -DestinationPath $Root -Force
    Remove-Item $zip -Force
    if (Test-Path (Join-Path $ToolsDir 'adb.exe')) {
        Good "adb installed: $ToolsDir\adb.exe"
        Say "This script finds it automatically. Nothing added to your PATH."
        Say "If you want adb everywhere, add $ToolsDir to PATH yourself."
    } else {
        Fail "Extraction finished but adb.exe is not where expected."
        exit 1
    }
}

function Cmd-Doctor {
    Step "Checking the toolchain"
    $adb = Get-AdbExe
    if ($adb) { Good "adb found: $adb" } else { Fail "adb not found. Run: .\Tv-Debloat.ps1 setup"; return }
    Say (((Remove-AdbNoise (Invoke-NativeCapture -Exe $adb -Arguments @('version')).Text) -split "`r?`n") |
         Where-Object { $_.Trim() } | Select-Object -First 1)
    Step "Devices adb can see"
    ((Remove-AdbNoise (Invoke-NativeCapture -Exe $adb -Arguments @('devices')).Text) -split "`r?`n") |
        Where-Object { $_.Trim() } | ForEach-Object { Say $_ }
}

function Cmd-Connect {
    if (-not $Ip) { Fail "Give me the TV's IP:  .\Tv-Debloat.ps1 connect -Ip 192.168.1.42"; exit 1 }
    $adb = Assert-Adb
    $target = if ($Ip -match ':') { $Ip } else { "${Ip}:5555" }

    Step "Connecting to $target"
    Say "Watch the TV screen now. It will ask 'Allow USB debugging from this"
    Say "computer?'. Tick 'Always allow from this computer', then OK."
    Write-Host ""

    Invoke-NativeCapture -Exe $adb -Arguments @('start-server')        | Out-Null
    Invoke-NativeCapture -Exe $adb -Arguments @('disconnect', $target) | Out-Null
    $out = (Remove-AdbNoise (Invoke-NativeCapture -Exe $adb -Arguments @('connect', $target)).Text).Trim()
    Say $out

    if ($out -match 'connected to') {
        $target | Set-Content $DeviceFile -Encoding ASCII -NoNewline
        Start-Sleep -Seconds 2
        $devs = (Invoke-NativeCapture -Exe $adb -Arguments @('devices')).Text
        if ($devs -match 'unauthorized') {
            Warn "Connected, but not yet authorised. Approve the dialog on the TV,"
            Warn "then run this connect command again."
            exit 1
        }
        Good "Connected and authorised."
        $model = (Invoke-AdbShell 'getprop ro.product.model' | Where-Object { $_ }) -join ''
        $rel   = (Invoke-AdbShell 'getprop ro.build.version.release' | Where-Object { $_ }) -join ''
        $sdk   = (Invoke-AdbShell 'getprop ro.build.version.sdk' | Where-Object { $_ }) -join ''
        Say "Model: $model    Android $rel (API $sdk)"
    } else {
        Fail "Could not connect."
        Say "Check: same network as the PC, no VPN active, USB/network debugging on."
        Say "Test the port with:  Test-NetConnection $($target -replace ':.*','') -Port 5555"
        exit 1
    }
}

function Cmd-Measure {
    Assert-Connected
    if (-not $Label) { Fail "Name this snapshot:  .\Tv-Debloat.ps1 measure -Label before"; exit 1 }
    $dir = Join-Path $SnapDir $Label
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    Step "Taking snapshot '$Label'"
    Say "dumpsys meminfo"
    (Invoke-AdbShell 'dumpsys meminfo')      | Set-Content (Join-Path $dir 'meminfo.txt') -Encoding UTF8
    Say "pm list packages -s   (system)"
    (Invoke-AdbShell 'pm list packages -s')  | Set-Content (Join-Path $dir 'packages-system.txt') -Encoding UTF8
    Say "pm list packages -d   (disabled)"
    (Invoke-AdbShell 'pm list packages -d')  | Set-Content (Join-Path $dir 'packages-disabled.txt') -Encoding UTF8
    Say "pm list packages -e   (enabled)"
    (Invoke-AdbShell 'pm list packages -e')  | Set-Content (Join-Path $dir 'packages-enabled.txt') -Encoding UTF8
    Say "pm list packages      (all)"
    (Invoke-AdbShell 'pm list packages')     | Set-Content (Join-Path $dir 'packages-all.txt') -Encoding UTF8

    $m = Get-MemSummary $Label
    Good "Saved to snapshots\$Label\"
    Say ("Total RAM {0}   Free {1}   Used {2}   Enabled pkgs {3}   Disabled {4}" -f `
         $m.Total, $m.Free, $m.Used, $m.Enabled, $m.Disabled)
}

function Get-MemSummary {
    param([string]$Label)
    $dir = Join-Path $SnapDir $Label
    $res = [ordered]@{ Label = $Label; Total = 'n/a'; Free = 'n/a'; Used = 'n/a'
                       Enabled = 'n/a'; Disabled = 'n/a' }
    $mem = Join-Path $dir 'meminfo.txt'
    if (Test-Path $mem) {
        $t = Get-Content $mem -Raw
        if ($t -match 'Total RAM:\s*([\d,]+)K')       { $res.Total = Format-Kb $Matches[1] }
        if ($t -match 'Free RAM:\s*([\d,]+)K')        { $res.Free  = Format-Kb $Matches[1] }
        if ($t -match 'Used RAM:\s*([\d,]+)K')        { $res.Used  = Format-Kb $Matches[1] }
    }
    $en = Join-Path $dir 'packages-enabled.txt'
    $di = Join-Path $dir 'packages-disabled.txt'
    if (Test-Path $en) { $res.Enabled  = @(Get-Content $en | Where-Object { $_ -match '^package:' }).Count }
    if (Test-Path $di) { $res.Disabled = @(Get-Content $di | Where-Object { $_ -match '^package:' }).Count }
    return [pscustomobject]$res
}

function Format-Kb {
    param([string]$Raw)
    $kb = [double]($Raw -replace ',', '')
    return ('{0:N0} MB' -f ($kb / 1024))
}

function Cmd-Triage {
    Assert-Connected
    Step "Reading the package list off the TV"
    $installed  = @(Get-InstalledPackages)
    $disabled   = @(Get-DisabledOnDevice)
    $thirdParty = @(Invoke-AdbShell 'pm list packages -3' |
                    Where-Object { $_ -match '^package:' } |
                    ForEach-Object { ($_ -replace '^package:', '').Trim() } |
                    Where-Object { $_ })
    Say "$($installed.Count) installed, $($disabled.Count) already disabled, $($thirdParty.Count) installed by you"

    $g1 = Read-PatternFile (Join-Path $Root 'group1-junk.txt')
    $g2 = Read-PatternFile (Join-Path $Root 'group2-ask.txt')

    $rows = foreach ($pkg in $installed) {
        if ($disabled -contains $pkg) { continue }
        if ($thirdParty -contains $pkg) {
            [pscustomobject]@{ Package = $pkg; Group = '0 YOURS'
                               Reason = 'you installed this yourself - not factory bloat' }
            continue
        }
        $prot = Get-ProtectingPattern $pkg
        if ($prot) {
            [pscustomobject]@{ Package = $pkg; Group = '3 UNTOUCHABLE'
                               Reason = "protected by keep-list rule '$($prot.Pattern)'" }
            continue
        }
        $hit1 = $g1 | Where-Object { $pkg -like $_.Pattern } | Select-Object -First 1
        if ($hit1) {
            [pscustomobject]@{ Package = $pkg; Group = '1 JUNK'; Reason = $hit1.Reason }
            continue
        }
        $hit2 = $g2 | Where-Object { $pkg -like $_.Pattern } | Select-Object -First 1
        if ($hit2) {
            [pscustomobject]@{ Package = $pkg; Group = '2 ASK ME'; Reason = $hit2.Reason }
            continue
        }
        [pscustomobject]@{ Package = $pkg; Group = '2 ASK ME'
                           Reason = 'unrecognised - I will not guess what this does' }
    }
    $rows = @($rows)

    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine('# Triage')
    [void]$md.AppendLine('')
    [void]$md.AppendLine("Device packages: $($installed.Count) installed, $($disabled.Count) already disabled.")
    [void]$md.AppendLine('')
    foreach ($g in @('1 JUNK', '2 ASK ME', '0 YOURS', '3 UNTOUCHABLE')) {
        $sel = @($rows | Where-Object { $_.Group -eq $g } | Sort-Object Package)
        [void]$md.AppendLine("## Group $g  ($($sel.Count))")
        [void]$md.AppendLine('')
        [void]$md.AppendLine('| Package | What it is |')
        [void]$md.AppendLine('|---|---|')
        foreach ($r in $sel) { [void]$md.AppendLine("| ``$($r.Package)`` | $($r.Reason) |") }
        [void]$md.AppendLine('')
    }
    $outFile = Join-Path $Root 'triage.md'
    $md.ToString() | Set-Content $outFile -Encoding UTF8

    foreach ($g in @('1 JUNK', '2 ASK ME', '0 YOURS', '3 UNTOUCHABLE')) {
        $n = @($rows | Where-Object { $_.Group -eq $g }).Count
        Say ("Group {0,-14} {1,4}" -f $g, $n)
    }
    Good "Written to triage.md - send me that file and I will pick the batches."
}

function Cmd-Disable {
    Assert-Connected
    if (-not $Packages) { Fail "Nothing given. Use: -Packages com.a,com.b"; exit 1 }
    $pkgs = @(Expand-PackageList $Packages)

    Step "Checking $($pkgs.Count) package(s) against the rules"

    # Rule 4: batch cap.
    if ($pkgs.Count -gt $MaxBatch) {
        Fail "$($pkgs.Count) packages requested, the limit is $MaxBatch per batch."
        Say "Split them up. The cap exists so a broken TV is easy to narrow down."
        exit 1
    }

    # Rule 5: keep-list.
    $blocked = @()
    foreach ($p in $pkgs) {
        $prot = Get-ProtectingPattern $p
        if ($prot) { $blocked += [pscustomobject]@{ Package = $p; Pattern = $prot.Pattern; Why = $prot.Reason } }
    }
    if ($blocked) {
        Fail "Refusing. These are on the never-disable list:"
        foreach ($b in $blocked) {
            Say "$($b.Package)"
            $why = if ($b.Why) { $b.Why } else { 'protected system / signal-path / input package' }
            Say "    matched '$($b.Pattern)' - $why"
        }
        Say ""
        Say "Nothing was changed. Not one package in this batch was touched."
        exit 1
    }

    # Sanity: is it actually installed and currently enabled?
    $installed = @(Get-InstalledPackages)
    $already   = @(Get-DisabledOnDevice)
    $todo = @()
    foreach ($p in $pkgs) {
        if ($installed -notcontains $p) { Warn "$p is not installed on this TV - skipping" ; continue }
        if ($already   -contains  $p)   { Warn "$p is already disabled - skipping" ; continue }
        $todo += $p
    }
    if (-not $todo) { Warn "Nothing left to do."; return }

    $batch = Get-NextBatch
    Step "Batch $batch - disabling $($todo.Count) package(s)"

    $g1 = Read-PatternFile (Join-Path $Root 'group1-junk.txt')
    $g2 = Read-PatternFile (Join-Path $Root 'group2-ask.txt')
    $ok = @(); $bad = @()

    foreach ($p in $todo) {
        $out = (Invoke-AdbShell "pm disable-user --user 0 $p" -AllowFailure) -join ' '
        if ($out -match 'new state: disabled') {
            Good "$p"
            $why = $Note
            if (-not $why) {
                $h = ($g1 + $g2) | Where-Object { $p -like $_.Pattern } | Select-Object -First 1
                $why = if ($h) { $h.Reason } else { 'no description recorded' }
            }
            Add-Record -Batch $batch -Pkg $p -Reason $why
            $ok += $p
        } else {
            Fail "$p  ->  $($out.Trim())"
            $bad += $p
        }
    }

    $summary = "Batch $batch. Disabled: " + ($(if ($ok) { $ok -join ', ' } else { 'none' })) + "."
    if ($bad) { $summary += " Failed: " + ($bad -join ', ') + "." }
    $summary += "`n`nUndo this batch:`n`n``````powershell`n.\Tv-Debloat.ps1 undo-last`n``````"
    Add-Log $summary

    Show-TestChecklist
}

function Cmd-Enable {
    Assert-Connected
    if (-not $Packages) { Fail "Nothing given. Use: -Packages com.a,com.b"; exit 1 }
    Step "Re-enabling"
    foreach ($p in (Expand-PackageList $Packages)) {
        $out = (Invoke-AdbShell "pm enable $p" -AllowFailure) -join ' '
        if ($out -match 'new state: enabled') { Good "$p" } else { Fail "$p -> $($out.Trim())" }
    }
}

function Cmd-UndoLast {
    Assert-Connected
    $rows = @(Get-RecordRows)
    if (-not $rows) { Warn "kapatilanlar.txt is empty. Nothing to undo."; return }
    $last = ($rows | Measure-Object -Property Batch -Maximum).Maximum
    $sel  = @($rows | Where-Object { $_.Batch -eq $last })

    Step "Undoing batch $last  ($($sel.Count) package(s))"
    foreach ($r in $sel) {
        $out = (Invoke-AdbShell "pm enable $($r.Package)" -AllowFailure) -join ' '
        if ($out -match 'new state: enabled') { Good "$($r.Package)" } else { Fail "$($r.Package) -> $($out.Trim())" }
    }

    # Drop the batch from the record so the file stays truthful.
    $keep = Get-Content $DisabledFile | Where-Object {
        if ($_ -match '^\s*#' -or -not $_.Trim()) { return $true }
        $f = $_ -split "`t"
        if ($f.Count -lt 3) { return $true }
        return ([int]$f[1] -ne $last)
    }
    $keep | Set-Content $DisabledFile -Encoding UTF8

    Add-Log "Rolled back batch ${last}: $(($sel.Package) -join ', ')."
    Warn "Reboot and test. If it is still broken, the cause is an earlier batch:"
    Say  "run undo-last again, then narrow down one package at a time."
}

function Cmd-UndoAll {
    Assert-Connected
    $rows = @(Get-RecordRows)
    if (-not $rows) { Warn "Nothing recorded. Nothing to undo."; return }
    Step "Re-enabling all $($rows.Count) recorded package(s)"
    foreach ($r in $rows) {
        $out = (Invoke-AdbShell "pm enable $($r.Package)" -AllowFailure) -join ' '
        if ($out -match 'new state: enabled') { Good "$($r.Package)" } else { Fail "$($r.Package) -> $($out.Trim())" }
    }
    Step "Restoring animation speeds to stock (1.0)"
    foreach ($k in 'window_animation_scale', 'transition_animation_scale', 'animator_duration_scale') {
        Invoke-AdbShell "settings put global $k 1.0" -AllowFailure | Out-Null
        Good "$k = 1.0"
    }
    Add-Log "Full rollback: re-enabled every recorded package, animation scales back to 1.0."
    Good "Done. Reboot the TV."
}

function Cmd-UndoCommand {
    $rows = @(Get-RecordRows)
    if (-not $rows) { Warn "Nothing recorded yet."; return }
    $chain = (($rows.Package | Sort-Object -Unique) | ForEach-Object { "pm enable $_" }) -join '; '
    Step "The single command that undoes everything"
    Write-Host ""
    Write-Host "adb shell `"$chain; settings put global window_animation_scale 1.0; settings put global transition_animation_scale 1.0; settings put global animator_duration_scale 1.0`""
    Write-Host ""
    Say "Paste that into PowerShell with the TV connected, then reboot."
    $f = Join-Path $Root 'UNDO-EVERYTHING.txt'
    "adb shell `"$chain; settings put global window_animation_scale 1.0; settings put global transition_animation_scale 1.0; settings put global animator_duration_scale 1.0`"" |
        Set-Content $f -Encoding UTF8
    Good "Also saved to UNDO-EVERYTHING.txt"
}

function Cmd-Tune {
    Assert-Connected
    Step "Halving the animation speeds"
    foreach ($k in 'window_animation_scale', 'transition_animation_scale', 'animator_duration_scale') {
        Invoke-AdbShell "settings put global $k 0.5" | Out-Null
        $v = (Invoke-AdbShell "settings get global $k" | Where-Object { $_ }) -join ''
        Good "$k = $v"
    }
    Say "This does not make the TV faster in any real sense - it makes it *feel*"
    Say "faster, because you spend half as long watching things slide about."
    Add-Log 'Animation scales set to 0.5. Undo: settings put global <key> 1.0'
}

function Cmd-Trim {
    Assert-Connected
    Step "Trimming caches"
    Invoke-AdbShell 'pm trim-caches 999G' -AllowFailure | Out-Null
    Good "Asked Android to drop cached files down to its low-water mark."
    Say "Apps rebuild their caches as you use them, so this is a one-off gain,"
    Say "not a permanent saving. Nothing of yours is deleted."
}

function Cmd-Reboot {
    Assert-Connected
    Step "Rebooting the TV"
    Invoke-Adb -AdbArgs @('reboot') -AllowFailure | Out-Null
    Good "Reboot sent. The TV drops off the network for a minute."
    Say "When it is back:  .\Tv-Debloat.ps1 connect -Ip <ip>"
}

function Cmd-Status {
    Assert-Connected
    Step "Current state"
    $rows = @(Get-RecordRows)
    Say "Recorded as disabled by this tool: $($rows.Count)"
    Say "Disabled on the TV right now:      $(@(Get-DisabledOnDevice).Count)"
    $homePkg = Get-HomePackage
    if ($homePkg) { Say "Home screen resolves to: $homePkg" }
    else          { Warn "Could not determine the current home screen from adb." }
    foreach ($k in 'window_animation_scale', 'transition_animation_scale', 'animator_duration_scale') {
        $v = (Invoke-AdbShell "settings get global $k" | Where-Object { $_ }) -join ''
        Say "$k = $v"
    }
}

function Cmd-ReplaceLauncher {
    Assert-Connected
    Step "Replacing the Google TV home screen with FLauncher"

    $installed = @(Get-InstalledPackages)
    if ($installed -notcontains $FLauncherPkg) {
        Fail "FLauncher is not installed."
        Say "Install it from the Play Store on the TV first (search 'FLauncher'),"
        Say "open it once, then run this command again."
        exit 1
    }
    Good "FLauncher is installed."

    $current = Get-HomePackage
    if ($current) { Say "HOME currently resolves to: $current" }
    else          { Warn "adb could not tell me which launcher owns HOME on this build." }

    if ($current -ne $FLauncherPkg -and -not $FLauncherIsDefault) {
        Fail "FLauncher is not the default home screen yet."
        Say "On the TV: press Home, choose FLauncher, pick 'Always'."
        Say "Then re-run. If your firmware gives no chooser, confirm you have set"
        Say "it inside FLauncher's own settings and re-run with -FLauncherIsDefault."
        exit 1
    }

    Warn "About to disable $LauncherPkg."
    Warn "If FLauncher is NOT working, this leaves a black screen at boot."
    $answer = Read-Host "  Type exactly YES to continue"
    if ($answer -ne 'YES') { Say "Cancelled. Nothing changed."; return }

    $batch = Get-NextBatch
    $out = (Invoke-AdbShell "pm disable-user --user 0 $LauncherPkg" -AllowFailure) -join ' '
    if ($out -match 'new state: disabled') {
        Good "$LauncherPkg disabled."
        Add-Record -Batch $batch -Pkg $LauncherPkg -Reason 'Google TV home screen with its ad and recommendation rows'
        Add-Log "Batch $batch. Disabled the Google TV launcher after confirming FLauncher is default HOME.`n`nUndo: ``adb shell pm enable $LauncherPkg``"
        Say ""
        Say "Now: .\Tv-Debloat.ps1 reboot"
        Say "After it comes back, confirm FLauncher is still the home screen."
        Say "If you get a black screen, plug a USB keyboard in or reconnect adb and run:"
        Say "  adb shell pm enable $LauncherPkg"
    } else {
        Fail "Failed: $($out.Trim())"
    }
}

function Cmd-Report {
    Step "Before / after"
    $snaps = @(Get-ChildItem $SnapDir -Directory -ErrorAction SilentlyContinue | Sort-Object CreationTime)
    if ($snaps.Count -lt 2) {
        Warn "Need at least two snapshots. Take 'before' and 'after' with: measure -Label <name>"
        return
    }
    $a = Get-MemSummary $snaps[0].Name
    $b = Get-MemSummary $snaps[-1].Name

    $t = @"
| Measurement | $($a.Label) | $($b.Label) |
|---|---|---|
| Total RAM | $($a.Total) | $($b.Total) |
| Free RAM | $($a.Free) | $($b.Free) |
| Used RAM | $($a.Used) | $($b.Used) |
| Enabled packages | $($a.Enabled) | $($b.Enabled) |
| Disabled packages | $($a.Disabled) | $($b.Disabled) |
"@
    Write-Host ""
    Write-Host $t
    $t | Set-Content (Join-Path $Root 'REPORT.md') -Encoding UTF8

    $rows = @(Get-RecordRows)
    if ($rows) {
        Write-Host ""
        Say "Disabled by this tool ($($rows.Count)):"
        foreach ($r in ($rows | Sort-Object Batch, Package)) {
            Say ("  [batch {0}] {1} - {2}" -f $r.Batch, $r.Package, $r.Reason)
        }
    }
    Good "Saved to REPORT.md"
    Warn "Read 'Free RAM' with suspicion: Android deliberately fills free RAM with"
    Warn "cache. A lower 'Used RAM' right after a reboot is the honest number."
}

function Cmd-Help {
@"
Tv-Debloat.ps1 - reversible Android TV cleanup over ADB

  setup                          download adb into this folder
  doctor                         check adb and list visible devices
  connect -Ip 192.168.1.42       connect to the TV (approve the dialog on screen)
  measure -Label before          snapshot meminfo + package lists
  triage                         classify what is installed -> triage.md
  disable -Packages a,b,c        disable up to 10, refuses anything keep-listed
  enable  -Packages a,b          re-enable specific packages
  undo-last                      re-enable the most recent batch
  undo-all                       re-enable everything, animations back to stock
  undo-command                   print the single command that undoes it all
  tune                           animation scales to 0.5
  trim                           pm trim-caches
  reboot                         reboot the TV
  status                         what is disabled, which launcher, animation scales
  replace-launcher               disable Google TV home once FLauncher is default
  report                         before/after table -> REPORT.md

Order: setup -> connect -> measure before -> triage -> disable batches
       -> tune -> trim -> reboot -> measure after -> report

Nothing here uninstalls anything. Every change reverses with pm enable.
"@ | Write-Host
}

# ------------------------------------------------------------------ main ---
switch ($Command) {
    'setup'            { Cmd-Setup }
    'doctor'           { Cmd-Doctor }
    'connect'          { Cmd-Connect }
    'measure'          { Cmd-Measure }
    'triage'           { Cmd-Triage }
    'disable'          { Cmd-Disable }
    'enable'           { Cmd-Enable }
    'undo-last'        { Cmd-UndoLast }
    'undo-all'         { Cmd-UndoAll }
    'undo-command'     { Cmd-UndoCommand }
    'tune'             { Cmd-Tune }
    'trim'             { Cmd-Trim }
    'reboot'           { Cmd-Reboot }
    'status'           { Cmd-Status }
    'replace-launcher' { Cmd-ReplaceLauncher }
    'report'           { Cmd-Report }
    default            { Cmd-Help }
}

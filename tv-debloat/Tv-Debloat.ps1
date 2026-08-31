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
                 'reboot', 'report', 'replace-launcher', 'status', 'list-home',
                 'set-home', 'relabel')]
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
# Every activity on the TV that can act as a home screen, as "pkg/activity".
# Google TV shows no launcher chooser, so the component name has to come from
# the device rather than being assumed.
function Get-HomeActivities {
    # An intent with a category but no action matches nothing, so the action
    # has to be included or the query comes back empty on every build.
    foreach ($c in @('cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME',
                     'pm query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME',
                     'cmd package query-activities -a android.intent.action.MAIN -c android.intent.category.HOME')) {
        $hits = @(Invoke-AdbShell $c -AllowFailure |
                  ForEach-Object { if ($_ -match '([A-Za-z0-9_.]+/[A-Za-z0-9_.$]+)') { $Matches[1] } } |
                  Where-Object { $_ })
        if ($hits) { return @($hits | Sort-Object -Unique) }
    }
    return @()
}

# The HOME activity of one specific package. Tried three ways, because builds
# differ in which of these the shell actually implements.
function Get-HomeActivityFor {
    param([string]$Pkg)
    $esc = [regex]::Escape($Pkg)

    # 1. Resolver, scoped to this package with -p.
    $r = Invoke-AdbShell "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME -p $Pkg" -AllowFailure |
         ForEach-Object { if ($_ -match "($esc/[A-Za-z0-9_.`$]+)") { $Matches[1] } } |
         Where-Object { $_ } | Select-Object -First 1
    if ($r) { return $r }

    # 2. The full HOME list, filtered.
    $q = Get-HomeActivities | Where-Object { $_ -like "$Pkg/*" } | Select-Object -First 1
    if ($q) { return $q }

    # 3. Read the package dump and pair an activity name with the HOME category.
    $current = ''
    foreach ($line in (Invoke-AdbShell "dumpsys package $Pkg" -AllowFailure)) {
        if ($line -match "($esc/[A-Za-z0-9_.`$]+)") { $current = $Matches[1] }
        if ($line -match 'android\.intent\.category\.HOME' -and $current) { return $current }
    }
    return ''
}

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
    if ($m.Total -eq 'n/a') {
        Warn "The memory figures did not parse. dumpsys meminfo returns nothing"
        Warn "useful for a minute or two after a reboot, while services start."
        Warn "Wait a few minutes with the TV idle, then measure again under a"
        Warn "new label, e.g.  .\Tv-Debloat.ps1 measure -Label after-settled"
    }
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

# Packages are disabled with 'pm disable-user --user 0'. A bare 'pm enable'
# does not reliably undo a user-scoped disable on every build - and worse, it
# can report "new state: enabled" while the package stays disabled. So try both
# forms and VERIFY against the device rather than trusting what adb printed.
function Enable-Package {
    param([string]$Pkg)
    foreach ($cmd in @("pm enable $Pkg", "pm enable --user 0 $Pkg")) {
        Invoke-AdbShell $cmd -AllowFailure | Out-Null
        if (@(Get-DisabledOnDevice) -notcontains $Pkg) { return $true }
    }
    return $false
}

function Report-EnableFailure {
    param([string]$Pkg)
    Fail "$Pkg is STILL disabled after both enable forms."
    Say  "  Left in the record so it is not lost. Try by hand:"
    Say  "    adb shell pm enable --user 0 $Pkg"
}

function Cmd-Enable {
    Assert-Connected
    if (-not $Packages) { Fail "Nothing given. Use: -Packages com.a,com.b"; exit 1 }
    Step "Re-enabling"
    foreach ($p in (Expand-PackageList $Packages)) {
        if (Enable-Package $p) { Good "$p" } else { Report-EnableFailure $p }
    }
}

function Cmd-UndoLast {
    Assert-Connected
    $rows = @(Get-RecordRows)
    if (-not $rows) { Warn "kapatilanlar.txt is empty. Nothing to undo."; return }
    $last = ($rows | Measure-Object -Property Batch -Maximum).Maximum
    $sel  = @($rows | Where-Object { $_.Batch -eq $last })

    Step "Undoing batch $last  ($($sel.Count) package(s))"
    $freed = @()
    foreach ($r in $sel) {
        if (Enable-Package $r.Package) { Good "$($r.Package)"; $freed += $r.Package }
        else { Report-EnableFailure $r.Package }
    }

    # Drop ONLY the rows actually re-enabled. A package that is still disabled
    # keeps its row, so the record can never claim something is enabled while
    # the TV still has it off - which would put it beyond reach of undo-all.
    $keep = Get-Content $DisabledFile | Where-Object {
        if ($_ -match '^\s*#' -or -not $_.Trim()) { return $true }
        $f = $_ -split "`t"
        if ($f.Count -lt 3) { return $true }
        return ($freed -notcontains $f[2])
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
    $stuck = @()
    foreach ($r in $rows) {
        if (Enable-Package $r.Package) { Good "$($r.Package)" }
        else { Report-EnableFailure $r.Package; $stuck += $r.Package }
    }
    # Keep rows only for packages that did NOT come back. Leaving every row in
    # place meant a later re-disable appended duplicates on top of stale
    # entries, and the record drifted away from the device.
    $keep = Get-Content $DisabledFile | Where-Object {
        if ($_ -match '^\s*#' -or -not $_.Trim()) { return $true }
        $f = $_ -split "`t"
        if ($f.Count -lt 3) { return $true }
        return ($stuck -contains $f[2])
    }
    $keep | Set-Content $DisabledFile -Encoding UTF8
    if ($stuck) {
        Warn "$($stuck.Count) package(s) could not be re-enabled and remain recorded."
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
    $dev  = @(Get-DisabledOnDevice)
    Say "Recorded as disabled by this tool: $($rows.Count)"
    Say "Disabled on the TV right now:      $($dev.Count)"

    # A package disabled on the TV but missing from the record is beyond the
    # reach of undo-all. Say so loudly rather than leaving it to be spotted by
    # comparing two counts by eye.
    $known = @($rows | ForEach-Object { $_.Package })

    # Packages already disabled in the 'before' snapshot were not our doing,
    # so they are not orphans and reporting them as such is just noise.
    $preFile = Join-Path $Root 'snapshots\before\packages-disabled.txt'
    $pre = @()
    if (Test-Path $preFile) {
        $pre = @(Get-Content $preFile |
                 ForEach-Object { ($_ -replace '^package:', '').Trim() } |
                 Where-Object { $_ })
    }

    $preHit  = @($dev | Where-Object { $known -notcontains $_ -and $pre -contains $_ })
    $orphans = @($dev | Where-Object { $known -notcontains $_ -and $pre -notcontains $_ })

    if ($preHit) {
        Say "$($preHit.Count) package(s) were already disabled before this tool ran:"
        foreach ($o in $preHit) { Say "    $o" }
    }
    if ($orphans) {
        Warn "$($orphans.Count) package(s) disabled on the TV but NOT in the record."
        Warn "undo-all will NOT restore these. Re-enable by hand if wanted:"
        foreach ($o in $orphans) { Say "    adb shell pm enable --user 0 $o" }
    }

    # The mirror case: a row claiming a package is disabled when the TV says it
    # is enabled. Harmless to undo-all, but it makes the record overstate what
    # was done, and the count no longer matches the device.
    $stale = @($known | Where-Object { $dev -notcontains $_ })
    if ($stale) {
        Warn "$($stale.Count) row(s) in the record name a package that is NOT"
        Warn "disabled on the TV. Run 'relabel' to drop them. They are:"
        foreach ($o in $stale) { Say "    $o" }
    }
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
    Step "Disabling the Google TV home screen"

    # Whatever currently owns HOME is the replacement - Projectivy, FLauncher,
    # or anything else. Hardcoding one launcher was wrong: the check has to
    # follow the device, not a name baked into this script.
    $current = Get-HomePackage
    if (-not $current) {
        Fail "adb cannot tell me which launcher owns HOME on this build."
        Say "Run:  .\Tv-Debloat.ps1 list-home"
        Say "and set a launcher with set-home before disabling the stock one."
        exit 1
    }
    Say "HOME currently resolves to: $current"

    if ($current -eq $LauncherPkg) {
        Fail "The Google TV launcher is still your home screen."
        Say "Set a replacement first:"
        Say "  .\Tv-Debloat.ps1 list-home"
        Say "  .\Tv-Debloat.ps1 set-home -Packages <your launcher>"
        exit 1
    }

    # FallbackHome means no real launcher is set - disabling now is how you
    # get a TV with nowhere to go.
    if ($current -like 'com.android.tv.settings*') {
        Fail "HOME resolves to FallbackHome, which is not a launcher."
        Say "Install or set a real launcher first, then re-run."
        exit 1
    }

    if (@(Get-InstalledPackages) -notcontains $current) {
        Fail "$current owns HOME but is not installed. Refusing to continue."
        exit 1
    }
    Good "$current is installed and owns HOME."

    if (@(Get-DisabledOnDevice) -contains $LauncherPkg) {
        Good "$LauncherPkg is already disabled. Nothing to do."
        return
    }

    Warn "About to disable $LauncherPkg."
    Warn "If $current is NOT working, this leaves a black screen at boot."
    Warn "Note: the remote's branded hotkeys (Netflix/Prime/YouTube/Media) may"
    Warn "stop working while the Google TV launcher is disabled."
    $answer = Read-Host "  Type exactly YES to continue"
    if ($answer -ne 'YES') { Say "Cancelled. Nothing changed."; return }

    $batch = Get-NextBatch
    $out = (Invoke-AdbShell "pm disable-user --user 0 $LauncherPkg" -AllowFailure) -join ' '
    if ($out -match 'new state: disabled') {
        Good "$LauncherPkg disabled."
        Add-Record -Batch $batch -Pkg $LauncherPkg -Reason 'Google TV home screen with its ad and recommendation rows'
        Add-Log "Batch $batch. Disabled the Google TV launcher; HOME was $current."
        Say ""
        Say "Now: .\Tv-Debloat.ps1 reboot"
        Say "After it comes back, confirm $current is still the home screen AND"
        Say "test the remote's Netflix / Prime / YouTube / Media buttons."
        Say "If you get a black screen, reconnect adb and run:"
        Say "  adb shell pm enable --user 0 $LauncherPkg"
    } else {
        Fail "Failed: $($out.Trim())"
    }
}


function Cmd-ListHome {
    Assert-Connected
    Step "Apps on this TV that can be the home screen"
    $acts = Get-HomeActivities
    if (-not $acts) {
        Warn "The bulk query returned nothing on this build. Probing the"
        Warn "likely launchers one at a time instead."
        $probe = @(Get-InstalledPackages | Where-Object {
            $_ -match 'launcher|flauncher|home|leanback|tvlauncher'
        })
        foreach ($p in $probe) {
            $c = Get-HomeActivityFor $p
            if ($c) { $acts += $c }
        }
    }
    if (-not $acts) {
        Warn "Still nothing. replace-launcher remains available as the fallback."
        return
    }
    foreach ($a in $acts) { Say $a }
    Write-Host ""
    $now = Get-HomePackage
    if ($now) { Say "Currently active: $now" } else { Warn "Could not tell which is active." }
}

function Cmd-SetHome {
    Assert-Connected
    if (-not $Packages) { Fail "Which package? e.g. -Packages me.efesser.flauncher"; exit 1 }
    $target = @(Expand-PackageList $Packages)[0]

    if (@(Get-InstalledPackages) -notcontains $target) {
        Fail "$target is not installed on this TV."
        exit 1
    }
    $component = Get-HomeActivityFor $target
    if (-not $component) {
        Fail "$target registers no HOME activity that adb can find."
        Say "Open the app once on the TV, then try again. If it still fails,"
        Say "replace-launcher is the fallback route."
        exit 1
    }

    Step "Setting $component as the home screen"
    $out = (Invoke-AdbShell "cmd package set-home-activity $component" -AllowFailure) -join ' '
    if ($out.Trim()) { Say $out.Trim() }

    $now = Get-HomePackage
    if ($now -eq $target) {
        Good "HOME now resolves to $now"
        Say "Press Home on the remote to confirm, then run replace-launcher."
    } else {
        Warn "HOME still resolves to '$now'."
        Say "Some builds refuse set-home-activity while the stock launcher is enabled."
        Say "In that case replace-launcher is the route: disabling the Google"
        Say "launcher leaves FLauncher as the only home app, so it wins by default."
    }
}


function Cmd-Relabel {
    Assert-Connected
    $rows = @(Get-RecordRows)
    if (-not $rows) { Warn "kapatilanlar.txt is empty."; return }
    $g1 = Read-PatternFile (Join-Path $Root 'group1-junk.txt')
    $g2 = Read-PatternFile (Join-Path $Root 'group2-ask.txt')

    Step "Tidying the record"
    $dev = @(Get-DisabledOnDevice)
    $seen = @{}; $filled = 0; $dupes = 0; $stale = 0
    $out = @(
        '# Packages disabled by Tv-Debloat.ps1',
        '# Undo any single line with:   adb shell pm enable <package>',
        '# Tab-separated: timestamp<TAB>batch<TAB>package<TAB>what it was',
        ''
    )
    foreach ($r in ($rows | Sort-Object Batch, Package)) {
        if ($seen.ContainsKey($r.Package)) {
            $dupes++
            continue
        }
        # A row for a package the TV reports as enabled is no longer true.
        if ($dev -notcontains $r.Package) {
            $stale++
            continue
        }
        $seen[$r.Package] = $true
        $why = $r.Reason
        if (-not $why -or $why -eq 'no description recorded') {
            $h = ($g1 + $g2) | Where-Object { $r.Package -like $_.Pattern } | Select-Object -First 1
            if ($h -and $h.Reason) { $why = $h.Reason; $filled++ }
        }
        $out += "$($r.Time)`t$($r.Batch)`t$($r.Package)`t$why"
    }
    $out | Set-Content $DisabledFile -Encoding UTF8
    Good "Descriptions filled in: $filled.  Duplicate rows removed: $dupes."
    if ($stale) { Good "Stale rows dropped (package no longer disabled): $stale." }
    Say  "$($seen.Count) unique packages now recorded."
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
  list-home                      list every app that can act as the home screen
  set-home -Packages <pkg>       make that app the home screen (Google TV has no chooser)
  replace-launcher               disable Google TV home once FLauncher is default
  relabel                        fill in missing descriptions, drop duplicate rows
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
    'relabel'          { Cmd-Relabel }
    'list-home'        { Cmd-ListHome }
    'set-home'         { Cmd-SetHome }
    'replace-launcher' { Cmd-ReplaceLauncher }
    'report'           { Cmd-Report }
    default            { Cmd-Help }
}

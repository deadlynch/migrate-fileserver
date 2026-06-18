#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
============================================================================
  Migrate-FileServer.ps1  -  Guided file server migration CLI (with ETA)
----------------------------------------------------------------------------
  Migrates a department (folder + SMB share) from an old file server to a new
  one, preserving NTFS ACLs, ownership and the share-level permission.
  Target: Windows Server, Active Directory domain, 1:1 migration, one share
  (department) at a time.

  Usage: open an ADMIN PowerShell and run  .\Migrate-FileServer.ps1
         then follow the menu (no parameters to memorize).

  Phases:
    BASELINE -> first copy, old server still live, users working. Adds only.
    DELTA    -> fast copy of what changed. Run as many times as you like.
    CUTOVER  -> final mirror copy + (re)create the share. Do it with the old
                share already set to read-only.

  Identity assumption: source and destination in the SAME AD domain, so the
  SIDs referenced by the NTFS ACLs resolve identically on both sides and the
  copied ACLs work without remapping. The orphan-ACE scan catches the
  exception (an ACE pointing at a LOCAL account of the old server).

  ENCODING NOTE:
  This file is intentionally 100% ASCII so it parses the same under any
  encoding (Windows PowerShell 5.1 reads scripts as ANSI by default). The
  progress-bar block characters are built at run time. If the bar shows boxes
  on your console, set $UseUnicodeBar to $false below.
============================================================================
#>

$ErrorActionPreference = 'Stop'
try { chcp 65001 | Out-Null } catch {}
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Toggle the solid progress-bar blocks (set to $false if you see boxes)
$UseUnicodeBar = $true

$ProfileDir = Join-Path $PSScriptRoot 'profiles'
$LogRoot    = Join-Path $PSScriptRoot 'migration-logs'
foreach ($d in @($ProfileDir,$LogRoot)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

# Color palette
$C = @{ Brand='Cyan'; Ok='Green'; Warn='Yellow'; Bad='Red'; Dim='DarkGray'; Hi='White' }

# Progress-bar glyphs built at run time (source stays ASCII)
if ($UseUnicodeBar) {
    $script:GFull  = [string][char]0x2588   # full block
    $script:GLight = [string][char]0x2591   # light shade
} else {
    $script:GFull  = '#'
    $script:GLight = '-'
}

# ===========================================================================
#  COSMETICS
# ===========================================================================
function Clear-Screen { try { Clear-Host } catch {} }

function Show-Banner {
    Clear-Screen
    $art = @(
        '+==============================================================+',
        '|                                                              |',
        '|    ###  FILE SERVER MIGRATION                                |',
        '|    Guided department migration  (NTFS perms + SMB share)     |',
        '|                                                              |',
        '+==============================================================+'
    )
    foreach ($l in $art) { Write-Host $l -ForegroundColor $C.Brand }
    Write-Host "  source -> destination  |  preserves perms, owner and share  |  live ETA" -ForegroundColor $C.Dim
    Write-Host ""
}
function Title($t) {
    Show-Banner
    Write-Host "  [ $t ]" -ForegroundColor $C.Hi
    Write-Host  ("  " + ('-'*60)) -ForegroundColor $C.Dim
}
function Info($m)  { Write-Host "    $m" }
function Good($m)  { Write-Host "    [OK] $m" -ForegroundColor $C.Ok }
function Warn($m)  { Write-Host "    [!]  $m" -ForegroundColor $C.Warn }
function Bad($m)   { Write-Host "    [X]  $m" -ForegroundColor $C.Bad }
function Step($m)  { Write-Host "`n  >> $m" -ForegroundColor $C.Brand }
function Pause-Enter { Write-Host ""; Read-Host "    [ENTER] to continue" | Out-Null }

function Format-Eta {
    param([TimeSpan]$ts)
    if ($ts.TotalHours -ge 1) { return ('{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours,$ts.Minutes,$ts.Seconds) }
    return ('{0:00}:{1:00}' -f [int]$ts.TotalMinutes,$ts.Seconds)
}
function Show-Bar {
    param([double]$Pct,[double]$CopiedGB,[double]$TotalGB,[double]$Mbps,[string]$Eta)
    $w = 34
    $fill = [int]([math]::Floor($Pct/100*$w))
    if ($fill -gt $w) { $fill = $w }
    $bar = ($script:GFull * $fill) + ($script:GLight * ($w-$fill))
    # Dynamic color: yellow while copying, green once past 90%
    $clr = if ($Pct -ge 90) { $C.Ok } else { $C.Warn }
    $line = ("`r    [{0}] {1,5:N1}%  {2,6:N2}/{3:N2} GB  {4,6:N1} MB/s  ETA {5}   " -f $bar,$Pct,$CopiedGB,$TotalGB,$Mbps,$Eta)
    Write-Host $line -NoNewline -ForegroundColor $clr
}

# ===========================================================================
#  INPUT HELPERS (validated)
# ===========================================================================
function Ask-Text { param([string]$Prompt,[string]$Default,[switch]$AllowEmpty)
    while ($true) {
        $hint = if ($Default) { " [$Default]" } else { "" }
        $v = Read-Host "    $Prompt$hint"
        if ([string]::IsNullOrWhiteSpace($v) -and $Default) { return $Default }
        if ([string]::IsNullOrWhiteSpace($v) -and $AllowEmpty) { return "" }
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
        Bad "A value is required."
    } }
function Ask-YesNo { param([string]$Prompt,[bool]$DefaultYes=$true)
    $d = if ($DefaultYes) { "Y/n" } else { "y/N" }
    while ($true) {
        $v = (Read-Host "    $Prompt ($d)").Trim().ToLower()
        if ($v -eq "") { return $DefaultYes }
        if ($v -in 'y','yes') { return $true }
        if ($v -in 'n','no')  { return $false }
        Bad "Please answer Y or N."
    } }
function Ask-Int { param([string]$Prompt,[int]$Default,[int]$Min=1,[int]$Max=128)
    while ($true) {
        $v = Read-Host "    $Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
        if ($v -match '^\d+$' -and [int]$v -ge $Min -and [int]$v -le $Max) { return [int]$v }
        Bad "Enter a whole number between $Min and $Max."
    } }
function Ask-Menu { param([string]$Prompt,[string[]]$Options)
    for ($i=0;$i -lt $Options.Count;$i++) {
        Write-Host ("      {0}  {1}" -f "[$($i+1)]", $Options[$i]) -ForegroundColor $C.Hi
    }
    Write-Host ""
    while ($true) {
        $v = Read-Host "    $Prompt"
        if ($v -match '^\d+$' -and [int]$v -ge 1 -and [int]$v -le $Options.Count) { return [int]$v }
        Bad "Enter a number between 1 and $($Options.Count)."
    } }
function Ask-SourcePath {
    while ($true) {
        $p = Ask-Text "SOURCE path (e.g. \\OLD-FS\Finance$)"
        Write-Host "    testing source..." -NoNewline -ForegroundColor $C.Dim
        if (Test-Path -LiteralPath $p) { Write-Host " OK" -ForegroundColor $C.Ok; return $p }
        Write-Host ""; Bad "Could not access '$p'."
    } }
function Ask-DestPath {
    while ($true) {
        $p = Ask-Text "DESTINATION path (e.g. E:\Data\Finance)"
        if (Test-Path -LiteralPath $p) { Good "Destination exists."; return $p }
        if (Ask-YesNo "Destination does not exist. Create it now?" $true) {
            try { New-Item -ItemType Directory -Path $p -Force | Out-Null; Good "Created."; return $p }
            catch { Bad $_.Exception.Message }
        }
    } }
function Ask-Server { param([string]$Label)
    while ($true) {
        $s = Ask-Text "$Label server (NetBIOS name, e.g. OLD-FS)"
        Write-Host "    pinging '$s'..." -NoNewline -ForegroundColor $C.Dim
        if (Test-Connection -ComputerName $s -Count 1 -Quiet -ErrorAction SilentlyContinue) { Write-Host " OK" -ForegroundColor $C.Ok; return $s }
        Write-Host ""
        if (Ask-YesNo "No ping reply. Use it anyway?" $false) { return $s }
    } }

# ===========================================================================
#  PROFILE
# ===========================================================================
function New-MigrationProfile {
    Title "NEW DEPARTMENT"
    Info "I'll ask for the details once and save a reusable profile.`n"
    $dept   = Ask-Text "Department name (e.g. Finance)"
    $src    = Ask-SourcePath
    $dst    = Ask-DestPath
    $share  = Ask-Text "SHARE name on the destination" $dept
    $ssrv   = Ask-Server 'SOURCE'
    $dsrv   = Ask-Server 'DESTINATION'
    $threads= Ask-Int "robocopy threads (/MT, 1-128)" 16 1 128
    $quiet  = Ask-YesNo "Suppress file names in logs? (for privacy-sensitive folders; disables the detailed bar)" $false
    $p = [ordered]@{ Dept=$dept;SourcePath=$src;DestPath=$dst;ShareName=$share;
        SourceServer=$ssrv;DestServer=$dsrv;Threads=$threads;QuietLog=$quiet;
        Created=(Get-Date).ToString('s');History=@() }
    $file = Join-Path $ProfileDir ("{0}.json" -f ($dept -replace '[^\w\-]','_'))
    $p | ConvertTo-Json -Depth 5 | Set-Content $file -Encoding UTF8
    Good "Profile saved: $file"; Pause-Enter; return $file
}
function Get-Profiles { Get-ChildItem $ProfileDir -Filter *.json -EA SilentlyContinue }
function Load-Profile { param($Path) Get-Content $Path -Raw | ConvertFrom-Json }
function Save-Profile { param($ProfileObj,$Path) $ProfileObj | ConvertTo-Json -Depth 5 | Set-Content $Path -Encoding UTF8 }
# Safe slug for file names derived from a (possibly funky) department name
function Get-SafeName { param([string]$Name) ($Name -replace '[^\w\-]','_') }

function Show-ProfileSummary { param($P)
    Write-Host ("    +" + ('-'*46)) -ForegroundColor $C.Dim
    Write-Host ("    | {0}" -f $P.Dept) -ForegroundColor $C.Hi
    Write-Host ("    | source: {0}" -f $P.SourcePath) -ForegroundColor $C.Dim
    Write-Host ("    | dest  : {0}" -f $P.DestPath)   -ForegroundColor $C.Dim
    Write-Host ("    | share : {0}   threads: {1}   quietLog: {2}" -f $P.ShareName,$P.Threads,$P.QuietLog) -ForegroundColor $C.Dim
    if ($P.History.Count -gt 0) {
        Write-Host "    | history:" -ForegroundColor $C.Dim
        foreach ($h in ($P.History | Select-Object -Last 5)) {
            $col = if ($h.Result -like 'OK*') { $C.Ok } else { $C.Bad }
            Write-Host ("    |   - {0}  {1,-8} {2}" -f $h.When,$h.Mode,$h.Result) -ForegroundColor $col
        }
    }
    Write-Host ("    +" + ('-'*46)) -ForegroundColor $C.Dim
}

# ===========================================================================
#  CORE
# ===========================================================================
function Get-LocalPathOnDest { param($P)
    if ($P.DestPath -match '^[a-zA-Z]:\\') { return $P.DestPath }
    return ($P.DestPath -replace "^\\\\$([regex]::Escape($P.DestServer))\\([a-zA-Z])\$",'$1:')
}
# Locale-proof: with /NC robocopy prints no translatable class label, leaving
# "<bytes> <path>". Matches: line start, (bytes), whitespace, then a path.
$script:FileTag = '^\s*(\d+)\s+\S'

function Get-CopyEstimate { param($P,[string[]]$ModeFlags)
    Step "Estimating volume to copy"
    $script:total = [int64]0; $script:files = 0
    $listArgs = @($P.SourcePath,$P.DestPath)+$ModeFlags+@('/L','/BYTES','/NC','/NP','/NJH','/NJS','/NDL','/R:0','/W:0','/XJ','/XF','~$*','*.tmp','Thumbs.db')
    & robocopy.exe @listArgs 2>$null | ForEach-Object {
        if ($_ -match $script:FileTag) {
            $script:total += [int64]$Matches[1]; $script:files++
            if ($script:files % 40 -eq 0) {
                Write-Host ("`r    scanning... {0} files / {1:N2} GB" -f $script:files,($script:total/1GB)) -NoNewline -ForegroundColor $C.Dim
            }
        }
    }
    Write-Host ("`r    to copy: {0} files, {1:N2} GB{2}" -f $script:files,($script:total/1GB),(' '*25)) -ForegroundColor $C.Brand
    return @{ Total=$script:total; Files=$script:files }
}

function Invoke-RoboCopyProgress { param($P,[string]$Mode,[string]$LogFile,[switch]$DryRun)
    if (-not (Test-Path -LiteralPath $P.SourcePath)) { throw "Source not reachable: $($P.SourcePath)" }
    $modeFlags = if ($Mode -eq 'Cutover') { @('/MIR') } else { @('/E') }

    $est = Get-CopyEstimate -P $P -ModeFlags $modeFlags
    if ($DryRun) { Good "Dry run complete (nothing was copied)."; return -1 }

    # /XF excludes Office lock files (~$*), temp and shell junk - they are
    # transient and frequently vanish mid-copy, which otherwise trips ERROR 2.
    $common = @('/COPYALL','/DCOPY:DAT','/SECFIX','/B','/R:2','/W:5',"/MT:$($P.Threads)",'/XJ','/NP','/BYTES','/NC','/NDL','/XF','~$*','*.tmp','Thumbs.db')
    if ($P.QuietLog) { $common += @('/NFL','/NDL') }
    $rcArgs = @($P.SourcePath,$P.DestPath)+$modeFlags+$common

    Step "Copying data + NTFS ACLs + ownership"
    $script:copied=[int64]0; $script:last=Get-Date; $start=Get-Date
    $total=[int64]$est.Total
    if ($total -le 0) { Info "(nothing to copy; applying fixes/SECFIX...)" }

    & robocopy.exe @rcArgs 2>&1 | Tee-Object -FilePath $LogFile | ForEach-Object {
        if (-not $P.QuietLog -and $total -gt 0 -and $_ -match $script:FileTag) {
            $script:copied += [int64]$Matches[1]
            $now = Get-Date
            if (($now-$script:last).TotalMilliseconds -gt 300) {
                $script:last = $now
                $pct  = [math]::Min(100,($script:copied/$total*100))
                $el   = ($now-$start).TotalSeconds
                $mbps = if ($el -gt 0) { ($script:copied/1MB)/$el } else { 0 }
                $eta  = if ($mbps -gt 0) { [TimeSpan]::FromSeconds(((($total-$script:copied)/1MB)/$mbps)) } else { [TimeSpan]::Zero }
                Show-Bar -Pct $pct -CopiedGB ($script:copied/1GB) -TotalGB ($total/1GB) -Mbps $mbps -Eta (Format-Eta $eta)
                Write-Progress -Activity "Copying $($P.Dept) [$Mode]" -Status ("{0:N1}% - ETA {1}" -f $pct,(Format-Eta $eta)) -PercentComplete $pct
            }
        }
    }
    $code = $LASTEXITCODE
    Write-Progress -Activity "x" -Completed
    if ($total -gt 0 -and -not $P.QuietLog) { Show-Bar -Pct 100 -CopiedGB ($total/1GB) -TotalGB ($total/1GB) -Mbps 0 -Eta "00:00"; Write-Host "" }

    # Robocopy exit codes are a bitmask, not a severity scale:
    #   1=copied  2=extras  4=mismatch  8=some files FAILED  16=fatal error
    # 8 (a few files skipped/failed - e.g. open or vanished files) should NOT
    # abort a Baseline/Delta; only a fatal error (>=16) truly aborts.
    if ($code -ge 16) {
        Bad "robocopy exit $code (FATAL error). See $LogFile"
        throw "robocopy fatal error (exit $code)."
    }
    elseif ($code -band 8) {
        Warn "robocopy exit ${code}: some files were not copied (open/locked or vanished)."
        Warn "This is expected on a live Baseline; a later Delta/Cutover usually picks them up. See $LogFile"
    }
    elseif ($code -eq 0) { Good "In sync (no changes)." }
    else { Good "Copy complete (exit $code = success)." }
    return $code
}

function Test-OrphanedAce { param($P,[switch]$Deep)
    Step "Scanning for orphaned ACEs (old server local account / unresolved SID)"
    $srcNet = ($P.SourceServer -split '\.')[0]
    $targets = @($P.DestPath)
    if ($Deep) { $targets += (Get-ChildItem $P.DestPath -Directory -Recurse -EA SilentlyContinue).FullName }
    else       { $targets += (Get-ChildItem $P.DestPath -Directory -EA SilentlyContinue).FullName }
    $issues = New-Object System.Collections.Generic.List[object]
    foreach ($t in ($targets | Where-Object {$_})) {
        try { $acl = Get-Acl -LiteralPath $t } catch { continue }
        foreach ($a in $acl.Access) {
            $id = $a.IdentityReference.Value
            if ($id -match '^S-1-' -or $id -like "$srcNet\*") { $issues.Add([PSCustomObject]@{Path=$t;Identity=$id;Rights=$a.FileSystemRights}) }
        }
    }
    if ($issues.Count -gt 0) {
        Warn "$($issues.Count) suspicious ACE(s):"
        $issues | Format-Table -AutoSize | Out-String | Write-Host
        $csv = Join-Path $LogRoot ("{0}-orphans-{1}.csv" -f (Get-SafeName $P.Dept),(Get-Date -Format yyyyMMdd-HHmmss))
        $issues | Export-Csv $csv -NoTypeInformation -Encoding UTF8
        Warn "Saved: $csv"
    } else { Good "No orphaned ACEs." }
}

function Test-PermissionParity { param($P)
    Step "Validating permissions (root: source vs destination)"
    try {
        $s=(Get-Acl -LiteralPath $P.SourcePath).Sddl; $d=(Get-Acl -LiteralPath $P.DestPath).Sddl
        if ($s -eq $d) { Good "Root ACL is identical." }
        else { Warn "Root ACL differs; saving a comparison."
            $f=Join-Path $LogRoot ("{0}-sddl-{1}.txt" -f (Get-SafeName $P.Dept),(Get-Date -Format yyyyMMdd-HHmmss))
            "SOURCE:`n$s`n`nDESTINATION:`n$d" | Set-Content $f -Encoding UTF8; Warn "File: $f" }
    } catch { Warn "Comparison failed: $($_.Exception.Message)" }
}

function Sync-SmbShare { param($P)
    Step "Recreating the share-level (SMB) permission on the destination"
    $sc=New-CimSession -ComputerName $P.SourceServer; $dc=New-CimSession -ComputerName $P.DestServer
    try {
        $src=Get-SmbShare -CimSession $sc -Name $P.ShareName -ErrorAction Stop
        $acc=Get-SmbShareAccess -CimSession $sc -Name $P.ShareName
        $local=Get-LocalPathOnDest $P
        Info "source: $($src.Name) -> $($src.Path) | ABE: $($src.FolderEnumerationMode) | ACEs: $($acc.Count)"
        Info "destination path: $local"
        $exists=Get-SmbShare -CimSession $dc -Name $P.ShareName -ErrorAction SilentlyContinue
        if ($exists) { Warn "Share already exists; reapplying ACL." }
        else { New-SmbShare -CimSession $dc -Name $P.ShareName -Path $local -Description $src.Description -FolderEnumerationMode $src.FolderEnumerationMode | Out-Null; Good "Share created." }
        Revoke-SmbShareAccess -CimSession $dc -Name $P.ShareName -AccountName 'Everyone' -Force -EA SilentlyContinue | Out-Null
        foreach ($a in $acc) {
            # Reapply every source ACE faithfully (the default Everyone=Read was already revoked above)
            if ($a.AccessControlType -eq 'Allow') { Grant-SmbShareAccess -CimSession $dc -Name $P.ShareName -AccountName $a.AccountName -AccessRight $a.AccessRight -Force | Out-Null }
            else { Block-SmbShareAccess -CimSession $dc -Name $P.ShareName -AccountName $a.AccountName -Force | Out-Null }
            Good "Share ACE: $($a.AccountName) = $($a.AccessControlType)/$($a.AccessRight)"
        }
    } finally { Remove-CimSession $sc,$dc -EA SilentlyContinue }
}

# ===========================================================================
#  PHASE
# ===========================================================================
function Run-Phase { param($ProfilePath,[string]$Mode)
    $P = Load-Profile $ProfilePath
    Title "PHASE $Mode - $($P.Dept)"
    Show-ProfileSummary $P
    switch ($Mode) {
        'Baseline' { Info "First copy. Old server live, users working. Adds only." }
        'Delta'    { Info "Fast copy of what changed. Run as many times as you like." }
        'Cutover'  { Warn "Final mirror copy (/MIR) + recreate the share."; Warn "The old share must be READ-ONLY before you run this." }
    }
    Step "Pre-flight checks"
    if (-not (Test-Path -LiteralPath $P.SourcePath)) { Bad "Source not reachable."; Pause-Enter; return }
    Good "Source reachable."
    if (Test-Path -LiteralPath $P.DestPath) { Good "Destination reachable." } else { Warn "Destination will be created." }

    if ($Mode -eq 'Cutover') {
        if (-not (Ask-YesNo "Is the old share '$($P.ShareName)' already READ-ONLY?" $false)) { Warn "Set the old share read-only and come back."; Pause-Enter; return }
        if ((Ask-Text "Type '$($P.Dept)' to confirm the CUTOVER") -ne $P.Dept) { Bad "Confirmation did not match. Cancelled."; Pause-Enter; return }
    }
    $dry = Ask-YesNo "Dry run first (estimate only, no copy)?" ($Mode -ne 'Delta')
    $log = Join-Path $LogRoot ("{0}-{1}-{2}.log" -f (Get-SafeName $P.Dept),$Mode,(Get-Date -Format yyyyMMdd-HHmmss))
    if ($dry) {
        Invoke-RoboCopyProgress -P $P -Mode $Mode -LogFile $log -DryRun | Out-Null
        if (-not (Ask-YesNo "Run for real now?" $true)) { Warn "Cancelled."; Pause-Enter; return }
    }
    $result = "OK"
    try {
        Invoke-RoboCopyProgress -P $P -Mode $Mode -LogFile $log | Out-Null
        Test-OrphanedAce -P $P
        Test-PermissionParity -P $P
        if ($Mode -eq 'Cutover') {
            if (Ask-YesNo "Recreate the SHARE on the new server now?" $true) { Sync-SmbShare -P $P } else { Warn "Share NOT recreated." }
            Write-Host ""; Warn "NEXT MANUAL STEP: point your DFS namespace to the new target, then release user access."
            Warn "Keep the old server as a rollback for a few days."
        }
    } catch { $result = "FAILURE: $($_.Exception.Message)"; Bad $result }
    $P.History += [PSCustomObject]@{ When=(Get-Date).ToString('s'); Mode=$Mode; Result=$result }
    Save-Profile $P $ProfilePath
    Write-Host ""; Good "Phase '$Mode' finished. Logs: $LogRoot"; Pause-Enter
}

# ===========================================================================
#  MENUS
# ===========================================================================
function Select-ProfileMenu {
    $profiles = @(Get-Profiles)
    if ($profiles.Count -eq 0) { Warn "No departments registered yet."; Pause-Enter; return $null }
    Title "SELECT A DEPARTMENT"
    $names = @($profiles | ForEach-Object { (Load-Profile $_.FullName).Dept })
    $opts  = $names + @("<< Back")
    $sel = Ask-Menu "Department" $opts
    if ($sel -eq $opts.Count) { return $null }
    return $profiles[$sel-1].FullName
}
function Department-Menu { param($ProfilePath)
    while ($true) {
        $P = Load-Profile $ProfilePath
        Title "DEPARTMENT: $($P.Dept)"
        Show-ProfileSummary $P; Write-Host ""
        $opt = Ask-Menu "Action" @(
            "Phase 1 - BASELINE (first copy)",
            "Phase 2 - DELTA (copy only what changed)",
            "Phase 3 - CUTOVER (final copy + recreate share)",
            "View logs for this department",
            "<< Back")
        switch ($opt) {
            1 { Run-Phase $ProfilePath 'Baseline' }
            2 { Run-Phase $ProfilePath 'Delta' }
            3 { Run-Phase $ProfilePath 'Cutover' }
            4 { Title "LOGS - $($P.Dept)"; Get-ChildItem $LogRoot -Filter "$(Get-SafeName $P.Dept)-*" | Select Name,@{N='KB';E={[int]($_.Length/1KB)}},LastWriteTime | Format-Table -AutoSize | Out-String | Write-Host; Info "Folder: $LogRoot"; Pause-Enter }
            5 { return }
        }
    }
}
function Main-Menu {
    while ($true) {
        Title "MAIN MENU"
        $opt = Ask-Menu "Choose" @(
            "Register a NEW department",
            "Work on an existing department",
            "List departments",
            "Exit")
        switch ($opt) {
            1 { $f=New-MigrationProfile; if ($f) { Department-Menu $f } }
            2 { $f=Select-ProfileMenu;  if ($f) { Department-Menu $f } }
            3 { Title "DEPARTMENTS"; $ps=@(Get-Profiles); if($ps.Count){$ps|%{$x=Load-Profile $_.FullName; Write-Host ("    - {0}  ({1})" -f $x.Dept,$x.SourcePath) -ForegroundColor $C.Hi}}else{Info "None."}; Pause-Enter }
            4 { Title "Goodbye!"; Write-Host ""; return }
        }
    }
}

Main-Menu
